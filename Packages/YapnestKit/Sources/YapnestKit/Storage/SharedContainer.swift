import Foundation
import os

/// Where the app and its extensions keep what they share: the accounts'
/// databases and files, and the lock that keeps them from running a session at
/// the same time.
public enum SharedContainer {
    /// The app group, from the `YapnestAppGroup` key the app's and both extensions'
    /// Info.plist set from the bundle id.
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "YapnestAppGroup") as? String ?? "group.fr.yapnest.app"

    /// The group's container, or the process's own Application Support where
    /// there is none (tests, unsigned builds).
    public static var url: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        return (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    public static var accounts: URL { accounts(in: url) }

    /// The diagnostics log's folder, which the app and both extensions write.
    public static var logs: URL { logs(in: url) }

    /// The same inside another container, for a test's own.
    static func accounts(in container: URL) -> URL { container.appending(path: "accounts") }
    static func logs(in container: URL) -> URL { container.appending(path: "Logs") }

    /// Everything of one account: its database, avatars and files.
    public static func directory(for account: JID) -> URL {
        accounts.appending(path: account.description)
    }

    public static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    private static let deviceIdKey = "yapnest.deviceId"

    /// A stable per-install id, which tells this device's resources apart.
    public static var deviceId: String {
        if let id = existingDeviceId { return id }
        // Kept in the app's own defaults before the extension needed it.
        let id = UserDefaults.standard.string(forKey: deviceIdKey) ?? String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(id, forKey: deviceIdKey)
        return id
    }

    /// Signing out takes the id away, so the next account's resource doesn't
    /// tell its server it is the same install as the last one's.
    public static func forgetDeviceId() {
        defaults.removeObject(forKey: deviceIdKey)
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
    }

    /// The id, if the app made one: the extension doesn't.
    public static var existingDeviceId: String? { defaults.string(forKey: deviceIdKey) }

    /// Held by whichever process has a session open.
    public static var sessionLock: ProcessLock { ProcessLock(url: url.appending(path: "session.lock")) }

    /// Held by the app for as long as it holds or waits for the session lock,
    /// so the extensions can tell the app is running without reading anything
    /// the holder of the session lock writes after taking it.
    public static var appLock: ProcessLock { ProcessLock(url: url.appending(path: "app.lock")) }
}

/// An exclusive lock between processes (flock), released when the holder
/// exits, even by crashing.
public final class ProcessLock: @unchecked Sendable {
    private let url: URL
    private let fd = OSAllocatedUnfairLock<Int32>(initialState: -1)
    /// Where `waitForLock` blocks. A wait can last 30 seconds, and the
    /// cooperative pool has about a thread per core, so it must not be one of
    /// its threads.
    private let waitQueue = DispatchQueue(label: "fr.yapnest.process-lock-wait", qos: .userInitiated)

    public init(url: URL) {
        self.url = url
    }

    deinit { unlock() }

    /// Waits up to `timeout` for the lock. Blocks: call it off the main thread.
    public func lock(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryLock() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// `lock(timeout:as:)` for async code: it polls on a queue of its own and
    /// resumes when it has the lock or the time is up.
    public func waitForLock(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            waitQueue.async { continuation.resume(returning: self.lock(timeout: timeout)) }
        }
    }

    public func tryLock() -> Bool {
        fd.withLock { fd in
            if fd >= 0 { return true }
            let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard opened >= 0 else { return false }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                close(opened)
                return false
            }
            fd = opened
            return true
        }
    }

    /// Whether another open of this file holds the lock. Meant for the app's
    /// lock, which the app takes before it waits for the session lock and
    /// lets go of with it, so a failure here means the app is running. The
    /// lock is only tried, and let go of at once.
    public var appIsRunning: Bool {
        let reader = open(url.path, O_RDONLY | O_CLOEXEC)
        guard reader >= 0 else { return false }
        defer { close(reader) }
        if flock(reader, LOCK_SH | LOCK_NB) == 0 {
            flock(reader, LOCK_UN)
            return false
        }
        return true
    }

    public var isLocked: Bool { fd.withLock { $0 >= 0 } }

    public func unlock() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
}

/// How the account's files are protected at rest: unreadable after a restart
/// until the first unlock, then readable while locked, which the notification
/// and share extensions need. It's iOS's default for an app's files, set here
/// so that nothing depends on the default, or on what a folder was given.
public enum FileProtection {
    public static let level = FileProtectionType.completeUntilFirstUserAuthentication

    /// Gives `url` the protection, a folder's being what new files in it
    /// take. A file system without it (a simulator) leaves the attribute off.
    public static func apply(to url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: level], ofItemAtPath: url.path)
    }
}

extension FileManager {
    /// Creates `directory` if needed, with the account's file protection.
    public func createProtectedDirectory(at directory: URL) throws {
        try createDirectory(at: directory, withIntermediateDirectories: true)
        FileProtection.apply(to: directory)
    }
}
