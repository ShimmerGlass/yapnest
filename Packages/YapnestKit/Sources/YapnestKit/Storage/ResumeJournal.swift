import Foundation
@preconcurrency import Martin

/// A stanza the notification extension consumed from the app's stream that the app has to see live,
/// kept as it was read.
public struct JournalEntry: Codable, Equatable, Sendable {
    /// The stream it was read on, so that a journal can't be applied to another one.
    public var stream: String?
    /// When it was read, as the server's own `<delay>` may be missing from a stanza that arrived live.
    public var at: Date
    public var xml: String

    public init(stream: String?, at: Date, xml: String) {
        self.stream = stream
        self.at = at
        self.xml = xml
    }
}

/// What the app reads back.
public struct JournalContents: Equatable, Sendable {
    public var entries: [JournalEntry]
    /// False if the journal overflowed, a write failed, or the file is cut off: what it holds is true, but
    /// something may be missing from it, so the app's stream can't be resumed on its strength.
    public var isComplete: Bool
}

/// The extension consumes what the server queued for the app's stream, which the app, resuming it, would
/// have been sent: the journal keeps what the app's modules do something about live and the extension
/// doesn't store, and the app feeds it to them when it returns.
///
/// One file beside the ticket, a JSON object per line, appended as stanzas are read and before stream
/// management counts them, so none is acknowledged without being kept. It has the ticket's protection and
/// is never logged: it is the account's traffic. Only the holder of the session lock writes or reads it.
public final class ResumeJournal: @unchecked Sendable {
    /// What a journal may hold before it stops keeping more. Presences are a few hundred bytes and messages
    /// a few thousand, and a wake lasts seconds, so this is hundreds of stanzas, more than a stream sees
    /// in the minutes a push is outstanding; a flood past it means the app is a long way behind, and a new
    /// session, which reads the archive, is the better way back.
    public static let defaultCapacity = 512 * 1024

    private let store: ResumeTicketStore
    private let capacity: Int
    private let lock = NSLock()
    private var size: Int?
    private var lostState = false
    /// Open for the wake, as a stanza a second is a write each.
    private var handle: FileHandle?

    public init(store: ResumeTicketStore, capacity: Int = ResumeJournal.defaultCapacity) {
        self.store = store
        self.capacity = capacity
    }

    /// Whether this journal, or an earlier wake's that it goes on, is missing something.
    public var isLost: Bool { lock.withLock { lostState } }

    /// Adds `entry`, or marks the journal incomplete if it doesn't fit or can't be written.
    public func append(_ entry: JournalEntry) {
        lock.withLock {
            if size == nil {
                size = (try? FileManager.default.attributesOfItem(atPath: store.journalURL.path)[.size] as? Int) ?? 0
                if store.journalEndsIncomplete() { lostState = true }
            }
            guard !lostState, let line = Self.line(JournalLine(entry: entry)) else { return }
            if (size ?? 0) + line.count > capacity || !write(line) { markLost() }
        }
    }

    private func markLost() {
        lostState = true
        if let line = Self.line(JournalLine(lost: true)) { _ = write(line) }
    }

    /// Lets go of the file once the wake is over. A later `append` opens it again.
    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    private func write(_ line: Data) -> Bool {
        let file = store.journalURL
        do {
            if handle == nil {
                if FileManager.default.fileExists(atPath: file.path) {
                    handle = try FileHandle(forWritingTo: file)
                    try handle?.seekToEnd()
                } else {
                    // Created whole, with its protection and out of backups, which the handle then adds to.
                    guard store.writeProtected(line, at: file) else { return false }
                    handle = try FileHandle(forWritingTo: file)
                    try handle?.seekToEnd()
                    size = (size ?? 0) + line.count
                    return true
                }
            }
            try handle?.write(contentsOf: line)
        } catch {
            try? handle?.close()
            handle = nil
            return false
        }
        size = (size ?? 0) + line.count
        return true
    }

    fileprivate struct JournalLine: Codable {
        var entry: JournalEntry?
        var lost: Bool?
    }

    fileprivate static func line(_ line: JournalLine) -> Data? {
        guard var data = try? JSONEncoder().encode(line) else { return nil }
        data.append(0x0A)
        return data
    }
}

extension ResumeTicketStore {
    var journalURL: URL { url.deletingLastPathComponent().appending(path: "stream-journal.jsonl") }

    /// What an extension kept; nothing, and complete, if no wake wrote any.
    public func readJournal() -> JournalContents {
        guard let data = try? Data(contentsOf: journalURL) else { return JournalContents(entries: [], isComplete: true) }
        var entries: [JournalEntry] = []
        var isComplete = true
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let decoded = try? decoder.decode(ResumeJournal.JournalLine.self, from: Data(line)) else {
                // A write the process didn't live to finish.
                isComplete = false
                break
            }
            if let entry = decoded.entry { entries.append(entry) }
            if decoded.lost == true { isComplete = false }
        }
        return JournalContents(entries: entries, isComplete: isComplete)
    }

    /// Whether an earlier wake left the journal cut off or marked lost, from its end alone: a lost marker
    /// is the last line written, and nothing is appended after one or after a torn line, so the whole file
    /// needn't be decoded to know.
    func journalEndsIncomplete() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: journalURL) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        guard (try? handle.seek(toOffset: size - 1)) != nil, let last = try? handle.read(upToCount: 1), last == Data([0x0A]) else { return true }
        // The last line: back to the newline before it, in chunks, as an entry can be thousands of bytes.
        var end = size - 1
        var line = Data()
        while end > 0 {
            let start = end > 4096 ? end - 4096 : 0
            guard (try? handle.seek(toOffset: start)) != nil, let chunk = try? handle.read(upToCount: Int(end - start)) else { return true }
            if let newline = chunk.lastIndex(of: 0x0A) {
                line = chunk[(newline + 1)...] + line
                break
            }
            line = chunk + line
            end = start
        }
        guard let decoded = try? JSONDecoder().decode(ResumeJournal.JournalLine.self, from: line) else { return true }
        return decoded.lost == true
    }

    public func deleteJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }
}

