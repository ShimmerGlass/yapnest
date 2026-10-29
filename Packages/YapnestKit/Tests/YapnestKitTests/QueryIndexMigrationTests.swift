import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct QueryIndexMigrationTests {
    let alice = JID("alice@example.org")!

    /// The statements triggers ran while `body` did: SQLite reports each of a
    /// trigger's statements to the trace, prefixed with `--`, once its WHEN
    /// has let it run.
    private func triggered(_ db: AppDatabase, _ body: () throws -> Void) throws -> [String] {
        let lines = Collected<String>()
        try db.writer.write { database in
            database.trace { event in
                if case .statement(let statement) = event, statement.sql.hasPrefix("--") { lines.add(statement.sql) }
            }
        }
        try body()
        try db.writer.write { $0.trace(options: .statement, nil) }
        return lines.all
    }

    @Test func aChangeOfStatusDoesNotIndexTheMessageAgain() throws {
        let db = try AppDatabase.inMemory()
        let conversation = try db.conversation(with: alice).id!
        var message = try db.insert(Message(conversationId: conversation, direction: .outgoing, sender: JID("me@example.org")!, body: "hello there", remoteId: "r1"))

        let status = try triggered(db) {
            message.status = .delivered
            try db.writer.write { try message.update($0) }
        }
        #expect(!status.contains { $0.contains("INTO messageSearch") }, "\(status)")

        let body = try triggered(db) {
            message.body = "hello again"
            try db.writer.write { try message.update($0) }
        }
        #expect(body.contains { $0.contains("INTO messageSearch") }, "a new body is indexed")
        #expect(try db.searchMessages("again", in: nil, limit: 10).map(\.messageId) == [message.id!])
        #expect(try db.searchMessages("there", in: nil, limit: 10).isEmpty)

        message.isRetracted = true
        try db.writer.write { try message.update($0) }
        #expect(try db.searchMessages("again", in: nil, limit: 10).isEmpty, "a retraction takes it out")
        try db.writer.write { try $0.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('integrity-check')") }
    }

    @Test func aDatabaseFromBeforeTheIndicesKeepsItsDataAndGetsThem() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v49-group-roster")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES (?, 'chat', 0)", arguments: [alice])
            for index in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, serverId)
                    VALUES (1, 'incoming', ?, ?, ?, 'received', ?, 'none', ?)
                    """, arguments: [alice, "body \(index)", Date(timeIntervalSince1970: Double(index)), index == 0 ? 1 : 0, "s\(index)"])
            }
        }
        let db = try AppDatabase(queue)
        #expect(try db.unreadMessageCount(peer: alice) == 2)
        let found = try db.searchMessages("body", in: nil, limit: 10)
        #expect(found.count == 3)
        let names = try queue.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'message'") }
        #expect(names.contains("message_on_conversation_serverId"))
        #expect(!names.contains("message_on_serverId"))
        let message = try #require(try db.writer.read { try AppDatabase.duplicate(of: Message(conversationId: 1, direction: .incoming, sender: alice, body: "", serverId: "s2"), $0) })
        #expect(message.body == "body 2")
        try queue.write { try $0.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('integrity-check')") }
    }

    @Test func aMessageAConversationOwnedGoesWithItsPendingEdits() throws {
        let db = try AppDatabase.inMemory()
        let conversation = try db.conversation(with: alice).id!
        let message = try db.insert(Message(conversationId: conversation, direction: .incoming, sender: alice, body: "x", remoteId: "r1"))
        try db.writer.write { database in
            try database.execute(sql: """
                INSERT INTO pendingEdit (conversationId, ref, kind, outgoing, sender, encryption, createdAt, editedAt, standInId)
                VALUES (?, 'r0', 'correction', 0, ?, 'none', 0, 0, ?)
                """, arguments: [conversation, alice, message.id])
            try database.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [conversation])
        }
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingEdit") } == 0)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message") } == 0)
    }
}
