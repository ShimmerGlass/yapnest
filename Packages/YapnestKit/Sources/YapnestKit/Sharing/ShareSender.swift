import Foundation
import GRDB
import os

/// What the share extension does with what's shared: writes it to the
/// account's database as pending messages, then sends them in a session of its
/// own, like `NotificationFetcher` does for pushes.
///
/// The messages are written first, so that whatever goes wrong afterwards, the
/// app has them: it sends everything still pending the next time it connects.
public struct ShareSender: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The server has everything.
        case sent
        /// The app holds the session, which happens when it's open (always,
        /// on the Mac). It's been told, and sends the messages itself.
        case handedToApp
        /// Written, but not sent: the app will send it the next time it
        /// connects.
        case queued(String)
        /// Nothing was written, so nothing is lost: the user can try again.
        case failed(String)
        /// Written, and one message failed. It waits in Yapnest with its retry
        /// button, and the ones after it are sent when the app next connects.
        /// Sending again from the sheet would duplicate all of them.
        case failedInApp(String)
    }

    public var credentials: XMPPSession.Credentials
    /// The account's directory in the shared container.
    public var directory: URL
    public var resource: String
    public var lock: ProcessLock

    /// Files larger than this are left for the app: sending one reads it into
    /// memory, encrypted twice over, and the extension has about 120 MB.
    public static let maxFileSize: Int64 = 20 * 1024 * 1024

    /// How long to wait for the app to let go of the session. Long enough
    /// for one that has just gone to the background, short enough that on
    /// the Mac, where it never does, the user isn't kept waiting.
    public var lockTimeout: TimeInterval = 3

    /// How long to keep waiting when the lock is held by an extension rather
    /// than the app: its fetch is bounded, and no app is listening for a
    /// signal, so the messages would otherwise wait for the next launch.
    public var extensionLockWait: TimeInterval = 20

    /// Stands in for the session that would connect to the server, so a send
    /// can be tried without one.
    var makeSession: (@Sendable (AppDatabase) throws -> XMPPSession)?

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

    /// For the signed-in account, or nil if the app hasn't been signed in.
    public static func current() -> ShareSender? {
        guard let credentials = try? CredentialStore().load(), let deviceId = SharedContainer.existingDeviceId else { return nil }
        return ShareSender(
            credentials: credentials,
            directory: SharedContainer.directory(for: credentials.jid),
            resource: "yapnest-\(deviceId)-share",
        )
    }

    private static let logger = Logger(subsystem: "Yapnest", category: "Share")

    // MARK: Recipients

    /// The chats to choose from, most recent first. Conversations we can't
    /// write to (groups we left, blocked contacts) are left out.
    public func recipients() throws -> [ChatListItem] {
        try openDatabase().chatList()
            .filter { $0.groupChat?.hasLeft != true && $0.contact?.isBlocked != true }
            .sorted { $0.conversation.lastActivityAt > $1.conversation.lastActivityAt }
    }

    /// Where `item`'s avatar is, if it has one.
    public func avatarURL(for item: ChatListItem) -> URL? {
        account.avatars.url(for: item.contact)
    }

    private var account: AccountDirectory { AccountDirectory(url: directory) }

    private func openDatabase() throws -> AppDatabase {
        try account.openDatabase()
    }

    // MARK: Sending

    /// Sends `content` to `peer`. `progress` hears how many messages the
    /// server has so far, of how many. Gives up after `timeout`.
    public func send(
        _ content: ShareContent, to peer: JID, timeout: TimeInterval = 60,
        progress: (@Sendable (_ sent: Int, _ total: Int) -> Void)? = nil,
    ) async -> Outcome {
        let started = Date()
        let outcome = await perform(content, to: peer, timeout: timeout, progress: progress)
        DiagLog.info(.shareExtension, "Share finished", .value("outcome", ShareResult(outcome)), .duration("took", since: started))
        // The extension is ended as soon as the sheet closes.
        DiagLog.flush()
        return outcome
    }

    private func perform(
        _ content: ShareContent, to peer: JID, timeout: TimeInterval,
        progress: (@Sendable (_ sent: Int, _ total: Int) -> Void)?,
    ) async -> Outcome {
        var deadline = Date().addingTimeInterval(timeout)
        let database: AppDatabase
        let staged: [Message]
        do {
            database = try openDatabase()
            staged = try await stage(content, to: peer, in: database)
        } catch {
            Self.logger.error("Couldn't write the shared messages: \(error)")
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard !staged.isEmpty else { return .failed(String(localized: "There's nothing to send.")) }
        await ShareSuggestions.donate(to: peer, database: database, avatars: account.avatars)

        if let outcome = await takeLock() { return outcome }
        defer { lock.unlock() }
        // The wait for the lock isn't the server's time.
        deadline = max(deadline, Date().addingTimeInterval(10))

        let session: XMPPSession
        do {
            session = try makeSession?(database)
                ?? XMPPSession(credentials: credentials, resource: resource, directory: account, database: database, mode: .share, identityKeys: identityKeys)
        } catch {
            return .queued(error.localizedDescription)
        }
        defer { session.disconnect() }
        session.savesConfirmedPassword(to: CredentialStore())

        if let reason = await session.connectToSend(timeout: deadline.timeIntervalSinceNow) {
            return .queued(reason)
        }
        if (try? database.groupChat(peer)) != nil,
           let reason = await session.joinToSend(peer, timeout: deadline.timeIntervalSinceNow) {
            return .queued(reason)
        }

        // One at a time, so they arrive in the order shared: uploads finish
        // whenever they do.
        for (index, message) in staged.enumerated() {
            if let size = try? database.attachment(messageId: message.id!)?.size, size > Self.maxFileSize {
                return .queued(String(localized: "A large file waits for Yapnest to open."))
            }
            session.transmit(message, to: peer)
            if let outcome = await waitUntilSent(message, in: database, deadline: deadline) { return outcome }
            progress?(index + 1, staged.count)
        }
        return .sent
    }

    /// Nil once this process holds the lock; else how the send ends without it.
    private func takeLock() async -> Outcome? {
        func acquire(_ wait: TimeInterval) async -> Bool {
            await Task.detached(operation: { [lock] in lock.lock(timeout: wait, as: .share) }).value
        }
        if await acquire(lockTimeout) { return nil }
        // Only the app listens for the signal.
        if lock.holder != .app {
            if await acquire(extensionLockWait) { return nil }
        }
        if lock.holder == .app {
            PendingSendsSignal.post()
            return .handedToApp
        }
        return .queued(String(localized: "Yapnest is busy. The messages are sent when it next opens."))
    }

    /// Writes the messages as pending. Files are copied into the account's
    /// attachment store first, so the message keeps them after the extension's
    /// temporary copies go.
    private func stage(_ content: ShareContent, to peer: JID, in database: AppDatabase) async throws -> [Message] {
        let outgoing = OutgoingMessages(
            database: database, attachments: account.attachments, account: credentials.jid,
        )
        var prepared: [OutgoingMessages.PreparedFile] = []
        var items: [OutgoingMessages.Item] = []
        do {
            for item in content.items() {
                switch item {
                case .file(let file):
                    let stored = try await outgoing.prepareFile(at: file.url, name: file.name, asPhoto: file.isPhoto)
                    prepared.append(stored)
                    items.append(.file(stored))
                case .text(let text):
                    items.append(.text(text))
                }
            }
            return try outgoing.stage(items, to: peer)
        } catch {
            outgoing.discard(prepared)
            throw error
        }
    }

    /// How a staged message that failed ends the send; nil if it hasn't.
    static func failure(status: Message.Status, error: String?) -> Outcome? {
        guard status == .failed else { return nil }
        return .failedInApp(error ?? String(localized: "The message couldn't be sent."))
    }

    /// Nil once the server has `message`; else how it ended.
    private func waitUntilSent(_ message: Message, in database: AppDatabase, deadline: Date) async -> Outcome? {
        let observation = database.observeDeliveryState(id: message.id!)
        do {
            return try await withTimeout(deadline.timeIntervalSinceNow) { () -> Outcome? in
                for try await state in observation.values(in: database.reader, bufferingPolicy: .bufferingNewest(1)) {
                    guard let state else { continue }
                    if let failure = Self.failure(status: state.status, error: state.error) { return failure }
                    if state.status >= .sent { return nil }
                }
                throw TimeoutError()
            }
        } catch {
            return .queued(String(localized: "The server didn't respond."))
        }
    }
}

/// How a share ended, for the diagnostics log.
enum ShareResult: String, DiagEnum {
    case sent, queued, handedToApp, failed, failedInApp

    init(_ outcome: ShareSender.Outcome) {
        switch outcome {
        case .sent: self = .sent
        case .queued: self = .queued
        case .handedToApp: self = .handedToApp
        case .failed: self = .failed
        case .failedInApp: self = .failedInApp
        }
    }
}
