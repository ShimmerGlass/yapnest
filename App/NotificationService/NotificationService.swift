import os
import UserNotifications
import YapnestKit

/// Runs for each push: the relay's alert says nothing, so this fetches what
/// arrived, decrypts it and shows it in the alert's place. The fetch and the
/// system's deadline race to deliver; the lock lets only the first through.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let contentHandler = OSAllocatedUnfairLock<(@Sendable (UNNotificationContent) -> Void)?>(initialState: nil)
    /// The relay's own "New message", for when there's nothing better.
    private var fallback: UNNotificationContent = UNNotificationContent()
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
        task = Task {
            await UNUserNotificationCenter.current().removeQuietNotifications()
            await handle(identifier)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        deliver(fallback)
    }

    private func handle(_ identifier: String) async {
        guard let fetcher = NotificationFetcher.current() else {
            // Before the first unlock after a restart the keychain can't be
            // read, which isn't being signed out: the relay's alert is what
            // the user gets, rather than silence.
            guard Self.isSignedOut() else {
                deliver(fallback)
                return
            }
            // Nothing of ours to show.
            return deliver(quiet: fallback, identifier)
        }
        let avatars = AccountDirectory(url: fetcher.directory).avatars
        switch await fetcher.fetch() {
        case .notifications(let notifications, let edited, let badge):
            await MessageNotification.replaceDelivered(edited, badge: badge, avatars: avatars)
            await MessageNotification.replaceHeld(notifications, badge: badge, avatars: avatars)
            let loud = notifications.filter { !$0.isQuiet }
            guard let first = loud.first else {
                // Muted groups, or something without a message (a reaction, a
                // key exchange). An empty notification would leave the relay's
                // loud alert, so show the first muted message silently.
                guard let quiet = notifications.first else {
                    // The claim still worked out the badge, which the relay's content lacks.
                    return deliver(quiet: fallback.withBadge(badge), identifier)
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
            deliver(fallback.withBadge(badge))
        case .busy, .failed:
            deliver(fallback)
        }
    }

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

private extension UNNotificationContent {
    func withBadge(_ badge: Int) -> UNNotificationContent {
        let copy = (mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        copy.badge = badge as NSNumber
        return copy
    }
}
