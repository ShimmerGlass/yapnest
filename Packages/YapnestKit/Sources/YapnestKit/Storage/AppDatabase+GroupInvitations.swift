import Foundation
import GRDB

extension AppDatabase {
    /// A newer invitation to the same room replaces the older one. One that
    /// names no password keeps the older one's: a member's direct invitation
    /// follows the room's relayed one, which is the one that carries it.
    func recordGroupInvitation(room: JID, inviter: JID, reason: String?, password: String? = nil, isDirect: Bool = false, at date: Date = Date()) throws {
        try writer.write { db in
            // A replacement is the same invitation again: the user was told once.
            let existing = try GroupInvitation.fetchOne(db, key: room)
            let isNotified = existing?.isNotified ?? false
            try GroupInvitation(room: room, inviter: inviter, reason: reason, password: password ?? existing?.password, receivedAt: date, isDirect: isDirect, isNotified: isNotified).save(db)
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
        ValueObservation.trackingConstantRegion(Self.groupInvitations)
    }

    static func groupInvitations(_ db: Database) throws -> [GroupInvitation] {
        try GroupInvitation.order(Column("receivedAt").desc).fetchAll(db)
    }
}
