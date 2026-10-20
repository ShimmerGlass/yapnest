import Foundation
import GRDB

/// A call as the conversation records it, from the device that handled it.
struct CallRecord: Sendable, Equatable {
    var peer: JID
    var account: JID
    var sid: String
    var direction: Message.Direction
    var outcome: CallOutcome
    var startedAt: Date
    var answeredAt: Date?
    var duration: TimeInterval?
    var isVideo = false
}

extension AppDatabase {
    /// How long after a `propose` an archive copy of it may still be ringing
    /// somewhere, so that it isn't taken for a missed call before its end is
    /// known.
    static let callUnresolvedWindow = CallMachine.ringWindow + 10

    /// Writes what this device saw of a call, once it ended. A row an archive
    /// replay made earlier is completed.
    @discardableResult
    func recordCall(_ record: CallRecord) throws -> Message? {
        try writer.write { db in
            try Self.upsertCall(db, record, isAuthoritative: true, isHistory: false)
        }
    }

    /// Applies a Jingle message seen in the archive, or as a carbon, or live
    /// where nothing is handling the call. Such a copy has no end of its own,
    /// so each message of a call refines the row the first one made: a
    /// `propose` alone is a missed or cancelled call, an answer makes it
    /// answered, and a `finish` gives the length. Applying one twice changes
    /// nothing, which a catch-up that reads a page again relies on.
    @discardableResult
    func applyCallSignal(_ signal: CallSignal, account: JID, isHistory: Bool, now: Date = Date()) throws -> Message? {
        try writer.write { db in
            try Self.applyCallSignal(db, signal, account: account, isHistory: isHistory, now: now)
        }
    }

    /// Applies a page of the archive in one transaction: its messages, then
    /// the call signals among them in order. Returns what each made, the rows
    /// of the signals as `applyCallSignal` does.
    func ingest(_ batch: [InboundMessage], callSignals: [(signal: CallSignal, isHistory: Bool)], account: JID) throws -> (results: [IngestResult], calls: [Message?]) {
        let insecure = allowsInsecureLinks
        let now = Date()
        return try writer.write { db in
            let results = try batch.map { try Self.ingest(db, $0, allowsInsecureLinks: insecure) }
            let calls = try callSignals.map { try Self.applyCallSignal(db, $0.signal, account: account, isHistory: $0.isHistory, now: now) }
            return (results, calls)
        }
    }

    static func applyCallSignal(_ db: Database, _ signal: CallSignal, account: JID, isHistory: Bool, now: Date) throws -> Message? {
        // The call gave way to another between the same two people, which is
        // the one that counts. Its propose may have made a row already, such
        // as when read back from the archive.
        if signal.isTieBreak {
            // Only an unanswered one, and only in the chat with whoever sent it.
            if let peer = signal.peer, let id = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id {
                try Message
                    .filter(Column("conversationId") == id && Column("remoteId") == signal.sid
                            && Column("callOutcome") != nil && Column("callOutcome") != CallOutcome.answered.rawValue)
                    .deleteAll(db)
            }
            return nil
        }
        let peer: JID
        let known: KnownCall
        if let signalPeer = signal.peer {
            peer = signalPeer
            known = try knownCall(db, peer: signalPeer, sid: signal.sid)
        } else {
            // A message we addressed to ourselves names no peer, only the call.
            let row = try Message.filter(Column("remoteId") == signal.sid && Column("callOutcome") != nil && Column("direction") == Message.Direction.incoming).fetchOne(db)
            guard let row, let conversation = try Conversation.fetchOne(db, key: row.conversationId) else { return nil }
            peer = conversation.peer
            known = KnownCall(conversation: conversation, row: row)
        }
        let existing = known.row
        // What we know of the call without its start: who called, and how far it got.
        guard let direction = existing?.direction ?? signal.impliedDirection else { return nil }
        var record = CallRecord(
            peer: peer, account: account, sid: signal.sid, direction: direction, outcome: .missed,
            startedAt: existing?.timestamp ?? signal.timestamp, isVideo: existing?.callIsVideo ?? false,
        )
        switch signal.action {
        case .propose, .retract:
            if signal.action.asksForVideo { record.isVideo = true }
            // A propose may still be ringing on a device that will say how it ended.
            if case .propose = signal.action, existing == nil, now.timeIntervalSince(signal.timestamp) < callUnresolvedWindow, !isHistory { return nil }
            record.outcome = direction == .incoming ? .missed : .cancelled
        case .proceed, .accept:
            record.outcome = .answered
            record.answeredAt = existing?.callAnsweredAt ?? signal.timestamp
        case .reject(let reason):
            record.outcome = reason == .busy && direction == .outgoing ? .busy : .declined
        case .finish(let reason):
            guard let existing, existing.callOutcome == .answered else { return nil }
            record.outcome = .answered
            record.answeredAt = existing.callAnsweredAt
            switch reason {
            case .connectivityError, .failedApplication, .generalError:
                record.outcome = .failed
            default:
                if let answeredAt = existing.callAnsweredAt, existing.callDuration == nil {
                    record.duration = max(0, signal.timestamp.timeIntervalSince(answeredAt))
                }
            }
        case .ringing:
            return nil
        }
        return try upsertCall(db, record, isAuthoritative: false, isHistory: isHistory, known: known)
    }

