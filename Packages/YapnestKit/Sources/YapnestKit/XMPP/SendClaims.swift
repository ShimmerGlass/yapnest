import Foundation

/// Which of our messages the send queue has taken up, so an edit or a
/// retraction knows whether the message can still be changed before it goes.
///
/// A message stays `.pending` until the server acknowledges it, which is after
/// it was written, so its status can't say. The queue claims a message when it
/// starts to build it, and the decision to change it or send a correction is
/// made under the same lock as the claim, so one of the two always sees the
/// other. A claim lasts for the session once a stanza was written, as a
/// message cut off mid-write may still be sent again by a resumed stream.
/// Only a failure, which is tried again from scratch, or finding that nothing
/// was written at all, gives it up.
struct SendClaims {
    enum Change: Equatable {
        case edited(String)
        case retracted
    }

    enum Claim: Equatable {
        /// Send it, with `text` instead of its body if it was edited meanwhile.
        case send(text: String?)
        /// It was retracted before it left: nothing goes out.
        case skip
    }

    private var claimed: Set<String> = []
    /// Which claim of an id is current, so a write that failed late can't give
    /// up the claim of a copy sent after it.
    private var tokens: [String: Int] = [:]
    private var lastToken = 0
    /// Handed to a send queue, which hasn't got to it yet.
    private var queued: Set<String> = []
    private var changes: [String: Change] = [:]

    /// `id` is about to be put on a send queue. False if it already is, or has
    /// been claimed, so it isn't sent twice. `resend` is for a message known to
    /// have been lost, such as one a room never echoed: it may be sent again
    /// after a claim, but never while another copy is still queued.
    mutating func enqueue(_ id: String, resend: Bool = false) -> Bool {
        if queued.contains(id) || (claimed.contains(id) && !resend) { return false }
        queued.insert(id)
        return true
    }

    /// The send queue takes up `id`.
    mutating func claim(_ id: String) -> Claim {
        queued.remove(id)
        let change = changes.removeValue(forKey: id)
        if change == .retracted { return .skip }
        claimed.insert(id)
        lastToken += 1
        tokens[id] = lastToken
        if case .edited(let text) = change { return .send(text: text) }
        return .send(text: nil)
    }

    /// The current claim of `id`, to hand to `releaseDropped`.
    func token(of id: String) -> Int? {
        tokens[id]
    }

    /// A write for the claim `token` was dropped, as the connection was gone:
    /// it is sent again from scratch, unless a newer claim has taken over.
    mutating func releaseDropped(_ id: String, token: Int) {
        guard tokens[id] == token else { return }
        claimed.remove(id)
        tokens[id] = nil
    }

    /// Whether the send queue has taken up `id` in this session.
    func isClaimed(_ id: String) -> Bool {
        claimed.contains(id)
    }

    /// `id` failed to send, or never reached the wire: it is tried again from
    /// scratch, and changes made meanwhile wait for that claim.
    mutating func release(_ id: String) {
        queued.remove(id)
        claimed.remove(id)
        tokens[id] = nil
    }

    /// Records `change` if `id` hasn't been claimed, and returns whether it
    /// still has to be sent as a correction or retraction instead.
    /// `alreadySent` is for what the message's status already says.
    mutating func apply(_ change: Change, to id: String, alreadySent: Bool) -> Bool {
        if claimed.contains(id) || alreadySent { return true }
        changes[id] = change
        return false
    }

    /// For a new session, whose unacknowledged messages are sent again.
    mutating func reset() {
        claimed = []
        queued = []
        tokens = [:]
        changes = [:]
    }
}
