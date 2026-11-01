import Foundation
import Testing
@testable import YapnestKit

struct BackupPolicyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isExcluded(_ url: URL) throws -> Bool {
        try URL(filePath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    /// The flag is an extended attribute, which a file system under heavy load
    /// has been seen to show late (a full run of the suite).
    private func isExcluded(_ url: URL, eventually expected: Bool) async throws -> Bool {
        try await eventually { try isExcluded(url) == expected }
    }

    private func defaults() -> UserDefaults {
        let name = "backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func messagesAreIncludedByDefault() {
        #expect(BackupPolicy.includesMessages(in: defaults()))
    }

    @Test func theChoiceIsKept() {
        let defaults = defaults()
        defaults.set(false, forKey: BackupPolicy.key)
        #expect(!BackupPolicy.includesMessages(in: defaults))
    }

    @Test func turningItOffExcludesBothFoldersAndOnClearsThem() async throws {
        let (account, logs) = (try folder(), try folder())
        BackupPolicy.apply(included: false, to: [account, logs])
        #expect(try await isExcluded(account, eventually: true))
        #expect(try await isExcluded(logs, eventually: true))
        BackupPolicy.apply(included: true, to: [account, logs])
        #expect(try await isExcluded(account, eventually: false))
        #expect(try await isExcluded(logs, eventually: false))
    }

    @Test func aFolderThatDoesNotExistIsSkipped() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        BackupPolicy.apply(included: false, to: [missing])
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func accountFoldersAndLogsFollowTheChoiceWhenItChanges() async throws {
        let container = try folder()
        let account = container.appending(path: "accounts/me@example.org")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let defaults = defaults()
        let logs = SharedContainer.logs(in: container)

        BackupPolicy.setIncludesMessages(false, defaults: defaults, container: container)
        #expect(try await isExcluded(account, eventually: true))
        #expect(try await isExcluded(logs, eventually: true))
        BackupPolicy.setIncludesMessages(true, defaults: defaults, container: container)
        #expect(try await isExcluded(account, eventually: false))
        #expect(try await isExcluded(logs, eventually: false))
    }

    @Test func aFolderMadeLaterPicksTheChoiceUpAtTheNextSweep() async throws {
        let container = try folder()
        let defaults = defaults()
        BackupPolicy.setIncludesMessages(false, defaults: defaults, container: container)
        let later = SharedContainer.accounts(in: container).appending(path: "new@example.org")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        #expect(try !isExcluded(later))
        BackupPolicy.apply(defaults: defaults, container: container)
        #expect(try await isExcluded(later, eventually: true))
    }

    @Test func openingAnAccountFolderAppliesTheChoice() throws {
        let directory = AccountDirectory(url: try folder())
        _ = try directory.openDatabase()
        #expect(try isExcluded(directory.url) == !BackupPolicy.includesMessages())
    }
}
