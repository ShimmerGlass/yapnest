import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct OwnReactionMigrationTests {
    let alice = JID("alice@example.org")!
    let me = JID("me@example.org")!

    @Test func aPendingIdAndAnErrorMoveFromTheRowsToTheRecord() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v55-undecryptable-reason")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES (?, 'chat', 0)", arguments: [alice])
            for index in 1...3 {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, remoteId)
                    VALUES (1, 'incoming', ?, 'hi', ?, 'received', 1, 'none', ?)
                    """, arguments: [alice, Date(timeIntervalSince1970: Double(index)), "m\(index)"])
            }
            try db.execute(sql: "INSERT INTO reaction (messageId, sender, nick, emoji, pendingId) VALUES (1, ?, '', '👍', 'P')", arguments: [me])
            try db.execute(sql: "INSERT INTO reaction (messageId, sender, nick, emoji, error) VALUES (2, ?, '', '👍', 'Nope')", arguments: [me])
            try db.execute(sql: "INSERT INTO reaction (messageId, sender, nick, emoji) VALUES (3, ?, '', '👍')", arguments: [me])
        }
        let database = try AppDatabase(queue)

        let records = try queue.read { try OwnReaction.order(Column("messageId")).fetchAll($0) }
        #expect(records.map(\.messageId) == [1, 2])
        #expect(records.map(\.pendingId) == ["P", nil])
        #expect(records.map(\.error) == [nil, "Nope"])
        let columns = try queue.read { try $0.columns(in: "reaction").map(\.name) }
        #expect(!columns.contains("pendingId") && !columns.contains("error"))
        #expect(try queue.read { try Reaction.fetchCount($0) } == 3)
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items.map(\.ownReactions) == [.pending, .failed("Nope"), nil])
    }
}
