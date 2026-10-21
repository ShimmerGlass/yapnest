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

    public static var accounts: URL { url.appending(path: "accounts") }

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

    /// The id, if the app made one: the extension doesn't.
    public static var existingDeviceId: String? { defaults.string(forKey: deviceIdKey) }

    /// Held by whichever process has a session open.
    public static var sessionLock: ProcessLock { ProcessLock(url: url.appending(path: "session.lock")) }
}

/// An exclusive lock between processes (flock), released when the holder
/// exits, even by crashing.
public final class ProcessLock: @unchecked Sendable {
    /// Who holds the lock, for the others to tell whether waiting is worth it.
    public enum Role: String, Sendable {
        case app, share, notification
    }

    private let url: URL
    private let fd = OSAllocatedUnfairLock<Int32>(initialState: -1)

    public init(url: URL) {
        self.url = url
    }

    deinit { unlock() }

    /// Waits up to `timeout` for the lock. Blocks: call it off the main thread.
    public func lock(timeout: TimeInterval, as role: Role? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryLock(as: role) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    public func tryLock(as role: Role? = nil) -> Bool {
        fd.withLock { fd in
            if fd >= 0 { return true }
            let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard opened >= 0 else { return false }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                close(opened)
                return false
            }
            fd = opened
            // The file's contents are the holder's role. Wiped first, as
            // what's there is the last holder's, which says nothing now.
            _ = ftruncate(opened, 0)
            if let bytes = role?.rawValue.data(using: .utf8) {
                _ = bytes.withUnsafeBytes { pwrite(opened, $0.baseAddress, bytes.count, 0) }
            }
            return true
        }
    }

    /// The role the current holder took the lock as, or nil if nobody holds
    /// it or it didn't say. The record is only believed while the lock is
    /// held: a holder that crashed leaves its role behind, but the system
    /// released its lock, so we can take it ourselves and know it's stale.
    public var holder: Role? {
        let reader = open(url.path, O_RDONLY | O_CLOEXEC)
        guard reader >= 0 else { return nil }
        defer { close(reader) }
        if flock(reader, LOCK_SH | LOCK_NB) == 0 {
            flock(reader, LOCK_UN)
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = pread(reader, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Role(rawValue: String(decoding: buffer[..<count], as: UTF8.self))
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
