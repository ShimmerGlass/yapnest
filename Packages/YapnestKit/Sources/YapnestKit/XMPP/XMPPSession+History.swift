import Foundation
@preconcurrency import Martin

public enum HistoryError: Error, LocalizedError {
    /// Not connected, or still catching up: try again once that's over.
    case notReady
    /// Another request for this chat is under way.
    case busy
    /// The server (or the room) keeps no archive, so there's nothing older.
    case noArchive
    /// The page came, but couldn't be stored; it is fetched again next time.
    case notStored

    public var errorDescription: String? {
        switch self {
        case .notReady: String(localized: "Not connected yet.")
        case .busy: String(localized: "Already loading.")
        case .noArchive: String(localized: "This server doesn't keep a message archive.")
        case .notStored: String(localized: "Couldn't save the older messages.")
        }
    }
}

/// Scrolling back past what this device has: older messages from the
/// server's archive (XEP-0313).
extension XMPPSession {
    /// How many messages one request asks for.
    static let historyPageSize = 50

    /// Fetches one more page of messages older than those stored for `peer`,
    /// and stores it. Returns whether the archive may have still older ones.
    ///
    /// What comes back is stored as read and nobody is told: not by a
    /// notification, a receipt or a displayed marker, and the chat keeps
    /// its place in the list. It goes through the same path as the catch-up,
    /// so decryption, duplicates, reactions, corrections and retractions all
    /// work. Pages come newest first, so a retraction or correction can come
    /// before the message it names: it is kept (`pendingEdit`) and applied
    /// when that message is stored, and a correction shows meanwhile as a
    /// message of its own. Reactions to a message older than the page can't
    /// find theirs yet, and are dropped like they would be anywhere else.
    public func loadOlderHistory(for peer: JID) async throws -> Bool {
        try await loadHistory(for: peer, newest: false)
    }

    /// With `newest`, a chat with nothing stored gets the archive's newest
    /// page, which is how a chat lost with the device is restored. Without,
    /// there is nothing "older" to ask for.
    func loadHistory(for peer: JID, newest: Bool) async throws -> Bool {
        let known = try database.historyState(peer: peer)
        if known.isComplete { return false }
        let oldest = try database.oldestMessage(peer: peer)
        if oldest != nil, newest { return false }
        guard oldest != nil || newest else { return false }

        let route = route(to: peer)
        let isRoom = route.isGroup
        guard isConnected, !lock.withLock({ $0.isSyncing }) else { throw HistoryError.notReady }
        let version: MessageArchiveManagementModule.Version
        if case .room(_, let status) = route {
            guard route.isReady, let status else { throw HistoryError.notReady }
            guard status.hasArchive else { throw HistoryError.noArchive }
            version = .MAM2
        } else {
            guard let archive = lock.withLock({ $0.archiveVersion }) else { throw HistoryError.noArchive }
            version = archive
        }
        guard lock.withLock({ $0.historyLoading.insert(peer).inserted }) else { throw HistoryError.busy }
        defer { _ = lock.withLock { $0.historyLoading.remove(peer) } }

        var cursor = known.cursor
        while true {
            // Without a cursor: the page that ends where our messages begin.
            let rsm = cursor.map { RSM.Query(before: $0, max: Self.historyPageSize) } ?? RSM.Query(lastItems: Self.historyPageSize)
            let result = await queryHistory(of: peer, isRoom: isRoom, version: version, end: cursor == nil ? oldest?.timestamp : nil, rsm: rsm)
            switch result {
            case .success(let page):
                // Moving the cursor past a page that didn't make it into the
                // database would leave a gap that is never fetched.
                guard page.isStored else {
                    logger.error("Older history of \(peer, privacy: .private) couldn't be stored")
                    throw HistoryError.notStored
                }
                let isComplete = page.isComplete
                try database.setHistoryState(peer: peer, isComplete: isComplete, cursor: page.first ?? cursor)
                return !isComplete
            case .failure(.item_not_found) where cursor != nil:
                // The archive dropped what our cursor points at: start over
                // from our oldest message, which the next page then moves.
                cursor = nil
                try database.setHistoryState(peer: peer, isComplete: false, cursor: nil)
            case .failure(let error):
                logger.error("Older history of \(peer, privacy: .private) failed: \(error)")
                throw error
            }
        }
    }

    struct HistoryPage: Sendable {
        var isComplete: Bool
        /// The archive id of its oldest message, where the next page ends.
        var first: String?
        var isStored = true

        /// An empty page ends the archive too, whatever the server says.
        static func isComplete(complete: Bool, first: String?) -> Bool {
            complete || first == nil
        }
    }

    private func queryHistory(
        of peer: JID, isRoom: Bool, version: MessageArchiveManagementModule.Version, end: Date?, rsm: RSM.Query,
    ) async -> Result<HistoryPage, XMPPError> {
        let queryId = UUID().uuidString
        _ = lock.withLock { $0.historyQueries.insert(queryId) }
        defer { _ = lock.withLock { $0.historyQueries.remove(queryId) } }
        return await withCheckedContinuation { continuation in
            client.module(.mam).queryItems(
                version: version,
                componentJid: isRoom ? Martin.JID(peer.martin) : nil,
                with: isRoom ? nil : Martin.JID(peer.martin),
                end: end,
                queryId: queryId,
                rsm: rsm,
            ) { [weak self] result in
                // The page's messages arrived before its answer, and are
                // stored before the caller looks at the database again.
                let isStored = self?.flushArchive(query: queryId) ?? false
                continuation.resume(returning: result.map {
                    HistoryPage(isComplete: HistoryPage.isComplete(complete: $0.complete, first: $0.rsm?.first), first: $0.rsm?.first, isStored: isStored)
                })
            }
        }
    }
}
