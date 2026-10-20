import Foundation
import GRDB

extension AppDatabase {
    /// A newer invitation to the same room replaces the older one.
    func recordGroupInvitation(room: JID, inviter: JID, reason: String?, at date: Date = Date()) throws {
        try writer.write { db in
            try GroupInvitation(room: room, inviter: inviter, reason: reason, receivedAt: date).save(db)
        }
    }

    /// Answered, or the room was joined some other way.
    func removeGroupInvitation(_ room: JID) throws {
        try writer.write { db in _ = try GroupInvitation.deleteOne(db, key: room) }
    }

    func groupInvitation(_ room: JID) throws -> GroupInvitation? {
        try reader.read { db in try GroupInvitation.fetchOne(db, key: room) }
    }

    /// Invitations waiting for an answer, newest first.
    public func observeGroupInvitations() -> ValueObservation<ValueReducers.Fetch<[GroupInvitation]>> {
        ValueObservation.tracking(Self.groupInvitations)
    }

    static func groupInvitations(_ db: Database) throws -> [GroupInvitation] {
        try GroupInvitation.order(Column("receivedAt").desc).fetchAll(db)
    }
}
