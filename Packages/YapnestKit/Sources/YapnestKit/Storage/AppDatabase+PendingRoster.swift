import Foundation
import GRDB

extension AppDatabase {
    /// Queues `kind` for `jid`. Nothing is applied to the contact until the
    /// server confirms; it shows the change as waiting. A later change
    /// replaces an earlier unsent one that it makes pointless, except the
    /// one in flight (`inFlight`, a row id), which the server may already have.
    func queueRosterChange(_ jid: JID, kind: PendingRosterKind, name: String? = nil, inFlight: Int64?, at date: Date = Date()) throws {
        try writer.write { db in
            let earlier = try PendingRosterChange.filter(Column("jid") == jid).order(Column("id")).fetchAll(db)
            let replaced: Set<PendingRosterKind> = switch kind {
            case .rename: [.rename]
            case .remove: [.rename, .remove]
            case .accept, .decline: [.accept, .decline]
            }
            for change in earlier where replaced.contains(change.kind) && change.id != inFlight {
                _ = try change.delete(db)
            }
            var change = PendingRosterChange(jid: jid, kind: kind, name: kind == .rename ? name : nil, createdAt: date)
            try change.insert(db)
            try Self.refreshPendingRoster(db, jid)
        }
    }

    /// The oldest change still to send.
    func nextPendingRosterChange() throws -> PendingRosterChange? {
        try reader.read { try PendingRosterChange.order(Column("id")).fetchOne($0) }
    }

    func pendingRosterChanges() throws -> [PendingRosterChange] {
        try reader.read { try PendingRosterChange.order(Column("id")).fetchAll($0) }
    }

    func hasPendingRosterChange(_ jid: JID, kind: PendingRosterKind) throws -> Bool {
        try reader.read { try PendingRosterChange.filter(Column("jid") == jid && Column("kind") == kind).fetchCount($0) > 0 }
    }

    /// The server answered `change`, or it is no longer needed: it goes, and
    /// the contact stops showing it as waiting. Returns whether it was queued.
    @discardableResult
    func removePendingRosterChange(id: Int64) throws -> Bool {
        try writer.write { db in
            guard let change = try PendingRosterChange.fetchOne(db, key: id) else { return false }
            _ = try change.delete(db)
            try Self.refreshPendingRoster(db, change.jid)
            return true
        }
    }

    /// What the contact shows of the changes waiting for it: the latest answer
    /// to a request or removal, and the latest rename.
    private static func refreshPendingRoster(_ db: Database, _ jid: JID) throws {
        let changes = try PendingRosterChange.filter(Column("jid") == jid).order(Column("id")).fetchAll(db)
        let answer = changes.last { $0.kind != .rename }?.kind
        let rename = changes.last { $0.kind == .rename }
        try updateContact(db, jid) { contact in
            contact.pendingRoster = answer
            contact.pendingRename = rename != nil
            contact.pendingName = rename?.name
        }
    }
}
