import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let bob = YapnestKit.JID("bob@example.org")!

struct RestoreChatsTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func archived(_ id: String, from sender: String = "alice@example.org", at seconds: TimeInterval, history: Bool) throws -> InboundMessage {
        let xml = "<message from='\(sender)/phone' to='me@example.org' type='chat' id='\(id)'><body>hi \(id)</body></message>"
        let message = Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
        var inbound = try #require(InboundMessage(
            message, account: me, source: .archive(serverId: "s-\(id)", timestamp: Date(timeIntervalSince1970: seconds)),
        ))
        inbound.isHistory = history
        return inbound
    }

    // MARK: When it runs

    @Test func aSyncWithoutACursorRestoresAndOneWithACursorDoesNot() {
        #expect(XMPPSession.beginsChatRestore(cursor: nil))
        #expect(!XMPPSession.beginsChatRestore(cursor: "abc"))
    }

    @Test func onlyContactsWithoutMessagesAreAsked() throws {
        try db.ingest(try archived("m", at: 1_000, history: false))
        try db.conversation(with: bob)
        let stored = try db.peersWithMessages()
        #expect(stored == [alice])
        #expect(XMPPSession.contactsToRestore(roster: [alice, bob], withMessages: stored) == [bob])
    }

    @Test func aDroppedConnectionLeavesTheRestorePending() async throws {
        let session = try makeSession(me, database: db)
        try await db.writer.write { try Contact(jid: alice, isInRoster: true).insert($0) }
        session.markChatRestorePending()
        // Never connected: the first contact isn't asked, so it isn't finished.
        await session.restoreChats(attempt: 0)
        #expect(try db.setting(.historyRestore) == "pending")
    }

    @Test func anEmptyRosterLeavesTheRestorePending() async throws {
        let session = try makeSession(me, database: db)
        session.markChatRestorePending()
        await session.restoreChats(attempt: 0)
        #expect(try db.setting(.historyRestore) == "pending")
    }

    @Test func nothingRunsUnlessASyncBeganWithoutACursor() throws {
        let session = try makeSession(me, database: db)
        #expect(try db.setting(.historyRestore) == nil)
        session.restoreChatsIfPending()
        #expect(try db.setting(.historyRestore) == nil)
    }

    // MARK: What it stores

    @Test func aRestoredChatTakesItsDateFromItsNewestMessageAndIsRead() throws {
        // A chat with news, which the restored one has to sort below.
        try db.ingest(try archived("recent", at: 5_000_000, history: false))

        let results = try db.ingest([
            try archived("old1", from: "bob@example.org", at: 1_000, history: true),
            try archived("old2", from: "bob@example.org", at: 2_000, history: true),
        ])
        #expect(results.allSatisfy { $0.newMessage != nil })

        let chats = try db.reader.read { try Conversation.order(Column("lastActivityAt").desc).fetchAll($0) }
        #expect(chats.map(\.peer) == [alice, bob])
        #expect(chats[1].lastActivityAt == Date(timeIntervalSince1970: 2_000))
        let unread = try db.reader.read { try Message.filter(Column("isRead") == false && Column("conversationId") == chats[1].id).fetchCount($0) }
        #expect(unread == 0)
    }

    @Test func historyNeverMovesAChatThatHasADate() throws {
        try db.ingest(try archived("new", at: 9_000, history: false))
        try db.ingest(try archived("old", at: 100, history: true))
        let conversation = try #require(try db.reader.read { try Conversation.fetchOne($0) })
        #expect(conversation.lastActivityAt == Date(timeIntervalSince1970: 9_000))
    }
}
