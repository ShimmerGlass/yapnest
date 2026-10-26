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

    @Test func turningItOffExcludesBothFoldersAndOnClearsThem() throws {
        let (account, logs) = (try folder(), try folder())
        BackupPolicy.apply(included: false, to: [account, logs])
        #expect(try isExcluded(account))
        #expect(try isExcluded(logs))
        BackupPolicy.apply(included: true, to: [account, logs])
        #expect(try !isExcluded(account))
        #expect(try !isExcluded(logs))
    }

    @Test func aFolderThatDoesNotExistIsSkipped() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        BackupPolicy.apply(included: false, to: [missing])
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func accountFoldersAndLogsFollowTheChoiceWhenItChanges() throws {
        let container = try folder()
        let account = container.appending(path: "accounts/me@example.org")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let defaults = defaults()
        let logs = SharedContainer.logs(in: container)

        BackupPolicy.setIncludesMessages(false, defaults: defaults, container: container)
        #expect(try isExcluded(account))
        #expect(try isExcluded(logs))
        BackupPolicy.setIncludesMessages(true, defaults: defaults, container: container)
        #expect(try !isExcluded(account))
        #expect(try !isExcluded(logs))
    }

    @Test func aFolderMadeLaterPicksTheChoiceUpAtTheNextSweep() throws {
        let container = try folder()
        let defaults = defaults()
        BackupPolicy.setIncludesMessages(false, defaults: defaults, container: container)
        let later = SharedContainer.accounts(in: container).appending(path: "new@example.org")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        #expect(try !isExcluded(later))
        BackupPolicy.apply(defaults: defaults, container: container)
        #expect(try isExcluded(later))
    }

    @Test func openingAnAccountFolderAppliesTheChoice() throws {
        let directory = AccountDirectory(url: try folder())
        _ = try directory.openDatabase()
        #expect(try isExcluded(directory.url) == !BackupPolicy.includesMessages())
    }
}
