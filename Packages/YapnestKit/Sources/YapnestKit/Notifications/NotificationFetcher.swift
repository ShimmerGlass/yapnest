import Foundation
import os
import UserNotifications

/// What the notification extension does with a push: catches up on the
/// account's archives in a session of its own and returns what to notify
/// about. The push itself says nothing; the messages come from the server.
public struct NotificationFetcher: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// What to show (possibly nothing new), the messages corrected since
        /// whose delivered notification should change text, and the app's badge.
        case notifications([MessageNotification], edited: [MessageNotification], badge: Int)
        /// The app holds the session: it's open, or just was, and notifies for
        /// what arrives itself.
        case appIsRunning
        /// Another process holds the session, one that won't notify for this
        /// push: the share extension, or unknown. The relay's own content
        /// should show.
        case busy
        case failed(String)
    }

    public var credentials: XMPPSession.Credentials
    /// The account's directory in the shared container.
    public var directory: URL
    public var resource: String
    public var lock: ProcessLock

    /// This device's OMEMO identity, the app's, which the session needs to
    /// decrypt; nil for the keychain's.
    public var identityKeys: (any IdentityKeyStore)?

    public init(
        credentials: XMPPSession.Credentials, directory: URL, resource: String, lock: ProcessLock = SharedContainer.sessionLock,
        identityKeys: (any IdentityKeyStore)? = nil,
    ) {
        self.credentials = credentials
        self.directory = directory
        self.resource = resource
        self.lock = lock
        self.identityKeys = identityKeys
    }

    private static let logger = Logger(subsystem: "Yapnest", category: "Notifications")

    /// Leaves a few seconds of the extension's 30 for the rest.
    public func fetch(timeout: TimeInterval = 20) async -> Outcome {
        let started = Date()
        let outcome = await run(timeout: timeout)
        DiagLog.info(.notificationExtension, "Fetch finished", .value("outcome", FetchResult(outcome)), .duration("took", since: started))
        return outcome
    }

    private func run(timeout: TimeInterval) async -> Outcome {
        // Servers push for presence and group traffic too, so pushes come in
        // bursts, and the extension handles them at once. One catch-up at a
        // time: a push that arrived before the latest one started only needs
        // what it stored.
        let arrived = Date()
        return await Self.queue.enqueue { [self] in
            // The extension has already shown its fallback by now, and what
            // it claimed would be lost.
            if Task.isCancelled { return .failed("Cancelled") }
            let lastCatchUp = await Self.queue.lastCatchUp
            switch Self.plan(arrived: arrived, lastCatchUp: lastCatchUp, now: Date(), timeout: timeout) {
            case .claimOnly:
                return claim()
            case .catchUp(let lockWait, let timeout):
                // Only a catch-up that finished, or one that found the app
                // holding the session (it has the connection and notifies by
                // itself), lets later pushes go without one. A push that found
                // another extension holding the lock, or a catch-up that timed
                // out, leaves them to try for themselves.
                let started = Date()
                let (outcome, completed) = await catchUpAndClaim(lockWait: lockWait, timeout: timeout)
                if completed { await Self.queue.setLastCatchUp(started) }
                // The pushes that arrived during the wait are the app's to show,
                // so the mark is when the wait ended, not when it began.
                else if outcome == .appIsRunning { await Self.queue.setLastCatchUp(Date()) }
                return outcome
            }
        }
    }

    enum Plan: Equatable {
        /// Only hand out what earlier catch-ups stored.
        case claimOnly
        case catchUp(lockWait: TimeInterval, timeout: TimeInterval)
    }

    /// Less than this isn't worth a connection: it takes about that long to
    /// connect and authenticate, so the push would be late anyway.
    static let minimumCatchUp: TimeInterval = 4
    static let maxLockWait: TimeInterval = 3

    /// What to do with a push that arrived at `arrived`, when it comes to
    /// the front of the queue at `now`. Its deadline is `timeout` after it
    /// arrived, however long it waited behind others.
    static func plan(arrived: Date, lastCatchUp: Date, now: Date, timeout: TimeInterval) -> Plan {
        if lastCatchUp > arrived { return .claimOnly }
        let remaining = arrived.addingTimeInterval(timeout).timeIntervalSince(now)
        if remaining < minimumCatchUp { return .claimOnly }
        let lockWait = min(maxLockWait, remaining)
        return .catchUp(lockWait: lockWait, timeout: remaining - lockWait)
    }

    private static let queue = FetchQueue()

    private func catchUpAndClaim(lockWait: TimeInterval, timeout: TimeInterval) async -> (Outcome, completed: Bool) {
        // The app connects and resumes in a moment, then lets go.
        guard await Task.detached(operation: { [lock] in lock.lock(timeout: lockWait, as: .notification) }).value else {
            if lock.holder == .app { return (.appIsRunning, false) }
            return (.busy, false)
        }
        defer { lock.unlock() }
        do {
            let database = try account.openDatabase()
            let session = try XMPPSession(
                credentials: credentials, resource: resource, directory: account, database: database, mode: .notificationService,
                identityKeys: identityKeys,
            )
            session.savesConfirmedPassword(to: CredentialStore())
            let caughtUp = await session.catchUpOnce(timeout: timeout)
            DiagLog.info(.notificationExtension, "Catch-up finished", .bool("completed", caughtUp), .duration("budget", timeout))
            if !caughtUp {
                Self.logger.warning("Catch-up didn't finish: \(session.state.value.caseName, privacy: .public)")
            }
            // What did arrive is worth showing even if the rest didn't.
            return (try claimed(from: database), caughtUp)
        } catch {
            DiagLog.error(.notificationExtension, "Fetching failed", .error(error))
            Self.logger.error("Fetching for notifications failed: \(error)")
            return (.failed(error.localizedDescription), false)
        }
    }

    private func claim() -> Outcome {
        do {
            return try claimed(from: account.openDatabase())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func claimed(from database: AppDatabase) throws -> Outcome {
        let claimed = try database.claimNotificationsAndEdits()
        return .notifications(claimed.new, edited: claimed.edited, badge: try database.unreadCount())
    }

    private var account: AccountDirectory { AccountDirectory(url: directory) }
}

/// Runs fetches one after another, in the order they came.
private actor FetchQueue {
    private var previous: Task<Void, Never>?
    private(set) var lastCatchUp = Date.distantPast

    func setLastCatchUp(_ date: Date) {
        lastCatchUp = date
    }

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let prior = previous
        let task = Task<T, Never> {
            await prior?.value
            return await operation()
        }
        previous = Task { _ = await task.value }
        // A caller that gives up, as the extension does when its time is
        // nearly up, stops its fetch if that hasn't started yet.
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

extension MessageNotification {
    /// Where the conversation's peer goes in a notification's `userInfo`.
    public static let peerKey = "peer"
    /// Marks a delivered notification that was only shown silently, so that it
    /// can be found and taken down again.
    public static let quietKey = "quiet"
    /// The message a notification shows. The first notification of a push is
    /// delivered under the push's own identifier, so a correction can't find
    /// it by `requestIdentifier`.
    public static let messageIdKey = "messageId"
    /// Where a held group invitation's notification keeps the group's address.
    public static let invitationKey = "invitation"
    /// The thread of every invitation's notification, which groups them
    /// apart from the chats'.
    public static let invitationsThread = "invitations"

    public func content(badge: Int?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = NotificationSound.choice(kind: isGroup ? .groupchat : .chat, stored: sound, isQuiet: isQuiet).unSound
        if isInvitation {
            // No peer: it isn't a chat to open, and the chat list shows the invitation.
            content.threadIdentifier = Self.invitationsThread
            content.userInfo = [Self.invitationKey: peer.description]
        } else {
            content.threadIdentifier = peer.description
            content.userInfo = [Self.peerKey: peer.description, Self.messageIdKey: messageId]
        }
        if isQuiet {
            content.interruptionLevel = .passive
            content.userInfo[Self.quietKey] = true
        }
        content.badge = badge.map { $0 as NSNumber }
        return content
    }

    public var requestIdentifier: String { isInvitation ? "invitation-\(peer)" : "message-\(messageId)" }

    /// The delivered notifications of invitations that aren't held any more,
    /// whether they were joined, declined or answered from another device.
    /// The extension's is delivered under the push's identifier, so they're
    /// found by what `userInfo` says.
    public static func staleInvitationNotifications(
        among delivered: [(identifier: String, userInfo: [AnyHashable: Any])], held: Set<JID>,
    ) -> [String] {
        delivered.compactMap { entry in
            guard let room = (entry.userInfo[invitationKey] as? String).flatMap(JID.init(_:)), !held.contains(room) else { return nil }
            return entry.identifier
        }
    }
}

extension UNNotificationContent {
    /// A copy that makes no sound and doesn't wake the screen, marked so it can
    /// be removed again. Delivering nothing would leave the relay's loud alert.
    public func quietCopy() -> UNNotificationContent {
        let copy = (mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        copy.sound = nil
        copy.interruptionLevel = .passive
        copy.userInfo[MessageNotification.quietKey] = true
        return copy
    }
}

extension UNNotification {
    public var isQuiet: Bool { request.content.userInfo[MessageNotification.quietKey] as? Bool == true }
}

extension UNUserNotificationCenter {
    /// Takes down the notifications of invitations no longer held.
    public func removeStaleInvitationNotifications(held: Set<JID>) async {
        let delivered = await deliveredNotifications().map { (identifier: $0.request.identifier, userInfo: $0.request.content.userInfo) }
        removeDeliveredNotifications(withIdentifiers: MessageNotification.staleInvitationNotifications(among: delivered, held: held))
    }

    /// Muted messages are shown silently by the notification extension, which
    /// takes them down again if it lives long enough. This clears the rest.
    public func removeQuietNotifications() async {
        removeDeliveredNotifications(withIdentifiers: await deliveredNotifications().filter(\.isQuiet).map(\.request.identifier))
    }
}

/// How a fetch ended, for the diagnostics log.
enum FetchResult: String, DiagEnum {
    case notifications, appIsRunning, busy, failed

    init(_ outcome: NotificationFetcher.Outcome) {
        switch outcome {
        case .notifications: self = .notifications
        case .appIsRunning: self = .appIsRunning
        case .busy: self = .busy
        case .failed: self = .failed
        }
    }
}
