import Foundation

/// What the server may be holding back from us while we're inactive
/// (XEP-0352). It keeps only the newest PEP notification per node and sender,
/// so a node with an item per chat, room or setting loses changes, and what we
/// read again on returning is owed from the moment we said we were inactive.
///
/// Read states are read again at every return. Bookmarks and settings cost a
/// fetch each, so they are read again at most once a `slowInterval`: a return
/// inside the window leaves them owed for when it ends.
struct HeldNotifications: Sendable {
    static let slowInterval: TimeInterval = 60

    enum Slow: Sendable, Equatable {
        case none
        case now
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
    private(set) var readStatesOwed = false
    private(set) var slowOwed = false
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
            readStatesOwed = true
            slowOwed = true
        }
        guard readStatesOwed || slowOwed else { return nil }
        let readStates = readStatesOwed
        readStatesOwed = false
        var slow = Slow.none
        if slowOwed {
            let wait = lastSlow.map { Self.slowInterval - now.timeIntervalSince($0) } ?? 0
            if wait <= 0 {
                slowOwed = false
                lastSlow = now
                slow = .now
            } else {
                slow = .after(wait)
            }
        }
        return Refresh(generation: generation, readStates: readStates, slow: slow)
    }

    /// The end of a wait `sent` asked for: whether the bookmarks and settings
    /// are still owed, and due.
    mutating func takeSlow(generation: Int, now: Date = Date()) -> Bool {
        guard generation == self.generation, slowOwed else { return false }
        if let lastSlow, now.timeIntervalSince(lastSlow) < Self.slowInterval { return false }
        slowOwed = false
        lastSlow = now
        return true
    }

    /// A refresh that failed is owed again at the next return, at once.
    mutating func failed(readStates: Bool, slow: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if readStates { readStatesOwed = true }
        if slow {
            slowOwed = true
            lastSlow = nil
        }
    }

    /// A new session's catch-up reads everything.
    mutating func reset() {
        generation += 1
        inactiveSince = nil
        readStatesOwed = false
        slowOwed = false
        lastSlow = nil
    }
}
