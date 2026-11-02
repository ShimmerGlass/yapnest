import Foundation
@preconcurrency import Martin

typealias PendingKind = AppDatabase.PendingKind

/// The stanzas of our reactions and of our corrections and retractions are
/// kept pending in the database under their own id until the server
/// acknowledges them. This is what the session does with both alike: which
/// were written this session, and what an acknowledgement or a give-up does.
/// Each kind differs in how its stanza is built and written, which stays with
/// `writeReactions` and `sendAction`.
struct PendingLedger {
    private var written: [String: PendingKind] = [:]

    func contains(_ id: String, of kind: PendingKind) -> Bool {
        written[id] == kind
    }

    /// The kind of stanza written this session under `id`.
    func kind(of id: String) -> PendingKind? {
        written[id]
    }

    /// False if `id` was written already, so none is written twice. Ids are
    /// UUIDs, so they are unique across kinds too.
    mutating func insert(_ id: String, of kind: PendingKind) -> Bool {
        guard written[id] == nil else { return false }
        written[id] = kind
        return true
    }

    mutating func remove(_ id: String) {
        written[id] = nil
    }

    /// A new session forgets what it wrote, as the server never got what it
    /// hadn't acknowledged.
    mutating func reset() {
        written = [:]
    }
}

extension XMPPSession {
    /// Which kind of pending stanza `stanza` is, if any: one written this
    /// session, or else one that says so itself, as a new session forgets what
    /// it wrote and the server's acknowledgement may still come.
    func pendingKind(of stanza: Stanza, id: String) -> PendingKind? {
        guard stanza.name == "message" else { return nil }
        if let kind = lock.withLock({ $0.pendingStanzas.kind(of: id) }) { return kind }
        if stanza.firstChild(name: "reactions", xmlns: NS.reactions) != nil { return .reaction }
        if stanza.firstChild(name: "replace", xmlns: NS.correction) != nil
            || stanza.firstChild(name: "retract", xmlns: NS.retraction) != nil { return .action }
        return nil
    }

    /// The server has the pending stanza `stanza`: it stops being pending. The
    /// database only clears what is pending under this very id, so an
    /// acknowledgement of an earlier write never undoes a newer change.
    /// False if it is no such stanza.
    func acknowledgePending(_ stanza: Stanza, id: String) -> Bool {
        guard let kind = pendingKind(of: stanza, id: id) else { return false }
        endWrite(kind, id: id)
        do {
            try database.clearPending(kind, id: id)
        } catch {
            switch kind {
            case .reaction: logger.error("Failed to mark reactions \(id, privacy: .private) sent: \(error)")
            case .action: logger.error("Failed to mark a correction or retraction \(id, privacy: .private) sent: \(error)")
            }
        }
        return true
    }

    /// Stops sending the pending stanza `id`. With a reason, it shows that it
    /// didn't reach the others, with a way to try again.
    func giveUpPending(_ kind: PendingKind, id: String, because reason: String?) {
        endWrite(kind, id: id)
        // A later error of the stanza would otherwise make the item pending
        // again and send it, or replace the reason shown.
        lock.withLock { $0.bounces.remove(id) }
        try? database.clearPending(kind, id: id, error: reason)
    }

    /// A change of a `kind` the server hasn't acknowledged: the message it is
    /// on, its conversation's peer, the id of its stanza, and for reactions
    /// the message itself, as their stanza is built from it.
    struct PendingRow {
        var messageId: Int64
        var peer: JID
        var id: String
        var message: Message?
    }

    func pendingRows(_ kind: PendingKind) -> [PendingRow] {
        switch kind {
        case .reaction:
            return ((try? database.pendingReactions()) ?? []).compactMap { message, peer, id in
                message.id.map { PendingRow(messageId: $0, peer: peer, id: id, message: message) }
            }
        case .action:
            return ((try? database.pendingActions()) ?? []).map { PendingRow(messageId: $0.messageId, peer: $0.peer, id: $0.id, message: nil) }
        }
    }

    /// Sends what the server never acknowledged, which only a new session
    /// loses: a resumed stream resends it itself, and it is already written
    /// then.
    func resendUnacknowledged(_ pending: [(kind: PendingKind, rows: [PendingRow])]) {
        for (kind, rows) in pending {
            for row in rows where !lock.withLock({ $0.pendingStanzas.contains(row.id, of: kind) }) {
                switch kind {
                case .reaction: resendReaction(row)
                case .action: sendAction(id: row.id, of: row.messageId, to: row.peer)
                }
            }
        }
    }

    /// A room that isn't ready has the reactions wait like a fresh reaction does.
    private func resendReaction(_ row: PendingRow) {
        guard let message = row.message else { return }
        // A room we left never becomes ready, so it would be queued again
        // every session for good.
        if (try? database.groupChat(row.peer))?.hasLeft == true {
            try? database.clearPending(.reaction, messageId: row.messageId)
            return
        }
        // Rebuilt from what we hold now, which the stored id names.
        guard !message.isRetracted, let target = reference(to: message),
              let mine = try? database.reactions(on: message, from: account) else {
            try? database.clearPending(.reaction, messageId: row.messageId)
            return
        }
        let route = route(to: row.peer)
        let stanza = OutboundStanza.reactions(mine, to: route, target: target, id: row.id)
        whenReady(route) { [self] in writeReactions(stanza, id: row.id, messageId: row.messageId, peer: row.peer) }
    }

    /// Marks the stanza `id` written this session, and records whose it is
    /// for the error that may bounce it: where the error may pass the item is
    /// made pending again and sent after a wait, where it won't `failure` is
    /// shown. A newer change to the item stands either way. False, with
    /// nothing done, if the stanza was written already.
    func beginWrite(_ kind: PendingKind, id: String, messageId: Int64, peer: JID, failure: String) -> Bool {
        guard lock.withLock({ $0.pendingStanzas.insert(id, of: kind) }) else { return false }
        let key: BounceKey
        let resend: AppDatabase.Resend
        switch kind {
        case .reaction:
            key = .reactions(messageId)
            resend = .reactions(messageId: messageId)
        case .action:
            key = .action(messageId)
            resend = .action(messageId: messageId)
        }
        expectBounce(
            of: id, key: key, peer: peer,
            release: { [weak self] in self?.endWrite(kind, id: id) },
            repend: { [weak self] in try? self?.database.repend(resend, id: id, ifNotSupersededBy: id) },
            fail: { [weak self] error in
                try? self?.database.clearPending(
                    kind, messageId: messageId, error: error.describe(failure), unlessSupersededBy: id,
                )
            },
        )
        return true
    }

    /// The stanza `id` wasn't written after all, or its error came: it may be written again.
    func endWrite(_ kind: PendingKind, id: String) {
        lock.withLock { $0.pendingStanzas.remove(id) }
    }
}
