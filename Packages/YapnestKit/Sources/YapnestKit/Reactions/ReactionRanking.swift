import Foundation
import GRDB

/// Which reactions the user reaches for, so the long-press menu's quick row
/// can offer them. Each pick adds one point that halves every two weeks: a
/// new favourite overtakes an old one within a few uses, and one left alone
/// drifts down and out. Only the score at the time of the last pick is kept,
/// and decayed when read, so nothing needs touching as time passes.
public struct ReactionRanking: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The score as of `updated`.
        public var score: Double
        public var updated: Date
    }

    /// What the quick row shows when nothing has been picked, in this order.
    public static let defaults = ["👍", "❤️", "😂", "😮", "😢"]
    public static let rowSize = 5
    public static let halfLife: TimeInterval = 14 * 24 * 3600
    /// An entry that has decayed below this is forgotten (about nine
    /// half-lives after a single pick), which keeps the stored set small.
    public static let forgetBelow = 0.002
    /// A hard bound for someone who picks many different emoji.
    public static let capacity = 64

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public func score(of emoji: String, at now: Date) -> Double {
        entries[emoji].map { Self.decayed($0, at: now) } ?? 0
    }

    /// Counts a pick. Taking a reaction back isn't subtracted: it says nothing
    /// against the emoji, and a score that could go down would let one
    /// mis-tap and its undo cost more than they gave.
    public mutating func record(_ emoji: String, at now: Date) {
        guard !emoji.isEmpty else { return }
        entries[emoji] = Entry(score: score(of: emoji, at: now) + 1, updated: now)
        prune(at: now)
    }

    /// The row: the highest scores first, ties going to the more recent pick
    /// and then to the defaults' order. Each default starts with a prior (see
    /// `prior(of:)`), so one stray pick doesn't push a default out, but two
    /// close together do, and a pick that has faded falls back below them.
    public func row(at now: Date) -> [String] {
        let order = Self.defaults
        var candidates = Set(order)
        for (emoji, entry) in entries where Self.decayed(entry, at: now) >= Self.forgetBelow { candidates.insert(emoji) }
        return candidates
            .map { (emoji: $0, score: score(of: $0, at: now) + Self.prior(of: $0), updated: entries[$0]?.updated ?? .distantPast) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.updated != b.updated { return a.updated > b.updated }
                let (x, y) = (order.firstIndex(of: a.emoji), order.firstIndex(of: b.emoji))
                if x != y { return (x ?? .max) < (y ?? .max) }
                return a.emoji < b.emoji
            }
            .prefix(Self.rowSize)
            .map(\.emoji)
    }

    /// Every emoji still remembered, the highest score first and, on equal
    /// scores, the more recent pick. Unlike `row`, defaults get no prior: this
    /// is for ordering a longer list by how much each has actually been used.
    public func byScore(at now: Date) -> [String] {
        entries
            .filter { Self.decayed($0.value, at: now) >= Self.forgetBelow }
            .map { (emoji: $0.key, score: Self.decayed($0.value, at: now), updated: $0.value.updated) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.updated != b.updated { return a.updated > b.updated }
                return a.emoji < b.emoji
            }
            .map(\.emoji)
    }

    /// Lifts an emoji's score to `score` if it holds less, without counting a pick.
    mutating func raise(_ emoji: String, to score: Double, at now: Date) {
        guard !emoji.isEmpty, self.score(of: emoji, at: now) < score else { return }
        entries[emoji] = Entry(score: score, updated: now)
        prune(at: now)
    }

    /// What a default is worth before anything is picked: a constant that
    /// doesn't decay, a little less for each place down the defaults so
    /// their order holds. Between one pick (1) and two (about 2).
    public static func prior(of emoji: String) -> Double {
        guard let index = defaults.firstIndex(of: emoji) else { return 0 }
        return defaultPrior - Double(index) * priorStep
    }

    public static let defaultPrior = 1.5
    public static let priorStep = 0.01

    /// Every ranking's scores added at one time, which is what one device
    /// would hold had it seen all the picks. Each emoji is added up as of its
    /// newest pick, so the sum keeps when that was, which breaks ties in `row`.
    public static func summed(_ rankings: [ReactionRanking], at now: Date) -> ReactionRanking {
        var total: [String: Entry] = [:]
        let emoji = Set(rankings.flatMap { $0.entries.keys })
        for e in emoji {
            let entries = rankings.compactMap { $0.entries[e] }
            guard let newest = entries.map(\.updated).max() else { continue }
            let entry = Entry(score: entries.reduce(0) { $0 + decayed($1, at: newest) }, updated: newest)
            if decayed(entry, at: now) >= forgetBelow { total[e] = entry }
        }
        return ReactionRanking(entries: total)
    }

    /// Whether every emoji has faded out, so the device that held it has
    /// been silent long enough for its item to go.
    public func isForgotten(at now: Date) -> Bool {
        entries.values.allSatisfy { Self.decayed($0, at: now) < Self.forgetBelow }
    }

    /// Keeps, for each emoji, the larger of the two scores as of `now`. An
    /// emptied ranking therefore can't wipe what the server holds. Scores
    /// decay by the same factor, so the larger now stays the larger.
    mutating func merge(_ other: ReactionRanking, at now: Date) {
        var merged: [String: Entry] = [:]
        for e in Set(entries.keys).union(other.entries.keys) {
            let mine = entries[e], theirs = other.entries[e]
            let winner = (mine.map { Self.decayed($0, at: now) } ?? 0) >= (theirs.map { Self.decayed($0, at: now) } ?? 0) ? mine : theirs
            if let winner, Self.decayed(winner, at: now) >= Self.forgetBelow { merged[e] = winner }
        }
        entries = merged
        prune(at: now)
    }

    /// Whether this holds something `other` lacks or has less of at `now`.
    func exceeds(_ other: ReactionRanking, at now: Date) -> Bool {
        entries.contains { e, entry in
            let mine = Self.decayed(entry, at: now)
            return mine >= Self.forgetBelow && mine > other.score(of: e, at: now) * (1 + 1e-9)
        }
    }

    private mutating func prune(at now: Date) {
        entries = entries.filter { Self.decayed($0.value, at: now) >= Self.forgetBelow }
        guard entries.count > Self.capacity else { return }
        let weakest = entries.sorted { score(of: $0.key, at: now) < score(of: $1.key, at: now) }
        for (emoji, _) in weakest.prefix(entries.count - Self.capacity) { entries[emoji] = nil }
    }

    private static func decayed(_ entry: Entry, at now: Date) -> Double {
        entry.score * pow(0.5, max(0, now.timeIntervalSince(entry.updated)) / halfLife)
    }
}

