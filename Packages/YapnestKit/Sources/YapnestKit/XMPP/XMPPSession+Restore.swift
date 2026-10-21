import Foundation
import Martin

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
        try? database.setSetting(.historyRestored, nil)
        try? database.setSetting(.historyRestore, "pending")
    }

    private func restoredPeers() -> Set<String> {
        guard let json = try? database.setting(.historyRestored), let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private func saveRestoredPeers(_ peers: Set<String>) {
        guard let data = try? JSONEncoder().encode(peers.sorted()) else { return }
        try? database.setSetting(.historyRestored, String(decoding: data, as: UTF8.self))
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
        // A contact that finished without leaving a message (no archive) isn't
        // among those with messages, and would be asked at every connect while
        // another one keeps failing.
        var restored = restoredPeers()
        let stored = (try? database.peersWithMessages()) ?? []
        var queue = Self.contactsToRestore(roster: roster, withMessages: stored).filter { !restored.contains($0.description) }[...]

        var allFinished = true
        await withTaskGroup(of: (JID, Bool).self) { group in
            func next() -> JID? {
                guard isCurrent(attempt: attempt) else { return nil }
                return queue.popFirst()
            }
            for _ in 0..<Self.restoreConcurrency {
                guard let peer = next() else { break }
                group.addTask { (peer, await self.restore(peer)) }
            }
            while let (done, finished) = await group.next() {
                if finished {
                    restored.insert(done.description)
                    saveRestoredPeers(restored)
                } else {
                    allFinished = false
                }
                guard let peer = next() else { continue }
                group.addTask { (peer, await self.restore(peer)) }
            }
        }
        // Not while it was cut short, or when a contact's query failed in a way
        // that may pass: those are for the next connect, which skips the restored.
        guard isCurrent(attempt: attempt), queue.isEmpty, allFinished else { return }
        try? database.setSetting(.historyRestore, nil)
        try? database.setSetting(.historyRestored, nil)
    }

    /// Whether there is nothing more to do for `peer`: it was restored, has no
    /// archive, or the server refused in a way that won't change. A failure that
    /// may pass (a timeout, a busy chat, a page that couldn't be stored) isn't
    /// finished, or the chat would be lost for good.
    private func restore(_ peer: JID) async -> Bool {
        do {
            _ = try await loadHistory(for: peer, newest: true)
            return true
        } catch {
            logger.info("Couldn't restore the chat with \(peer, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return Self.isDefinitive(error)
        }
    }

    static func isDefinitive(_ error: Error) -> Bool {
        if case HistoryError.noArchive = error { return true }
        guard let error = error as? XMPPError else { return false }
        switch error.errorCondition {
        case .item_not_found, .forbidden, .not_allowed, .feature_not_implemented, .service_unavailable: return true
        default: return false
        }
    }
}
