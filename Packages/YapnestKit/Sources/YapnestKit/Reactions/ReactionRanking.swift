import Foundation

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

    /// What a default is worth before anything is picked: a constant that
    /// doesn't decay, a little less for each place down the defaults so
    /// their order holds. Between one pick (1) and two (about 2).
    public static func prior(of emoji: String) -> Double {
        guard let index = defaults.firstIndex(of: emoji) else { return 0 }
        return defaultPrior - Double(index) * priorStep
    }

    public static let defaultPrior = 1.5
    public static let priorStep = 0.01

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
    public func reactionRanking() -> ReactionRanking {
        guard let json = try? setting(.reactionRanking), let data = json.data(using: .utf8),
              let ranking = try? JSONDecoder.reactionRanking.decode(ReactionRanking.self, from: data)
        else { return ReactionRanking() }
        return ranking
    }

    /// Counts a pick, in one transaction so two writers can't lose each other's.
    @discardableResult
    public func recordReactionPick(_ emoji: String, at now: Date = Date()) throws -> ReactionRanking {
        try updateJSONSetting(.reactionRanking, default: ReactionRanking(), decoder: .reactionRanking, encoder: .reactionRanking) { ranking in
            ranking.record(emoji, at: now)
            return ranking
        }
    }
}

private extension JSONEncoder {
    static var reactionRanking: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var reactionRanking: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
