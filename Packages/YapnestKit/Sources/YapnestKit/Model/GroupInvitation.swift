import Foundation
import GRDB

/// An invitation to a group that we haven't acted on: one a room relayed
/// (XEP-0045) from a server that can't vouch for the inviter, so it waits
/// for the user's answer instead of being joined.
public struct GroupInvitation: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var room: JID
    /// Who the room says invited us. Its claim, not a fact.
    public var inviter: JID
    public var reason: String?
    /// The room's password, which the inviter sent along.
    public var password: String?
    public var receivedAt: Date

    public init(room: JID, inviter: JID, reason: String? = nil, password: String? = nil, receivedAt: Date = Date()) {
        self.room = room
        self.inviter = inviter
        self.reason = reason
        self.password = password
        self.receivedAt = receivedAt
    }

    public static let databaseTableName = "groupInvitation"
}
