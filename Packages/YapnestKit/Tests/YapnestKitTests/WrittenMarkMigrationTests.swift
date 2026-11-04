import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct WrittenMarkMigrationTests {
    @Test func existingMessagesHaveNoWriteMark() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v59-attachment-own-file-facts")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('alice@example.org', 'chat', 0)")
            try db.execute(sql: """
                INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, remoteId)
                VALUES (1, 'outgoing', 'me@example.org', 'hi', 0, 'pending', 1, 'none', 'm1')
                """)
        }
        _ = try AppDatabase(queue)

        let message = try #require(try queue.read { try Message.fetchOne($0, key: 1) })
        #expect(message.writtenAt == nil)
        #expect(message.status == .pending)
    }
}
