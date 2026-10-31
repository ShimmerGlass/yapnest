import Foundation
import GRDB

extension AppDatabase {
    /// Blocks or unblocks `jid` here at once and queues the change for the
    /// server. A change replaces an earlier unsent one for the same person,
    /// and one that undoes it (when `canCancel`) leaves nothing to send.
    /// Returns whether there is something to send.
    @discardableResult
    func queueBlockChange(_ jid: JID, blocked: Bool, reason: XMPPSession.ReportReason?, declinesRequest: Bool, canCancel: Bool) throws -> Bool {
        let queued = try writer.write { db -> Bool in
            let earlier = try PendingBlockChange.filter(Column("jid") == jid).fetchOne(db)
            let was = try earlier?.wasBlocked ?? Contact.fetchOne(db, key: jid)?.isBlocked ?? false
            if let earlier { _ = try earlier.delete(db) }
            _ = try Self.updateContact(db, jid) { $0.isBlocked = blocked }
            if canCancel, blocked == was { return false }
            var change = PendingBlockChange(
                jid: jid, blocked: blocked, reason: blocked ? reason : nil,
                declinesRequest: blocked && (declinesRequest || earlier?.declinesRequest == true), wasBlocked: was,
            )
            try change.insert(db)
            return true
        }
        if blocked { ShareSuggestions.remove([jid]) }
        return queued
    }

    /// The oldest change still to send.
    func nextPendingBlockChange() throws -> PendingBlockChange? {
        try reader.read { try PendingBlockChange.order(Column("id")).fetchOne($0) }
    }

    /// The server took `change`. A newer change for the same person has its own row.
    func removePendingBlockChange(id: Int64) throws {
        try writer.write { db in _ = try PendingBlockChange.deleteOne(db, key: id) }
    }

    /// The server refused `change` for good: the person is as the server
    /// has them (`serverBlocked`), or as they were before it. Returns whether
    /// it was still queued: the user may have replaced it meanwhile.
    func dropPendingBlockChange(_ change: PendingBlockChange, serverBlocked: Bool?) throws -> Bool {
        guard let id = change.id else { return false }
        return try writer.write { db in
            guard try PendingBlockChange.deleteOne(db, key: id) else { return false }
            _ = try Self.updateContact(db, change.jid) { $0.isBlocked = serverBlocked ?? change.wasBlocked }
            return true
        }
    }

    /// The people the server's blocklist `server` and our unsent changes
    /// leave blocked. A change the server already agrees with is done, and
    /// for the others the server's list is what they would undo.
    static func blocklist(_ db: Database, server: Set<JID>) throws -> Set<JID> {
        var effective = server
        for var change in try PendingBlockChange.order(Column("id")).fetchAll(db) {
            let serverHas = server.contains(change.jid)
            if change.blocked == serverHas {
                _ = try change.delete(db)
                continue
            }
            if change.wasBlocked != serverHas {
                change.wasBlocked = serverHas
                try change.update(db)
            }
            if change.blocked { effective.insert(change.jid) } else { effective.remove(change.jid) }
        }
        return effective
    }
}
