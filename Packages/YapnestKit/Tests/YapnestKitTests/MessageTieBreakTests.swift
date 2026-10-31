import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// Two messages can carry the same timestamp (a server stamps to the second),
/// and every query for "the newest" has to pick the same one: the later row.
struct MessageTieBreakTests {
    let alice = JID("alice@example.org")!

    private func database() throws -> (AppDatabase, Int64, [Message]) {
        let db = try AppDatabase.inMemory()
        let chat = try #require(try db.conversation(with: alice).id)
        let at = Date(timeIntervalSince1970: 1000)
        var inserted: [Message] = []
        for index in 0..<3 {
            inserted.append(try db.insert(Message(
                conversationId: chat, direction: .incoming, sender: alice, body: "m\(index)", timestamp: at,
                remoteId: "r\(index)", serverId: "s\(index)",
            )))
        }
        return (db, chat, inserted)
    }

    @Test func theNewestIncomingIsTheLaterRowOnATie() throws {
        let (db, chat, messages) = try database()
        #expect(try db.lastIncoming(conversationId: chat)?.id == messages[2].id)
    }

    @Test func theLatestServerIdsStartWithTheLaterRowOnATie() throws {
        let (db, _, _) = try database()
        #expect(try db.lastServerIds(from: alice, limit: 3) == ["s2", "s1", "s0"])
    }

    @Test func markingUnreadPicksTheLaterRowOnATie() throws {
        let (db, chat, messages) = try database()
        try db.writer.write { try AppDatabase.markRead($0, conversationId: chat, through: .distantFuture) }
        try db.markUnread(conversationId: chat)
        let unread = try db.reader.read { try Message.filter(Column("isRead") == false).fetchAll($0).map(\.id) }
        #expect(unread == [messages[2].id])
    }
}
