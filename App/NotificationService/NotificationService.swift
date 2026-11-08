import CallKit
import os
import UserNotifications
import YapnestKit

/// Runs for each push: the relay's alert says nothing, so this fetches what
/// arrived, decrypts it and shows it in the alert's place. The fetch and the
/// system's deadline race to deliver; the lock lets only the first through.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let contentHandler = OSAllocatedUnfairLock<(@Sendable (UNNotificationContent) -> Void)?>(initialState: nil)
    /// The relay's own "New message", for when there's nothing better. Kept as
    /// it came, as a placeholder copy of it would mark a quiet one too.
    private var fallback: UNNotificationContent = UNNotificationContent()
    private var requestIdentifier = ""
    private var task: Task<Void, Never>?

    override init() {
        super.init()
        #if DEBUG
        AppDatabase.trapsMainThreadAccess = true
        #endif
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        nonisolated(unsafe) let handler = contentHandler
        self.contentHandler.withLock { $0 = { handler($0) } }
        fallback = request.content
        let identifier = request.identifier
        requestIdentifier = identifier
        task = Task {
            await UNUserNotificationCenter.current().removeQuietNotifications()
            await handle(identifier)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        deliverStandIn(requestIdentifier)
    }

    /// The relay's alert, for when the fetch couldn't say what came: left loud if it may be a message, which
    /// mustn't go unannounced, and shown quietly for one the relay marked as announcing none (a read marker, a
    /// reaction), which on a server that pushes for everything would otherwise ring "New message" whenever a wake
    /// fails. What the failed wake missed is read with the next one's catch-up.
    private func deliverStandIn(_ identifier: String, badge: Int? = nil) {
        if fallback.announcesNoMessage { return deliver(quiet: fallback.copy(withBadge: badge), identifier) }
        deliver(fallback.placeholderCopy(badge: badge))
    }

    private func handle(_ identifier: String) async {
        guard let fetcher = NotificationFetcher.current() else {
            // Before the first unlock after a restart the keychain can't be
            // read, which isn't being signed out: the relay's alert is what
            // the user gets, rather than silence.
            guard Self.isSignedOut() else {
                deliverStandIn(identifier)
                return
            }
            // Nothing of ours to show.
            return deliver(quiet: fallback, identifier)
        }
        let avatars = AccountDirectory(url: fetcher.directory).avatars
        await handle(await fetcher.fetch(), identifier, avatars: avatars)
    }

    private func handle(_ outcome: NotificationFetcher.Outcome, _ identifier: String, avatars: AvatarStore) async {
        switch outcome {
        case .calling(let calls, let otherwise):
            let handedOver = await show(calls)
            // The call is the app's now: a stand-in "New message" beside it would only be noise.
            if handedOver, case .incomplete(_, let badge) = otherwise { return deliver(quiet: fallback.copy(withBadge: badge), identifier) }
            await handle(otherwise, identifier, avatars: avatars)
        case .notifications(let notifications, let edited, let badge):
            let loud = await MessageNotification.settleFetched(notifications, edited: edited, badge: badge, avatars: avatars)
            guard let first = loud.first else {
                // Muted groups, or something without a message (a reaction, a
                // key exchange). An empty notification would leave the relay's
                // loud alert, so show the first muted message silently.
                guard let quiet = notifications.first else {
                    // The claim still worked out the badge, which the relay's content lacks.
                    return deliver(quiet: fallback.copy(withBadge: badge), identifier)
                }
                return deliver(quiet: await quiet.content(badge: badge, avatars: avatars), identifier)
            }
            for other in loud.dropFirst() {
                try? await UNUserNotificationCenter.current().add(await other.request(badge: badge, avatars: avatars))
            }
            deliver(await first.content(badge: badge, avatars: avatars))
        case .appIsRunning:
            // It has the connection, and notifies for what arrives itself.
            deliver(quiet: fallback, identifier)
        case .incomplete(let edited, let badge):
            await MessageNotification.replaceDelivered(edited, badge: badge, avatars: avatars)
            deliverStandIn(identifier, badge: badge)
        case .busy, .failed:
            deliverStandIn(identifier)
        }
    }

    /// Tells the system of the calls that are ringing, ahead of what else was fetched. The first goes to
    /// CallKit where there is one (iOS), which hands it to the app; a call it won't take, and the rest, are
    /// banners. Returns whether CallKit took the first.
    private func show(_ calls: [IncomingCall]) async -> Bool {
        var banners = calls[...]
        var handedOver = false
        #if !targetEnvironment(macCatalyst)
        if let first = calls.first {
            handedOver = await Self.report(first)
            if handedOver { banners = calls.dropFirst() }
        }
        #endif
        for call in banners {
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: call.requestIdentifier, content: call.notificationContent, trigger: nil),
            )
        }
        return handedOver
    }

    #if !targetEnvironment(macCatalyst)
    private static func report(_ call: IncomingCall) async -> Bool {
        await withCheckedContinuation { continuation in
            CXProvider.reportNewIncomingVoIPPushPayload(call.payload) { error in
                if let error { DiagLog.error(.notificationExtension, "CallKit refused an incoming call", .error(error)) }
                continuation.resume(returning: error == nil)
            }
        }
    }
    #endif

    /// Whether the keychain has no account, as opposed to not being readable.
    private static func isSignedOut() -> Bool {
        do {
            return try CredentialStore().load() == nil
        } catch {
            return false
        }
    }

    /// Shows nothing loud and takes the notification down soon after. Dropping
    /// the alert needs Apple's filtering entitlement, which we don't have.
    /// The extension may be killed before the removal; the next push and the
    /// app clear what's left.
    private func deliver(quiet content: UNNotificationContent, _ identifier: String) {
        let content = content.quietCopy()
        guard deliver(content) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    @discardableResult
    private func deliver(_ content: UNNotificationContent) -> Bool {
        let handler = contentHandler.withLock { handler in
            defer { handler = nil }
            return handler
        }
        DiagLog.flush()
        handler?(content)
        return handler != nil
    }
}
