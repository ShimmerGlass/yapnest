import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// A build installed over a newer one's data ran its code over it: build 7
/// over build 10's made a new encryption key while the keychain held the
/// device's, and contacts' clients stopped encrypting to the iPhone.
struct DowngradeTests {
    @Test func aDatabaseANewerBuildMigratedIsRefused() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999-from-a-newer-build')") }
        #expect(throws: AppDatabaseError.createdByNewerVersion) { try AppDatabase(queue) }
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v999-from-a-newer-build'") } != nil)
    }

    @Test func aDatabaseThisBuildMigratedOpensAgain() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue)
    }

    /// v24 was dropped from the code once, while every install made before
    /// then had run it, and their databases were refused as a newer build's.
    @Test func aDatabaseFromBeforeAMigrationWasDroppedOpens() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v23-last-seen")
        try queue.write { db in
            try db.alter(table: "groupInvitation") { t in t.add(column: "isMediated", .boolean).notNull().defaults(to: true) }
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v24-invitation-mediation')")
        }
        _ = try AppDatabase(queue)
        #expect(try queue.read { try $0.tableExists("groupRoster") })
    }

    /// A database made while v24 was missing gets it now, and opens again.
    @Test func aDatabaseMadeWithoutAMigrationGetsIt() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        try queue.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v24-invitation-mediation'") }
        _ = try AppDatabase(queue)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v24-invitation-mediation'") } != nil)
    }

    @Test func anOlderBuildsDatabaseIsMigrated() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v47-addresses-me")
        _ = try AppDatabase(queue)
        #expect(try queue.read { try $0.tableExists("heldGroupMessage") })
    }
}
