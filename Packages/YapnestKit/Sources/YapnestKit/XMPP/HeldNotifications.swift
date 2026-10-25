import Foundation

/// What the server may be holding back from us while we're inactive
/// (XEP-0352). It keeps only the newest PEP notification per node and sender,
/// so a node with an item per chat, room or setting loses changes, and what we
/// read again on returning is owed from the moment we said we were inactive.
///
/// Read states are read again at every return. Bookmarks and settings cost a
/// fetch each, so they are read again at most once a `slowInterval`: a return
/// inside the window leaves them owed for when it ends. Each is owed on its
/// own, so only the read that failed is done again.
struct HeldNotifications: Sendable {
    static let slowInterval: TimeInterval = 60

    /// The reads that can be owed.
    struct Parts: OptionSet, Sendable {
        let rawValue: Int
        static let readStates = Parts(rawValue: 1)
        static let bookmarks = Parts(rawValue: 2)
        static let settings = Parts(rawValue: 4)
        static let slow: Parts = [.bookmarks, .settings]
        static let all: Parts = [.readStates, .bookmarks, .settings]
    }

    enum Slow: Sendable, Equatable {
        case none
        /// Read these now.
        case now(Parts)
        case after(TimeInterval)
    }

    struct Refresh: Sendable, Equatable {
        var generation: Int
        var readStates: Bool
        var slow: Slow
    }

    /// Counts sessions, so a failure reported by an earlier one's request is ignored.
    private(set) var generation = 0
    private var inactiveSince: Date?
    private(set) var owed: Parts = []
    private var lastSlow: Date?

    /// Whether we have told the server we're inactive and not active since.
    var isHolding: Bool { inactiveSince != nil }

    /// The state we just sent. Inactive starts a hold; active turns it into
    /// what's owed, and says what to read now.
    mutating func sent(active: Bool, now: Date = Date()) -> Refresh? {
        guard active else {
            inactiveSince = inactiveSince ?? now
            return nil
        }
        if inactiveSince != nil {
            inactiveSince = nil
            owed = .all
        }
        guard !owed.isEmpty else { return nil }
        let readStates = owed.contains(.readStates)
        owed.remove(.readStates)
        var slow = Slow.none
        let due = owed.intersection(.slow)
        if !due.isEmpty {
            let wait = lastSlow.map { Self.slowInterval - now.timeIntervalSince($0) } ?? 0
            if wait <= 0 {
                owed.subtract(due)
                lastSlow = now
                slow = .now(due)
            } else {
                slow = .after(wait)
            }
        }
        return Refresh(generation: generation, readStates: readStates, slow: slow)
    }

    /// The end of a wait `sent` asked for: the bookmarks and settings that are
    /// still owed, if the window is up.
    mutating func takeSlow(generation: Int, now: Date = Date()) -> Parts {
        let due = owed.intersection(.slow)
        guard generation == self.generation, !due.isEmpty else { return [] }
        if let lastSlow, now.timeIntervalSince(lastSlow) < Self.slowInterval { return [] }
        owed.subtract(due)
        lastSlow = now
        return due
    }

    /// A read that failed is owed again at the next return, at once.
    mutating func failed(_ parts: Parts, generation: Int) {
        guard generation == self.generation else { return }
        owed.formUnion(parts)
        if !parts.isDisjoint(with: .slow) { lastSlow = nil }
    }

    /// A new session's catch-up reads everything.
    mutating func reset() {
        generation += 1
        inactiveSince = nil
        owed = []
        lastSlow = nil
    }
}
