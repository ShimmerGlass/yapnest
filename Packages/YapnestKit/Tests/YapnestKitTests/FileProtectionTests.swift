import Foundation
import Testing
@testable import YapnestKit

/// The account's folders carry the file protection that the files made in
/// them take. A folder made without it reports none on the Mac, where these
/// run; a simulator reports none either way.
struct FileProtectionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "protection-\(UUID().uuidString)")

    private func protection(of url: URL) -> FileProtectionType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
    }

    @Test func theAccountsFoldersAndDatabaseAreProtected() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountDirectory(url: root.appending(path: "account"))
        let database = try account.openDatabase()
        try database.setSetting(.lastArchiveId, "x")
        #expect(protection(of: account.url) == FileProtection.level)
        for suffix in ["", "-wal", "-shm"] {
            #expect(protection(of: account.url.appending(path: "db.sqlite" + suffix)) == FileProtection.level, "db.sqlite\(suffix)")
        }

        _ = try account.attachments.save(Data([1]), name: "a.txt")
        #expect(protection(of: account.attachments.directory) == FileProtection.level)
    }

    @Test func theLogsFolderIsProtected() {
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(path: "Logs")
        let store = DiagnosticsStore(directory: logs, process: .app)
        store.append(date: Date(), category: .app, level: .info, text: "x")
        store.flush()
        #expect(protection(of: logs) == FileProtection.level)
    }
}
