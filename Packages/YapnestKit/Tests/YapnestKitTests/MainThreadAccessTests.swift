import Foundation
import os
import GRDB
import Testing
@testable import YapnestKit

/// Serialized: the check is process-wide state.
@Suite(.serialized)
struct MainThreadAccessTests {
    private func open() throws -> AppDatabase {
        try AppDatabase.open(at: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/db.sqlite"))
    }

    private func count(isolation: isolated (any Actor)? = #isolation, during body: () async throws -> Void) async rethrows -> Int {
        let hits = OSAllocatedUnfairLock(initialState: 0)
        AppDatabase.mainThreadAccessHandler = { hits.withLock { $0 += 1 } }
        AppDatabase.trapsMainThreadAccess = true
        defer {
            AppDatabase.trapsMainThreadAccess = false
            AppDatabase.mainThreadAccessHandler = nil
        }
        try await body()
        return hits.withLock { $0 }
    }

    @Test @MainActor func readingOnTheMainThreadIsCaught() async throws {
        let db = try open()
        let hits = try await count { try db.reader.read { db in _ = try Int.fetchOne(db, sql: "SELECT 1") } }
        #expect(hits > 0)
    }

    @Test @MainActor func writingOnTheMainThreadIsCaught() async throws {
        let db = try open()
        let hits = try await count { try db.writer.write { db in try db.execute(sql: "SELECT 1") } }
        #expect(hits > 0)
    }

    @Test func workOffTheMainThreadIsNot() async throws {
        let db = try open()
        let hits = try await count {
            try await Task.detached { try db.reader.read { db in _ = try Int.fetchOne(db, sql: "SELECT 1") } }.value
        }
        #expect(hits == 0)
    }

    @Test @MainActor func observationsFirstFetchIsOffTheMainThread() async throws {
        let db = try open()
        let hits = try await count {
            let counts = db.observeUnreadCounts()
            for try await _ in counts.values(in: db.reader, bufferingPolicy: .bufferingNewest(1)) { break }
        }
        #expect(hits == 0)
    }

    @Test func switchedOffByDefault() throws {
        let db = try open()
        #expect(!AppDatabase.trapsMainThreadAccess)
        try db.reader.read { _ in }
    }
}
