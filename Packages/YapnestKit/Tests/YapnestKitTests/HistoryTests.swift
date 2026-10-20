import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

struct HistoryTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    /// A message from the archive, as `loadOlderHistory` hands them to the
    /// database.
    private func archived(_ id: String, body: String, from sender: String = "alice@example.org/phone", at seconds: TimeInterval, history: Bool) throws -> InboundMessage {
        let to = sender.hasPrefix("me@") ? "alice@example.org" : "me@example.org"
        let message = stanza("<message from='\(sender)' to='\(to)' type='chat' id='\(id)'><body>\(body)</body></message>")
        var inbound = try #require(InboundMessage(
            message, account: me, source: .archive(serverId: "s-\(id)", timestamp: Date(timeIntervalSince1970: seconds)),
        ))
        inbound.isHistory = history
        return inbound
    }

    private func conversation() throws -> Conversation {
        try #require(try db.reader.read { try Conversation.fetchOne($0) })
    }

    @Test func olderHistoryIsStoredReadAndLeavesTheChatWhereItIs() throws {
        // A chat with news from t=1000, archived by the user.
        try db.ingest(try archived("new", body: "newest", at: 1_000, history: false))
        let id = try conversation().id!
        try db.setArchived(true, conversationId: id)
        let before = try conversation()

        let results = try db.ingest([
            try archived("old1", body: "older", at: 100, history: true),
            try archived("old2", body: "mine, older", from: "me@example.org/laptop", at: 200, history: true),
        ])
        #expect(results.allSatisfy { $0.newMessage != nil })

        let stored = try db.reader.read { try Message.order(Column("timestamp")).fetchAll($0) }
        #expect(stored.map(\.body) == ["older", "mine, older", "newest"])
        // The newest one wasn't history, so it's the only unread.
        #expect(stored.map(\.isRead) == [true, true, false])
        let after = try conversation()
        #expect(after.lastActivityAt == before.lastActivityAt)
        #expect(after.isArchived)
        #expect(try db.reader.read { try Message.filter(Column("isRead") == false).fetchCount($0) } == 1)
    }

    @Test func historyOfAChatWithNoNewsGivesItItsNewestMessagesDate() throws {
        // The chat exists without messages, as sorted last until news. A
        // restored chat has only history, and sorts by it.
        try db.conversation(with: alice)
        try db.ingest(try archived("old", body: "from long ago", at: 100, history: true))
        #expect(try conversation().lastActivityAt == Date(timeIntervalSince1970: 100))
        #expect(try db.reader.read { try Message.filter(Column("isRead") == false).fetchCount($0) } == 0)
    }

    @Test func historyIsDeduplicatedAgainstWhatWeHave() throws {
        try db.ingest(try archived("m1", body: "twice", at: 500, history: false))
        let results = try db.ingest([try archived("m1", body: "twice", at: 500, history: true)])
        #expect(results[0].newMessage == nil)
        #expect(try db.reader.read { try Message.fetchCount($0) } == 1)
        // It stays unread: history only decides about messages it adds.
        #expect(try db.reader.read { try Message.fetchOne($0)?.isRead } == false)
    }

    @Test func undecryptableHistoryIsStoredOncePlaceholderOnly() throws {
        let message = stanza("<message from='alice@example.org/phone' type='chat' id='x1'><body>🔒</body></message>")
        var inbound = try #require(InboundMessage(
            message, account: me, source: .archive(serverId: "s-x1", timestamp: Date(timeIntervalSince1970: 100)), encryption: .omemoUndecryptable,
        ))
        inbound.isHistory = true
        try db.ingest([inbound])
        try db.ingest([inbound])
        let stored = try db.reader.read { try Message.fetchAll($0) }
        #expect(stored.count == 1)
        #expect(stored[0].encryption == .omemoUndecryptable)
        #expect(stored[0].isRead)
    }

    @Test func historyCompletenessIsRememberedPerConversation() throws {
        try db.conversation(with: alice)
        let bob = YapnestKit.JID("bob@example.org")!
        try db.conversation(with: bob)
        var state = try db.historyState(peer: alice)
        #expect(!state.isComplete && state.cursor == nil)

        try db.setHistoryState(peer: alice, isComplete: false, cursor: "s-50")
        state = try db.historyState(peer: alice)
        #expect(!state.isComplete && state.cursor == "s-50")

        try db.setHistoryState(peer: alice, isComplete: true, cursor: "s-1")
        #expect(try db.historyState(peer: alice) == (true, "s-1"))
        #expect(try db.historyState(peer: bob) == (false, nil))
        // Unknown chats read as not complete rather than failing.
        #expect(try db.historyState(peer: YapnestKit.JID("nobody@example.org")!) == (false, nil))
    }

    @Test func oldestMessageIsTheEarliestStored() throws {
        #expect(try db.oldestMessage(peer: alice) == nil)
        try db.ingest(try archived("b", body: "b", at: 300, history: false))
        try db.ingest(try archived("a", body: "a", at: 100, history: true))
        #expect(try db.oldestMessage(peer: alice)?.body == "a")
    }

    // MARK: loadOlderHistory

    @Test func nothingMoreIsLoadedOnceTheArchiveIsComplete() async throws {
        let session = try makeSession(me, database: db)
        try db.ingest(try archived("m", body: "x", at: 100, history: false))
        try db.setHistoryState(peer: alice, isComplete: true, cursor: nil)
        // Even offline: there is nothing to ask for.
        #expect(try await session.loadOlderHistory(for: alice) == false)
    }

    @Test func aChatWithoutMessagesHasNothingOlder() async throws {
        let session = try makeSession(me, database: db)
        try db.conversation(with: alice)
        #expect(try await session.loadOlderHistory(for: alice) == false)
    }

    @Test func historyIsNotReadyOffline() async throws {
        let session = try makeSession(me, database: db)
        try db.ingest(try archived("m", body: "x", at: 100, history: false))
        await #expect(throws: HistoryError.notReady) { try await session.loadOlderHistory(for: alice) }
    }

    @Test func aPageIsCompleteWhenFlaggedOrEmpty() {
        typealias Page = XMPPSession.HistoryPage
        #expect(Page.isComplete(complete: true, first: "s-1"))
        #expect(Page.isComplete(complete: false, first: nil))
        #expect(Page.isComplete(complete: true, first: nil))
        #expect(!Page.isComplete(complete: false, first: "s-1"))
    }
}
