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
                let existing = store.readJournal()
                size = (try? FileManager.default.attributesOfItem(atPath: store.journalURL.path)[.size] as? Int) ?? 0
                if !existing.isComplete { lostState = true }
            }
            guard !lostState, let line = Self.line(JournalLine(entry: entry)) else { return }
            if (size ?? 0) + line.count > capacity || !write(line) { markLost() }
        }
    }

    private func markLost() {
        lostState = true
        if let line = Self.line(JournalLine(lost: true)) { _ = write(line) }
    }

    private func write(_ line: Data) -> Bool {
        let file = store.journalURL
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                return false
            }
        } else if !store.writeProtected(line, at: file) {
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
    /// lists, settings, read state), which the modules apply live; call signals, also in a carbon; and a
    /// roster or block list push, which the app's modules hold in memory.
    ///
    /// Not kept: a 1:1 message, which the extension stores like the app would (a chat state or receipt
    /// in it is moot by the time the app returns); an iq request, which the extension answers on the
    /// stream, so that the app answering as well would be a second answer; an iq result or error, which
    /// answers the extension's own request; and anything of the stream itself (`r`, `a`, `resumed`).
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
        case "iq":
            guard element.getAttribute("type") == "set" else { return false }
            return element.findChild(name: "query", xmlns: "jabber:iq:roster") != nil
                || element.findChild(name: "block", xmlns: blocking) != nil
                || element.findChild(name: "unblock", xmlns: blocking) != nil
        default:
            return false
        }
    }

    static let pubsubEvent = "http://jabber.org/protocol/pubsub#event"
    static let blocking = "urn:xmpp:blocking"

    /// A Jingle message, bare or in a carbon's forwarded copy.
    static func containsCallSignal(_ element: Element) -> Bool {
        if element.children.contains(where: { $0.xmlns == CallSignal.namespace }) { return true }
        return element.children
            .first { $0.xmlns == "urn:xmpp:carbons:2" }?
            .firstChild(name: "forwarded", xmlns: "urn:xmpp:forward:0")?
            .firstChild(name: "message")?
            .children.contains { $0.xmlns == CallSignal.namespace } ?? false
    }

    /// The element to feed the app's modules, with the time it was read in a `<delay>` if it came without
    /// one it trusts, as its timestamp and a call's freshness are read from there: made now, a message read hours ago
    /// would sort after what came since and a call offer would ring. `stamper` is the one that vouches
    /// for it (the room, or the account's server), `offset` how far the server's clock is ahead of ours.
    static func replayable(_ entry: JournalEntry, stamper: (Element) -> String, offset: TimeInterval) -> Element? {
        guard let element = Element.from(string: entry.xml) else { return nil }
        let vouching = stamper(element)
        let isStamped = element.filterChildren(name: "delay", xmlns: NS.delay).contains { $0.getAttribute("from").flatMap { JID($0)?.description } == vouching }
        guard element.name == "message", !isStamped else { return element }
        let delay = Element(name: "delay", xmlns: NS.delay)
        delay.setAttribute("from", value: vouching)
        delay.setAttribute("stamp", value: ISO8601DateFormatter().string(from: entry.at.addingTimeInterval(offset)))
        element.addChild(delay)
        return element
    }
}
