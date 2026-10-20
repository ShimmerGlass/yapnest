import Foundation
import Observation
import GRDB
import SwiftUI
import YapnestKit

/// Searching inside one chat: the matches, newest first, and which one the
/// list is showing.
@MainActor
@Observable
final class ChatSearch {
    var isActive = false
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var isSearching = false
    /// Message ids, newest first.
    private(set) var matches: [Int64] = []
    /// Into `matches`; 0 is the newest.
    private(set) var current = 0

    @ObservationIgnored private let session: XMPPSession
    @ObservationIgnored private let peer: JID
    @ObservationIgnored private let conversation: ConversationModel
    @ObservationIgnored private var task: Task<Void, Never>?

    /// More than any chat needs to step through by hand.
    nonisolated private static let limit = 500

    init(session: XMPPSession, peer: JID, conversation: ConversationModel) {
        self.session = session
        self.peer = peer
        self.conversation = conversation
    }

    var hasMatches: Bool { !matches.isEmpty }
    var canGoOlder: Bool { current + 1 < matches.count }
    var canGoNewer: Bool { current > 0 }

    /// "3 of 12", or what's missing of it.
    var summary: String {
        if !matches.isEmpty { return String(localized: "\(current + 1) of \(matches.count)") }
        if isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return String(localized: "No results")
    }

    func open() { isActive = true }

    func close() {
        task?.cancel()
        isActive = false
        query = ""
        noMatches()
    }

    func goOlder() { move(to: current + 1) }
    func goNewer() { move(to: current - 1) }

    private func move(to index: Int) {
        guard matches.indices.contains(index) else { return }
        current = index
        conversation.reveal(matches[index])
    }

    private func queryChanged() {
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            noMatches()
            return
        }
        isSearching = true
        let database = session.database, peer = peer
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let conversationId = await Task.detached(priority: .userInitiated) {
                try? database.reader.read { try Conversation.filter(Column("peer") == peer).fetchOne($0)?.id }
            }.value
            guard !Task.isCancelled else { return }
            guard let conversationId else {
                self?.noMatches()
                return
            }
            // Followed from here on, so a message deleted, retracted or edited
            // away drops out, and one that now matches joins.
            let observation = database.observeSearchMatches(text, in: conversationId, limit: Self.limit)
            var isFirst = true
            await database.forEachValue(of: observation, "Chat search") { [weak self] found in
                guard let self, !Task.isCancelled else { return }
                if isFirst {
                    isFirst = false
                    matches = found
                    current = 0
                    isSearching = false
                    if let first = found.first { conversation.reveal(first) }
                } else {
                    matchesChanged(to: found)
                }
            }
        }
    }

    private func noMatches() {
        matches = []
        current = 0
        isSearching = false
    }

    /// The current match stays the same message wherever it moves in the list.
    /// When it's the one that dropped out, the one that took its place is
    /// current, which is the next older, or the newest of what's left if it
    /// was the oldest.
    private func matchesChanged(to found: [Int64]) {
        let shown = matches.indices.contains(current) ? matches[current] : nil
        matches = found
        if let shown, let index = found.firstIndex(of: shown) {
            current = index
            return
        }
        current = min(current, max(found.count - 1, 0))
        if found.indices.contains(current) { conversation.reveal(found[current]) }
    }
}
