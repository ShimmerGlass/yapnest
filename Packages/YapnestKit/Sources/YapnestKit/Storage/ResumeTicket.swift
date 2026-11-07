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
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeTicket.self, from: data)
    }

    /// Writes the stream atomically and returns the generation it got, or nil
    /// if the file couldn't be written (the next process then opens its own
    /// session, which is always safe).
    @discardableResult
    public func save(_ stream: StreamManagementModule.Snapshot) -> UInt64? {
        let previous = load()?.generation ?? 0
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        let ticket = ResumeTicket(generation: max(previous &+ 1, now), stream: stream)
        do {
            try FileManager.default.createProtectedDirectory(at: url.deletingLastPathComponent())
            try JSONEncoder().encode(ticket).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = url
            try? file.setResourceValues(values)
            return ticket.generation
        } catch {
            delete()
            return nil
        }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A call that came in live while an extension held the app's stream, which
/// the app rings for when it returns: iOS rings only from a live `propose`,
/// and the extension consumed this one, so the app's new session would only
/// read it back from the archive. Held like the ticket, and never logged.
public struct CallHandover: Codable, Equatable, Sendable {
    public var sid: String
    public var sender: String
    public var recipient: String
    public var from: String?
    /// `audio` and `video`, as the propose names them.
    public var media: [String]
    public var timestamp: Date

    public init(sid: String, sender: String, recipient: String, from: String?, media: [String], timestamp: Date) {
        self.sid = sid
        self.sender = sender
        self.recipient = recipient
        self.from = from
        self.media = media
        self.timestamp = timestamp
    }
}

extension ResumeTicketStore {
    /// Beside the ticket, and handled under the same session lock.
    var handoverURL: URL { url.deletingLastPathComponent().appending(path: "call-handover.json") }

    public func handovers() -> [CallHandover] {
        guard let data = try? Data(contentsOf: handoverURL) else { return [] }
        return (try? JSONDecoder().decode([CallHandover].self, from: data)) ?? []
    }

    private func write(_ handovers: [CallHandover]) {
        guard !handovers.isEmpty else { return deleteHandovers() }
        do {
            try FileManager.default.createProtectedDirectory(at: handoverURL.deletingLastPathComponent())
            try JSONEncoder().encode(handovers).write(to: handoverURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = handoverURL
            try? file.setResourceValues(values)
        } catch {
            deleteHandovers()
        }
    }

    /// Adds a call, forgetting those too old to ring and any earlier note of the same one.
    public func addHandover(_ handover: CallHandover, ringWindow: TimeInterval, now: Date = Date()) {
        var all = handovers().filter { $0.sid != handover.sid && now.timeIntervalSince($0.timestamp) < ringWindow }
        all.append(handover)
        write(all)
    }

    /// The call ended, or was answered elsewhere.
    public func removeHandover(sid: String) {
        let all = handovers()
        guard all.contains(where: { $0.sid == sid }) else { return }
        write(all.filter { $0.sid != sid })
    }

    /// What the app rings for, once: the file goes with it.
    public func takeHandovers() -> [CallHandover] {
        defer { deleteHandovers() }
        return handovers()
    }

    public func deleteHandovers() {
        try? FileManager.default.removeItem(at: handoverURL)
    }
}
