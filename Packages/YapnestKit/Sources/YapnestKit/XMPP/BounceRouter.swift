import Foundation

/// The item a stanza is for, as its owner names it. A newer stanza for the same
/// item replaces an older one, whose bounce no longer says anything about it.
enum BounceKey: Hashable {
    case message(String)
    case action(Int64)
    case reactions(Int64)
}

/// Who owns a stanza we wrote, so the error that bounces it finds its way back.
/// A message, a correction, a retraction or reactions each carry an id of their
/// own, and a server answers one that it can't deliver with an error of that
/// id, usually long after stream management acknowledged it.
///
/// It lives in memory and forgets an entry `lifetime` after the stanza was
/// written. Bounces come within seconds, a minute at most. One that arrives
/// after the app restarted is not matched here: a message still gets its
/// failure from ingest, which finds it by id in the database, and for the rest
/// the sender is better off with an unmarked edit than with the database
/// keeping every stanza id for ever.
struct BounceRouter {
    /// What a bounce leads to.
    enum Outcome {
        /// May pass: the owner makes its item pending again. `passes` is how
        /// many times this item has bounced like this.
        case retry(passes: Int)
        /// Won't pass, or has bounced `maxPasses` times: shown to the user.
        case fail(ServerError)
    }

    struct Owner {
        var key: BounceKey
        /// The bare address the stanza went to. An error from elsewhere than
        /// there or a server (an address without a local part) isn't taken.
        var peer: JID
        var handle: @Sendable (Outcome) -> Void
    }

    private struct Entry {
        var owner: Owner
        var expires: Date
    }

    /// The bounce that makes this many for an item is final, so a passing one
    /// is tried again `maxPasses - 1` times.
    static let maxPasses = 3
    static let lifetime: TimeInterval = 15 * 60
    /// Expired entries are swept out in bulk once there are this many, and
    /// then again when the live ones have doubled.
    static let pruneThreshold = 256

    private var entries: [String: Entry] = [:]
    /// The stanza each item last wrote, to replace it in one step.
    private var idForKey: [BounceKey: String] = [:]
    private var passes: [BounceKey: Int] = [:]
    private var nextPrune = BounceRouter.pruneThreshold
    private(set) var pruneRuns = 0

    /// Writing the stanza `id` again keeps its place and its pass count; a
    /// different id for the same item takes over from the old one, with a
    /// count of its own.
    mutating func register(_ id: String, _ owner: Owner, now: Date = Date()) {
        if let old = idForKey[owner.key], old != id {
            entries[old] = nil
            passes[owner.key] = nil
        }
        idForKey[owner.key] = id
        entries[id] = Entry(owner: owner, expires: now.addingTimeInterval(Self.lifetime))
        if entries.count > nextPrune {
            prune(now)
            nextPrune = max(Self.pruneThreshold, entries.count * 2)
        }
    }

    /// The user retried an item under the same id: its earlier bounces don't count.
    mutating func forget(_ key: BounceKey) {
        passes[key] = nil
    }

    /// Takes the owner of `id` if `from` may answer for it, and what the error
    /// means for it. Nil if the stanza isn't one we know of.
    mutating func route(_ id: String, from: JID?, account: JID, error: ServerError, now: Date = Date()) -> (owner: Owner, outcome: Outcome)? {
        guard let entry = entries[id] else { return nil }
        guard entry.expires > now else {
            drop(id, entry)
            return nil
        }
        guard Self.mayAnswer(from, peer: entry.owner.peer, account: account) else { return nil }
        entries[id] = nil
        let owner = entry.owner
        guard error.isPassing else {
            finish(owner.key)
            return (owner, .fail(error))
        }
        let count = (passes[owner.key] ?? 0) + 1
        guard count < Self.maxPasses else {
            finish(owner.key)
            return (owner, .fail(error))
        }
        passes[owner.key] = count
        return (owner, .retry(passes: count))
    }

    /// Only the peer, the servers either side of it, and our own account may
    /// say a stanza of ours bounced: any other domain could fail or resend our
    /// stanzas by guessing, or reading, their ids. A stanza without a sender
    /// is from our own server.
    private static func mayAnswer(_ from: JID?, peer: JID, account: JID) -> Bool {
        guard let from else { return true }
        if from.localPart == nil { return from.domain == peer.domain || from.domain == account.domain }
        return from == peer || from == account
    }

    private mutating func finish(_ key: BounceKey) {
        passes[key] = nil
        idForKey[key] = nil
    }

    private mutating func drop(_ id: String, _ entry: Entry) {
        entries[id] = nil
        if idForKey[entry.owner.key] == id { finish(entry.owner.key) }
    }

    private mutating func prune(_ now: Date) {
        pruneRuns += 1
        for (id, entry) in entries where entry.expires <= now { drop(id, entry) }
    }
}