    /// What `applyCallSignal` already looked up, so `upsertCall` doesn't.
    private struct KnownCall {
        var conversation: Conversation?
        var row: Message?
    }

    private static func knownCall(_ db: Database, peer: JID, sid: String) throws -> KnownCall {
        let conversation = try Conversation.filter(Column("peer") == peer).fetchOne(db)
        return KnownCall(conversation: conversation, row: try conversation?.id.flatMap { try callRow(db, conversationId: $0, sid: sid) })
    }

    private static func callRow(_ db: Database, conversationId: Int64, sid: String) throws -> Message? {
        try Message
            .filter(Column("conversationId") == conversationId && Column("remoteId") == sid && Column("callOutcome") != nil)
            .fetchOne(db)
    }

    /// Inserts the call's row, or brings the one it has up to date. Returns the
    /// row if it is new.
    ///
    /// A replay only ever refines (see `CallOutcome.rank`), unless
    /// `isAuthoritative`: the end of a call this device took part in. That is
    /// also what lets it open a conversation, so a stranger's replayed calls
    /// don't.
    private static func upsertCall(_ db: Database, _ record: CallRecord, isAuthoritative: Bool, isHistory: Bool, known: KnownCall? = nil) throws -> Message? {
        var known = try known ?? knownCall(db, peer: record.peer, sid: record.sid)
        if known.conversation == nil {
            let inRoster = try Contact.fetchOne(db, key: record.peer)?.isInRoster == true
            guard isAuthoritative || inRoster else { return nil }
            known.conversation = try Self.conversation(db, with: record.peer)
        }
        guard let conversation = known.conversation, let conversationId = conversation.id else { return nil }
        // A missed call is news until the chat is opened; any other ending is not.
        let isRead = record.direction == .outgoing || record.outcome != .missed || isHistory

        if var row = known.row {
            let current = row.callOutcome ?? .missed
            let refines = isAuthoritative || record.outcome.rank > current.rank
                || (record.outcome == current && (row.callDuration == nil && record.duration != nil
                                                    || row.callAnsweredAt == nil && record.answeredAt != nil))
            if refines {
                row.callOutcome = record.outcome
                row.callDuration = record.duration ?? row.callDuration
                row.callAnsweredAt = record.answeredAt ?? row.callAnsweredAt
                row.callIsVideo = row.callIsVideo || record.isVideo
                // Never news again once it was read.
                row.isRead = row.isRead || isRead
            } else if record.isVideo && !row.callIsVideo {
                // A replayed proposal knows the call was video but not how it
                // ended, so it must not undo an outcome we already have.
                row.callIsVideo = true
            } else {
                return nil
            }
            try row.update(db)
            return nil
        }

        var row = Message(
            conversationId: conversationId,
            direction: record.direction,
            sender: record.direction == .incoming ? record.peer : record.account,
            body: "",
            timestamp: record.startedAt,
            status: record.direction == .incoming ? .received : .sent,
            isRead: isRead,
            remoteId: record.sid,
        )
        row.callOutcome = record.outcome
        row.callDuration = record.duration
        row.callAnsweredAt = record.answeredAt
        row.callIsVideo = record.isVideo
        try row.insert(db)
        if !isHistory, record.startedAt > conversation.lastActivityAt {
            var moved = conversation
            moved.lastActivityAt = record.startedAt
            try moved.update(db)
        }
        try unarchive(db, conversationId: conversationId, ifNewerThan: record.startedAt)
        return row
    }
}
