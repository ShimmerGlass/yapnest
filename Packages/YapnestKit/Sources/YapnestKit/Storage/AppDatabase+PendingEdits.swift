import Foundation
import GRDB

/// A retraction or correction that named a message we don't have yet. The
/// archive's pages arrive newest first, so the edit can come before its
/// original, and the original can also lie beyond the sync window. Without
/// this, a retracted message would come back in full when its page arrived,
/// and a corrected one would show twice.
struct PendingEdit: Codable, FetchableRecord, MutablePersistableRecord {
    enum Kind: String, Codable {
        case retract
        case correct
    }

    static let databaseTableName = "pendingEdit"

    var id: Int64?
    var conversationId: Int64
    /// The id the edit names.
    var ref: String
    var kind: Kind
    var outgoing: Bool
    var sender: JID
    var nick: String?
    var occupantId: String?
    var encryption: Message.Encryption
    var createdAt: Date
    /// When the edit was made, which no message it names can be after.
    var editedAt: Date
    /// For a correction, the message that stands in for its missing original.
    var standInId: Int64?

    var author: Author { Author(jid: sender, nick: nick, occupantId: occupantId) }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension AppDatabase {
    static let pendingEditsPerConversation = 200
    static let pendingEditLifetime: TimeInterval = 90 * 24 * 3600

    /// Remembers an edit whose original isn't stored. The table is bounded
    /// because a forged edit naming an id that never arrives is never
    /// applied: the oldest past a cap go, and so does anything old.
    static func keepPending(_ db: Database, _ kind: PendingEdit.Kind, ref: String, _ inbound: InboundMessage, conversationId: Int64, standInId: Int64?) throws {
        let now = Date()
        var edit = PendingEdit(
            conversationId: conversationId, ref: ref, kind: kind, outgoing: inbound.isOutgoing,
            sender: inbound.author.jid, nick: inbound.author.nick, occupantId: inbound.author.occupantId,
            encryption: inbound.encryption, createdAt: now, editedAt: inbound.timestamp, standInId: standInId,
        )
        try edit.insert(db)
        try PendingEdit.filter(Column("conversationId") == conversationId && Column("createdAt") < now.addingTimeInterval(-pendingEditLifetime)).deleteAll(db)
        let excess = try PendingEdit.filter(Column("conversationId") == conversationId).fetchCount(db) - pendingEditsPerConversation
        if excess > 0 {
            let oldest = try PendingEdit.filter(Column("conversationId") == conversationId)
                .order(Column("id")).limit(excess).fetchAll(db).compactMap(\.id)
            try PendingEdit.deleteAll(db, keys: oldest)
        }
    }

    /// Applies what waited for `message`, which was just stored. Edits that
    /// don't pass the checks a live one does (the sender, and how the
    /// message was protected) are dropped without applying. Returns nil when
    /// nothing was waiting.
    static func applyPending(_ db: Database, to message: inout Message, room: JID?) throws -> (retracted: Bool, attachment: Attachment?)? {
        let refs = [message.remoteId, message.originId, message.serverId].compactMap { $0 }
        guard !refs.isEmpty, message.id != nil else { return nil }
        let waiting = try PendingEdit
            .filter(Column("conversationId") == message.conversationId && refs.contains(Column("ref")))
            .order(Column("id"))
            .fetchAll(db)
        guard !waiting.isEmpty else { return nil }
        try PendingEdit.deleteAll(db, keys: waiting.compactMap(\.id))

        let fitting = waiting.filter { edit in
            (message.direction == .outgoing) == edit.outgoing
                && (edit.outgoing || message.author.isSame(as: edit.author, room: room))
                && message.timestamp <= edit.editedAt
        }
        if fitting.contains(where: { $0.kind == .retract }) {
            let attachment = try retract(db, &message)
            try deleteStandIns(db, fitting)
            return (true, attachment)
        }
        var changed = false
        var applied: [PendingEdit] = []
        let corrections = try fitting.compactMap { edit -> (PendingEdit, Message)? in
            guard let id = edit.standInId, let standIn = try Message.fetchOne(db, key: id) else { return nil }
            return (edit, standIn)
        }.sorted { ($0.1.editedAt ?? $0.1.timestamp) < ($1.1.editedAt ?? $1.1.timestamp) }
        for (edit, standIn) in corrections where edit.encryption == message.encryption && !standIn.isRetracted {
            let result = try applyCorrection(
                db, to: &message, body: standIn.body, at: standIn.editedAt ?? standIn.timestamp, mentionsMe: standIn.mentionsMe,
                quickResponses: standIn.quickResponses, omemoDevice: standIn.omemoDevice, omemoTrust: standIn.omemoTrust,
                outgoing: edit.outgoing,
            )
            if result != nil {
                changed = true
                applied.append(edit)
            }
        }
        // A stand-in that wasn't applied stays a message of its own.
        try deleteStandIns(db, applied)
        return changed ? (false, nil) : nil
    }

    /// The waiting edits of `kind` for `ref` that `author` could have made.
    static func fittingPending(_ db: Database, _ kind: PendingEdit.Kind, conversationId: Int64, ref: String, by author: Author, outgoing: Bool, room: JID?) throws -> [PendingEdit] {
        try PendingEdit
            .filter(Column("conversationId") == conversationId && Column("ref") == ref && Column("kind") == kind.rawValue)
            .order(Column("id"))
            .fetchAll(db)
            .filter { $0.outgoing == outgoing && (outgoing || $0.author.isSame(as: author, room: room)) }
    }

    /// A retraction of a message we don't have also takes back the text of
    /// the corrections that stand in for it. Their rows stay, so that the
    /// original, when it arrives, takes the stand-ins' tombstones with it
    /// instead of leaving them beside its own.
    static func retractStandIns(_ db: Database, of edits: [PendingEdit]) throws {
        for edit in edits {
            if let id = edit.standInId, var standIn = try Message.fetchOne(db, key: id), !standIn.isRetracted {
                _ = try retract(db, &standIn)
            }
        }
    }

    /// The stand-ins of corrections that found their original: left, they
    /// would show the same message twice.
    private static func deleteStandIns(_ db: Database, _ edits: [PendingEdit]) throws {
        let ids = edits.compactMap(\.standInId)
        try Message.deleteAll(db, keys: ids)
    }
}
