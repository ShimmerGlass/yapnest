import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct GroupRosterMigrationTests {
    @Test func theRosterKeepsOnlyMembersAndEveryGroupCountsAfresh() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v57-signed-prekey-published")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('cake@rooms.example.org', 'group', 0)")
            try db.execute(sql: "INSERT INTO groupRoster (conversationId, key, nick, jid, isPresent, hasLeft) VALUES (1, 'bob@example.org', 'Bob', 'bob@example.org', 1, 0)")
            try db.execute(sql: "INSERT INTO groupRosterTaken (conversationId, listed) VALUES (1, 1)")
        }
        let database = try AppDatabase(queue)

        let (columns, members, baselines) = try queue.read { db in
            (try db.columns(in: "groupRoster").map(\.name),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM groupRoster"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM groupRosterTaken"))
        }
        #expect(columns == ["conversationId", "jid"])
        #expect(members == 0 && baselines == 0)
        let bob = JID("bob@example.org")!
        let afterDelete = try database.writer.write { db -> Int? in
            try db.execute(sql: "INSERT INTO groupRoster (conversationId, jid) VALUES (1, ?)", arguments: [bob])
            try db.execute(sql: "DELETE FROM conversation")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM groupRoster")
        }
        #expect(afterDelete == 0, "it goes with its conversation")
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('x@rooms.example.org', 'group', 0)")
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM conversation")!
            try db.execute(sql: "INSERT INTO groupRoster (conversationId, jid) VALUES (?, ?)", arguments: [id, bob])
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO groupRoster (conversationId, jid) VALUES (?, ?)", arguments: [id, bob])
            }
        }
    }
}
