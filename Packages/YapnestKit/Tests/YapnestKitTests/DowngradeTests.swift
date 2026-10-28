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

    @Test func anOlderBuildsDatabaseIsMigrated() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v47-addresses-me")
        _ = try AppDatabase(queue)
        #expect(try queue.read { try $0.tableExists("heldGroupMessage") })
    }
}
