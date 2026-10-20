import Foundation

/// Chats a reinstall lost. The first sync reads only the last
/// `initialSyncWindow` of the archive, and the chat list shows conversations,
/// which exist once a message is stored. A chat whose last message is older
/// would stay unlisted until someone wrote in it.
extension XMPPSession {
    /// How many contacts are asked about at once.
    static let restoreConcurrency = 4

    /// Whether a sync that begins with `cursor` has to restore chats after.
    /// Without a cursor it can only see the window; with one it has seen
    /// everything since.
    static func beginsChatRestore(cursor: String?) -> Bool {
        cursor == nil
    }

    /// The contacts to ask the archive about: those with no message stored.
    static func contactsToRestore(roster: [JID], withMessages: Set<JID>) -> [JID] {
        roster.filter { !withMessages.contains($0) }
    }

    func markChatRestorePending() {
        try? database.setSetting(.historyRestore, "pending")
    }

    /// Runs after the sync is reported done, so "connected" never waits on it.
    /// A drop leaves the setting pending, and the next connect starts again,
    /// skipping the contacts that were restored by then.
    func restoreChatsIfPending() {
        guard policy.syncsAccountState, (try? database.setting(.historyRestore)) == "pending" else { return }
        let attempt = lock.withLock { $0.attempt }
        Task.detached(priority: .utility) { [weak self] in
            await self?.restoreChats(attempt: attempt)
        }
    }

    private func isCurrent(attempt: Int) -> Bool {
        isConnected && lock.withLock { $0.attempt } == attempt
    }

    func restoreChats(attempt: Int) async {
        // The roster comes with the connection, in step with the catch-up. If
        // it hasn't arrived there is nobody to ask about yet, which is no
        // reason to call the job done.
        guard let roster = try? database.roster().map(\.jid), !roster.isEmpty else { return }
        let stored = (try? database.peersWithMessages()) ?? []
        var queue = Self.contactsToRestore(roster: roster, withMessages: stored)[...]

        await withTaskGroup(of: Void.self) { group in
            func next() -> JID? {
                guard isCurrent(attempt: attempt) else { return nil }
                return queue.popFirst()
            }
            for _ in 0..<Self.restoreConcurrency {
                guard let peer = next() else { break }
                group.addTask { await self.restore(peer) }
            }
            while await group.next() != nil {
                guard let peer = next() else { continue }
                group.addTask { await self.restore(peer) }
            }
        }
        // Not while it was cut short: the contacts left are for the next connect.
        guard isCurrent(attempt: attempt), queue.isEmpty else { return }
        try? database.setSetting(.historyRestore, nil)
    }

    private func restore(_ peer: JID) async {
        do {
            _ = try await loadHistory(for: peer, newest: true)
        } catch {
            logger.info("Couldn't restore the chat with \(peer, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
