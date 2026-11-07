import Foundation
@preconcurrency import Martin

/// What an extension needs to resume the app's XEP-0198 stream instead of
/// opening a session of its own: closing a session the server counts as the
/// account's makes it publish a push for the app's hibernated one, which wakes
/// the extension again.
///
/// The resumption id, with the account's credentials, takes over the stream,
/// so the file has the database's protection and is never logged or backed up.
/// Only the holder of the session lock reads or writes it.
public struct ResumeTicket: Codable, Equatable, Sendable {
    /// Rises with every write, and across deletions, so a process that saved
    /// one can tell whether another has written since: the clock stands in
    /// for a counter the file would have lost with it.
    public var generation: UInt64
    public var stream: StreamManagementModule.Snapshot
    /// Set by an extension that resumed the app's stream: the server's `h` when the first of them did,
    /// which says how many of the app's own stanzas had arrived by then. The stream's own `resumedH`
    /// is the latest wake's, which counts the earlier wakes' stanzas too. Nil in the app's own ticket.
    public var appHandled: UInt32?
    /// An extension couldn't keep a complete journal of what it consumed (`ResumeJournal`), so the app
    /// can't resume the stream without losing some of it.
    public var journalLost: Bool = false
}

/// One account's ticket, in its directory.
public struct ResumeTicketStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(directory: AccountDirectory) {
        self.init(url: directory.resumeTicketURL)
    }

    public func load() -> ResumeTicket? {
        Self.read(ResumeTicket.self, at: url)
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes atomically, with the account's protection, and out of backups.
    /// A file that couldn't be written is removed, so no stale one is left.
    func writeProtected(_ data: Data, at file: URL) -> Bool {
        do {
            try FileManager.default.createProtectedDirectory(at: file.deletingLastPathComponent())
            try data.write(to: file, options: .atomic)
            FileProtection.apply(to: file)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = file
            try? excluded.setResourceValues(values)
            return true
        } catch {
            try? FileManager.default.removeItem(at: file)
            return false
        }
    }

    /// Writes the stream atomically and returns the generation it got, or nil
    /// if the file couldn't be written (the next process then opens its own
    /// session, which is always safe).
    @discardableResult
    public func save(_ stream: StreamManagementModule.Snapshot, appHandled: UInt32? = nil, journalLost: Bool = false) -> UInt64? {
        let previous = load()?.generation ?? 0
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        let ticket = ResumeTicket(generation: max(previous &+ 1, now), stream: stream, appHandled: appHandled, journalLost: journalLost)
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        return writeProtected(data, at: url) ? ticket.generation : nil
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