extension ResumeJournal {
    /// Whether the app has to see `stanza`, which the extension has read live: what its modules act on and
    /// the extension doesn't store.
    ///
    /// Kept: presences (contacts', and rooms' occupants, which decide who a room message came from);
    /// messages of a room we are in and its errors; pubsub events (avatars, nicknames, bookmarks, device
    /// lists, settings, read state), which the modules apply live; and call signals, also in a carbon.
    ///
    /// Not kept: a 1:1 message, which the extension stores like the app would (a chat state or receipt
    /// in it is moot by the time the app returns); any iq, as the modules answer a request, so replayed
    /// it would be answered a second time, and an error bounced for one that was long since handled.
    /// The extension answers them on the stream itself, and its roster module has written a roster push
    /// to the database, which the app's reads; the block list is only held in memory, so the app reads
    /// it again when it resumes after an extension (`replayJournal`). An iq result or error answers the
    /// extension's own request; and anything of the stream itself (`r`, `a`, `resumed`) is no one's.
    public static func keeps(_ element: Element, isRoom: (JID) -> Bool) -> Bool {
        switch element.name {
        case "presence":
            return true
        case "message":
            // What the extension asked the archive for comes back as stanzas of the room's or the account's, and
            // belongs to its query.
            if element.children.contains(where: { $0.name == "result" && ($0.xmlns?.hasPrefix("urn:xmpp:mam:") ?? false) }) { return false }
            if element.getAttribute("type") == "groupchat" { return true }
            if let from = element.getAttribute("from").flatMap({ JID($0) }), isRoom(from) { return true }
            if element.findChild(name: "event", xmlns: pubsubEvent) != nil { return true }
            return containsCallSignal(element)
        default:
            return false
        }
    }

    static let pubsubEvent = "http://jabber.org/protocol/pubsub#event"

    /// A Jingle message, bare or in a carbon's forwarded copy.
    static func containsCallSignal(_ element: Element) -> Bool {
        if element.children.contains(where: { $0.xmlns == CallSignal.namespace }) { return true }
        return element.children
            .first { $0.xmlns == "urn:xmpp:carbons:2" }?
            .firstChild(name: "forwarded", xmlns: "urn:xmpp:forward:0")?
            .firstChild(name: "message")?
            .children.contains { $0.xmlns == CallSignal.namespace } ?? false
    }

    /// Names the stamps this process wrote when it replayed a journal, which a sender can't guess and
    /// so can't forge: it is made when the app starts and never stored or sent.
    private static let replayToken = UUID().uuidString

    /// Whether `delay` is a stamp `replayable` wrote. It dates a stanza the app is handling as live, which
    /// a room's or a server's own delay (history on joining) says it is not.
    static func isReplayStamp(_ delay: Element) -> Bool {
        delay.getAttribute("replay") == replayToken
    }

    /// The element to feed the app's modules, dated by when it was read, as its timestamp and a call's
    /// freshness are read from its `<delay>`: made now, a message read hours ago would sort after what
    /// came since and a call offer would ring. `stamper` is the one that vouches for it (the room, or the
    /// account's server), `offset` how far the server's clock is ahead of ours.
    ///
    /// The delays that stamper's name is on, and those of `server` (which stamps what it held for a stream
    /// it resumes, on any stanza, whoever vouches for its time), are replaced by one, the earlier of the time it was read and
    /// what they said: a sender can write a stamp in the future with the server's name, and the latest of
    /// the trusted stamps is the one that counts. The stamp is a replay's (`isReplayStamp`), so that the
    /// stanza, which the app would have been sent live, isn't taken for history as a delayed one is.
    static func replayable(_ entry: JournalEntry, stamper: (Element) -> String, server: String? = nil, offset: TimeInterval) -> Element? {
        guard let element = Element.from(string: entry.xml), element.name == "message" else { return Element.from(string: entry.xml) }
        let vouching = stamper(element)
        let read = entry.at.addingTimeInterval(offset)
        func source(_ delay: Element) -> String? { delay.getAttribute("from").flatMap { JID($0)?.description } }
        // A carbon's inner message is the sender's too, and takes the wrapper's stamp when it is handled.
        let inner = element.children.first { $0.xmlns == "urn:xmpp:carbons:2" }?
            .firstChild(name: "forwarded", xmlns: "urn:xmpp:forward:0")?.firstChild(name: "message")
        var earliest = read
        for holder in [element, inner].compactMap({ $0 }) {
            for delay in holder.filterChildren(name: "delay", xmlns: NS.delay) where source(delay) == vouching || source(delay) == server {
                if source(delay) == vouching, let stamp = Delay(element: delay).stamp { earliest = min(earliest, stamp) }
                holder.removeChild(delay)
            }
        }
        let delay = Element(name: "delay", xmlns: NS.delay)
        delay.setAttribute("from", value: vouching)
        delay.setAttribute("stamp", value: ISO8601DateFormatter().string(from: earliest))
        delay.setAttribute("replay", value: replayToken)
        element.addChild(delay)
        return element
    }
}
