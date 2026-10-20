import Foundation
@preconcurrency import Martin

/// What an item id names. The id on the wire is `raw`; an id this build
/// doesn't know, such as a kind a newer build adds, is `unknown` and is left
/// as it is.
enum SettingsItemID: Equatable, Sendable {
    case global
    case chat(JID)
    case gif(String)
    case usage(device: String)
    case unknown(String)

    init(_ raw: String) {
        if raw == "global" {
            self = .global
        } else if raw.hasPrefix("chat:"), let peer = JID(String(raw.dropFirst(5))) {
            self = .chat(peer)
        } else if raw.hasPrefix("gif:") {
            self = .gif(String(raw.dropFirst(4)))
        } else if raw.hasPrefix("usage:") {
            self = .usage(device: String(raw.dropFirst(6)))
        } else {
            self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .global: "global"
        case .chat(let peer): "chat:\(peer)"
        case .gif(let id): "gif:\(id)"
        case .usage(let device): "usage:\(device)"
        case .unknown(let raw): raw
        }
    }
}

extension Date {
    /// Whole milliseconds since 1970, which is how versions and times are written.
    var settingsMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(settingsMilliseconds ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}

/// A hybrid logical clock reading, `<ms>.<counter>` on the wire. A device
/// issues `max(now, highest seen + 1)`, so one whose clock runs behind still
/// orders its changes after those it has seen.
struct SettingsVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    var ms: Int64
    var counter: Int

    static let zero = SettingsVersion(ms: 0, counter: 0)

    init(ms: Int64, counter: Int) {
        self.ms = ms
        self.counter = counter
    }

    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let ms = Int64(parts[0]), let counter = Int(parts[1]), ms >= 0, counter >= 0 else { return nil }
        self.init(ms: ms, counter: counter)
    }

    var description: String { "\(ms).\(counter)" }

    var date: Date { Date(settingsMilliseconds: ms) }

    /// The reading to issue after this one was the highest seen.
    func next(at now: Date) -> SettingsVersion {
        let nowMs = now.settingsMilliseconds
        return nowMs > ms ? SettingsVersion(ms: nowMs, counter: 0) : SettingsVersion(ms: ms, counter: counter + 1)
    }

    static func < (a: SettingsVersion, b: SettingsVersion) -> Bool {
        (a.ms, a.counter) < (b.ms, b.counter)
    }
}

/// One setting's value in an item. No value is a tombstone: the setting is
/// back to its default, which a missing entry couldn't say.
struct SettingsEntry: Equatable, Sendable {
    var key: String
    var value: String?
    var version: SettingsVersion
    var by: String

    /// The version decides; the device id only breaks a tie, so two devices
    /// that issued the same version still agree on one winner.
    func supersedes(_ other: SettingsEntry) -> Bool {
        (version, by) > (other.version, other.by)
    }
}

/// What a `global`, `chat:`, `gif:` or other item holds. Any key is kept
/// whether or not this build knows it, so an older build never erases what a
/// newer one wrote.
struct SettingsItem: Equatable, Sendable {
    var entries: [SettingsEntry]

    init(entries: [SettingsEntry]) {
        self.entries = entries
    }

    init?(element: Element?) {
        guard let element, element.name == "settings", element.xmlns == NS.settings else { return nil }
        var newest: [String: SettingsEntry] = [:]
        for child in element.getChildren(name: "entry") {
            guard let key = child.getAttribute("key"), !key.isEmpty,
                  let version = child.getAttribute("v").flatMap(SettingsVersion.init),
                  let by = child.getAttribute("by") else { continue }
            let text = child.value
            let entry = SettingsEntry(key: key, value: text?.isEmpty == false ? text : nil, version: version, by: by)
            if let existing = newest[key], !entry.supersedes(existing) { continue }
            newest[key] = entry
        }
        self.init(entries: newest.values.sorted { $0.key < $1.key })
    }

    var content: String {
        entries.sorted { $0.key < $1.key }
            .map { "\($0.key)\u{0}\($0.value ?? "\u{1}")\u{0}\($0.version)\u{0}\($0.by)" }.joined(separator: "\n")
    }

    var element: Element {
        let settings = Element(name: "settings", xmlns: NS.settings)
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            let element = Element(name: "entry", cdata: entry.value, attributes: ["key": entry.key, "v": entry.version.description, "by": entry.by])
            settings.addChild(element)
        }
        return settings
    }
}

/// A device's emoji usage, as `<usage><emoji e score updated/></usage>`. Only
/// its own device writes one, so entries carry no version.
extension ReactionRanking {
    init?(usage element: Element?) {
        guard let element, element.name == "usage", element.xmlns == NS.settings else { return nil }
        var entries: [String: Entry] = [:]
        for child in element.getChildren(name: "emoji") {
            guard let emoji = child.getAttribute("e"), !emoji.isEmpty,
                  let score = child.getAttribute("score").flatMap(Double.init), score.isFinite, score > 0,
                  let updated = child.getAttribute("updated").flatMap(Int64.init) else { continue }
            let entry = Entry(score: score, updated: Date(settingsMilliseconds: updated))
            if let existing = entries[emoji], existing.updated >= entry.updated { continue }
            entries[emoji] = entry
        }
        self.init(entries: entries)
    }

    var usageElement: Element {
        let usage = Element(name: "usage", xmlns: NS.settings)
        for (emoji, entry) in entries.sorted(by: { $0.key < $1.key }) {
            usage.addChild(Element(name: "emoji", attributes: ["e": emoji, "score": String(entry.score), "updated": String(entry.updated.settingsMilliseconds)]))
        }
        return usage
    }
}
