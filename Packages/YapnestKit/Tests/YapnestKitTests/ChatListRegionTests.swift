import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The chat list and the badge are watched by the tables they read, which
/// are listed by hand. A table left out would leave them stale after a
/// change there, so these compare the lists with what the fetches read.
struct ChatListRegionTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
        // A message with a file, so every part of the fetch runs.
        let id = try db.conversation(with: alice).id!
        let message = try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "hi", timestamp: Date(timeIntervalSince1970: 1), remoteId: "m1"))
        try db.writer.write { db in
            try Attachment(messageId: message.id!, url: "https://example.org/a.png", name: "a.png", mimeType: "image/png", state: .pendingUpload).insert(db)
        }
    }

    /// The region GRDB itself works out from what `fetch` reads.
    private func readRegion(_ fetch: @escaping @Sendable (Database) throws -> Void) async throws -> DatabaseRegion {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var region: DatabaseRegion?
        }
        let box = Box()
        let observation = ValueObservation.tracking { db in try fetch(db) }
            .handleEvents(willTrackRegion: { region in box.lock.withLock { box.region = region } })
            .start(in: db.writer, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { _ in })
        defer { observation.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let region = box.lock.withLock({ box.region }) { return region }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    /// Tables whose change the fetch's own reads would notice but `watched` wouldn't.
    private func missing(from watched: [any DatabaseRegionConvertible], reading fetch: @escaping @Sendable (Database) throws -> Void) async throws -> [String] {
        let read = try await readRegion(fetch)
        return try await db.writer.read { db in
            var declared = DatabaseRegion()
            for table in watched { declared.formUnion(try table.databaseRegion(db)) }
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            return tables.filter { table in
                read.isModified(byEventsOfKind: .insert(tableName: table)) && !declared.isModified(byEventsOfKind: .insert(tableName: table))
            }
        }
    }

    @Test func theChatListWatchesEveryTableItReads() async throws {
        #expect(try await missing(from: AppDatabase.chatListTables) { _ = try ChatListItem.fetch($0, archived: false) } == [])
    }

    @Test func theBadgeWatchesEveryTableItReads() async throws {
        #expect(try await missing(from: AppDatabase.unreadBadgeTables) { _ = try AppDatabase.unreadCounts($0, archived: false) } == [])
    }
}
