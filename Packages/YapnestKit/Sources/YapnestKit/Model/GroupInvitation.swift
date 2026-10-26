import Foundation
import GRDB

/// An invitation to a group that we haven't acted on. Joining a group shows
/// the group our nickname and presence and adds it to every device, so every
/// invitation from a contact waits for the user's answer.
public struct GroupInvitation: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var room: JID
    /// Who the room says invited us. Its claim, not a fact.
    public var inviter: JID
    public var reason: String?
    /// The room's password, which the inviter sent along.
    public var password: String?
    public var receivedAt: Date
    /// Sent by the inviter (XEP-0249) rather than relayed by the room
    /// (XEP-0045). A direct invitation has no decline to send.
    public var isDirect: Bool
    /// Whether the inviter's claim holds: they sent it themselves, or the
    /// room is on their own server and can speak for them. Otherwise a room
    /// on another server named them, and could have named anyone.
    public var isVouched: Bool { isDirect || XMPPSession.vouches(room: room, for: inviter) }
    /// Whether the notification for it was claimed (see `claimNotifications`),
    /// by the app or the notification extension, whichever came first.
    public var isNotified: Bool

    public init(room: JID, inviter: JID, reason: String? = nil, password: String? = nil, receivedAt: Date = Date(), isDirect: Bool = false, isNotified: Bool = false) {
        self.room = room
        self.inviter = inviter
        self.reason = reason
        self.password = password
        self.receivedAt = receivedAt
        self.isDirect = isDirect
        self.isNotified = isNotified
    }

    public static let databaseTableName = "groupInvitation"
}