extension AppDatabase {
    /// This device's own ranking. Other devices' rankings are in
    /// `remoteUsage`; `emojiRanking` adds them all.
    public func reactionRanking() -> ReactionRanking {
        (try? reader.read { try Self.ownRanking($0) }) ?? ReactionRanking()
    }

    /// What readers rank by: every device's picks added up.
    public func emojiRanking(at now: Date = Date()) -> ReactionRanking {
        let rankings = (try? reader.read { db in
            [try Self.ownRanking(db)] + (try Self.remoteRankings(db))
        }) ?? []
        return ReactionRanking.summed(rankings, at: now)
    }

    /// Counts a pick, in one transaction so two writers can't lose each other's.
    @discardableResult
    public func recordEmojiPick(_ emoji: String, at now: Date = Date()) throws -> ReactionRanking {
        try writer.write { db in
            var ranking = try Self.ownRanking(db)
            ranking.record(emoji, at: now)
            try Self.storeOwnRanking(db, ranking)
            try Self.markOwnUsageDirty(db)
            return ranking
        }
    }

    /// Takes in the shortcode recents kept before emoji usage was synced, once
    /// per account. Each counts as a fraction of a pick, the first (most recent)
    /// the most, so one real pick outranks them and none can displace a default.
    /// Scores already held stay when they are higher.
    @discardableResult
    public func importEmojiRecents(_ recents: [String], at now: Date = Date()) throws -> Bool {
        try writer.write { db in
            guard try Self.setting(db, .emojiRecentsImported) == nil else { return false }
            var ranking = try Self.ownRanking(db)
            let before = ranking
            for (index, emoji) in recents.enumerated() {
                ranking.raise(emoji, to: max(0.5 - Double(index) * 0.01, 0.01), at: now)
            }
            if ranking != before {
                try Self.storeOwnRanking(db, ranking)
                try Self.markOwnUsageDirty(db)
            }
            try Self.setSetting(db, .emojiRecentsImported, "1")
            return true
        }
    }

    /// Other devices whose every emoji has faded out: any device retracts
    /// their items.
    func forgottenUsageDevices(at now: Date = Date()) throws -> [String] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT deviceId, json FROM remoteUsage").compactMap { row in
                let ranking = Self.decodeRanking(row["json"]) ?? ReactionRanking()
                return ranking.isForgotten(at: now) ? row["deviceId"] as String : nil
            }
        }
    }

    static func ownRanking(_ db: Database) throws -> ReactionRanking {
        decodeRanking(try setting(db, .reactionRanking)) ?? ReactionRanking()
    }

    private static func remoteRankings(_ db: Database) throws -> [ReactionRanking] {
        try String.fetchAll(db, sql: "SELECT json FROM remoteUsage").compactMap(decodeRanking)
    }

    static func decodeRanking(_ json: String?) -> ReactionRanking? {
        json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder.reactionRanking.decode(ReactionRanking.self, from: $0) }
    }

    static func encodeRanking(_ ranking: ReactionRanking) throws -> String {
        String(decoding: try JSONEncoder.reactionRanking.encode(ranking), as: UTF8.self)
    }

    static func storeOwnRanking(_ db: Database, _ ranking: ReactionRanking) throws {
        try setSetting(db, .reactionRanking, try encodeRanking(ranking))
    }
}

extension JSONEncoder {
    static var reactionRanking: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var reactionRanking: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
