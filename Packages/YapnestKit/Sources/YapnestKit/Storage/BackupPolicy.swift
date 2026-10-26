import Foundation

/// Whether this device's messages and files go into its backups (iCloud
/// Backup, computer backups, Time Machine), which the user chooses.
///
/// The choice is kept in the app group's `UserDefaults`, not in the database:
/// backups are per device, so it mustn't sync, and the database is inside
/// the folder the choice excludes, so it couldn't be read before the folder is
/// opened, nor survive a restore that leaves the folder out. The group's
/// defaults sit outside the excluded folders and are restored with the app.
public enum BackupPolicy {
    static let key = "yapnest.includesMessagesInBackups"

    /// On unless turned off.
    public static func includesMessages(in defaults: UserDefaults = SharedContainer.defaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Saves the choice and applies it to every account folder and the log
    /// folder at once.
    public static func setIncludesMessages(
        _ included: Bool, defaults: UserDefaults = SharedContainer.defaults, container: URL = SharedContainer.url,
    ) {
        defaults.set(included, forKey: key)
        apply(defaults: defaults, container: container)
    }

    /// Makes the account folders (and `also`, one just made or opened) and
    /// `SharedContainer.url/Logs` follow the choice. Called whenever an account
    /// folder is opened, so a folder made after a restore or reinstall picks it
    /// up and the flag can't drift. The flag on a folder covers what is inside it.
    ///
    /// `container` is where the account folders and `Logs` live, a test's own.
    public static func apply(
        also extra: [URL] = [], defaults: UserDefaults = SharedContainer.defaults, container: URL = SharedContainer.url,
    ) {
        let logs = container.appending(path: "Logs")
        try? FileManager.default.createProtectedDirectory(at: logs)
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: container.appending(path: "accounts"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles,
        )) ?? []
        apply(included: includesMessages(in: defaults), to: accounts + extra + [logs])
    }

    /// Sets or clears the exclusion on each folder that exists, leaving alone
    /// one that already has it right.
    static func apply(included: Bool, to folders: [URL]) {
        for var folder in folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // A URL remembers what it read, and the flag may have changed since.
            folder.removeAllCachedResourceValues()
            if (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == !included { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = !included
            // A file system that can't mark a folder (a simulator's) has no
            // backup to leave it out of, and the next open tries again.
            try? folder.setResourceValues(values)
        }
    }
}
