import Foundation

/// Discord-style `:shortcode:` lookup for the composer. Pure, so the
/// trigger rules and ranking are testable without a text view.
public struct EmojiShortcodes: Sendable {
    public struct Entry: Sendable, Equatable {
        public let emoji: String
        public let aliases: [String]
        public let keywords: [String]
    }

    public struct Match: Sendable, Equatable {
        public let emoji: String
        /// The alias that matched, shown as `:shortcode:`.
        public let shortcode: String
    }

    /// A `:query` being typed: where it sits in the text, in UTF-16 units
    /// like `NSRange`, and what follows the colon.
    public struct Trigger: Sendable, Equatable {
        public let range: NSRange
        public let query: String
    }

    public static let minimumQueryLength = 2

    /// Loaded on first use; the file is small, but nothing needs it before
    /// someone types a colon.
    public static let shared: EmojiShortcodes = {
        guard let url = Bundle.module.url(forResource: "emoji-shortcodes", withExtension: "tsv", subdirectory: "Emoji"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return EmojiShortcodes(entries: []) }
        return EmojiShortcodes(tsv: text)
    }()

    private let entries: [Entry]
    private let byAlias: [String: Entry]

    public init(entries: [Entry]) {
        self.entries = entries
        var byAlias: [String: Entry] = [:]
        for entry in entries {
            for alias in entry.aliases where byAlias[alias] == nil { byAlias[alias] = entry }
        }
        self.byAlias = byAlias
    }

    /// One emoji per line: the emoji, its aliases and its keywords, tab
    /// separated, the lists comma separated. File order stands in for how
    /// common an emoji is, as gemoji lists faces and gestures first.
    public init(tsv: String) {
        let entries = tsv.split(whereSeparator: \.isNewline).compactMap { line -> Entry? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let aliases = fields[1].split(separator: ",").map(String.init)
            guard !aliases.isEmpty else { return nil }
            let keywords = fields.count > 2 ? fields[2].split(separator: ",").map(String.init) : []
            return Entry(emoji: String(fields[0]), aliases: aliases, keywords: keywords)
        }
        self.init(entries: entries)
    }

    // MARK: Triggers

    private static func isQueryCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        let character = Character(scalar)
        return character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }

    /// A colon only opens a shortcode at the start of a word, so times,
    /// URLs and "a:b" are left alone.
    private static func canOpenShortcode(before index: Int, in text: NSString) -> Bool {
        guard index > 0 else { return true }
        guard let scalar = Unicode.Scalar(text.character(at: index - 1)) else { return false }
        let previous = Character(scalar)
        return previous.isWhitespace || "([{<".contains(previous)
    }

    /// The `:query` ending at the cursor, if it's long enough to look up.
    public static func trigger(in text: String, cursor: Int) -> Trigger? {
        let string = text as NSString
        guard cursor >= 0, cursor <= string.length else { return nil }
        var start = cursor
        while start > 0, isQueryCharacter(string.character(at: start - 1)) { start -= 1 }
        guard start > 0, string.character(at: start - 1) == 0x3A else { return nil }
        let colon = start - 1
        guard cursor - start >= minimumQueryLength, canOpenShortcode(before: colon, in: string) else { return nil }
        return Trigger(range: NSRange(location: colon, length: cursor - colon), query: string.substring(with: NSRange(location: start, length: cursor - start)))
    }

    /// A complete `:code:` just before the cursor that names a known emoji,
    /// with the range to replace.
    public func completedShortcode(in text: String, cursor: Int) -> (range: NSRange, emoji: String)? {
        let string = text as NSString
        guard cursor >= 1, cursor <= string.length, string.character(at: cursor - 1) == 0x3A,
              let trigger = Self.trigger(in: text, cursor: cursor - 1),
              let entry = byAlias[trigger.query.lowercased()]
        else { return nil }
        return (NSRange(location: trigger.range.location, length: trigger.range.length + 1), entry.emoji)
    }

    // MARK: Ranking

    /// Up to `limit` emoji for a query: shortcodes starting with it, then
    /// containing it, then keywords. Within each group recently used emoji
    /// come first, then shorter and earlier-listed ones. `recents` is
    /// most recent first.
    public func matches(for query: String, recents: [String] = [], limit: Int = 8) -> [Match] {
        let query = query.lowercased()
        guard query.count >= Self.minimumQueryLength else { return [] }
        struct Scored { var match: Match; var group: Int; var recent: Int; var length: Int; var index: Int }
        var scored: [Scored] = []
        for (index, entry) in entries.enumerated() {
            var best: (group: Int, alias: String)?
            for alias in entry.aliases {
                let group: Int
                if alias.hasPrefix(query) {
                    group = 0
                } else if alias.contains(query) {
                    group = 1
                } else {
                    continue
                }
                if best == nil || group < best!.group || (group == best!.group && alias.count < best!.alias.count) {
                    best = (group, alias)
                }
            }
            if best == nil, entry.keywords.contains(where: { $0.contains(query) }) {
                best = (2, entry.aliases[0])
            }
            guard let best else { continue }
            let recent = recents.firstIndex(of: entry.emoji) ?? Int.max
            scored.append(Scored(match: Match(emoji: entry.emoji, shortcode: best.alias), group: best.group, recent: recent, length: best.alias.count, index: index))
        }
        scored.sort {
            ($0.group, $0.recent, $0.length, $0.index) < ($1.group, $1.recent, $1.length, $1.index)
        }
        return scored.prefix(limit).map(\.match)
    }
}
