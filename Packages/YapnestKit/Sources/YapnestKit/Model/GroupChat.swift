import Foundation
import GRDB

/// What we keep about a group chat (XEP-0045 room) beyond its conversation.
public struct GroupChat: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    /// Which of the group's messages notify (XEP-0492's values).
    public enum Notify: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case always
        /// Only messages that say our nickname or reply to ours.
        case onMention = "on-mention"
        case never
    }

    public var conversationId: Int64
    public var jid: JID
    /// Our nickname in the room.
    public var nickname: String
    /// The room's name, from its configuration or bookmark.
    public var name: String?
    public var subject: String?
    /// We left, or were removed; the conversation stays for its history.
    public var hasLeft: Bool
    /// Whether the room is in our bookmarks (XEP-0402), so we can tell a
    /// bookmark removed on another device from one we never published.
    public var isBookmarked: Bool
    /// Only members may join.
    public var isMembersOnly: Bool
    /// Occupants' addresses are visible to them: what OMEMO needs to know who
    /// to encrypt for, together with `isMembersOnly`.
    public var isNonAnonymous: Bool
    /// Last item we have from the room's own archive.
    public var lastArchiveId: String?
    /// Kept in the bookmark, for our other devices.
    public var notify: Notify
    /// The room vouches for XEP-0421 occupant ids, so they can be trusted
    /// to tell occupants apart. Elsewhere anyone could forge one.
    public var hasOccupantIds: Bool
    /// The room's password, from the invitation that gave it. Kept here and
    /// not in the bookmark: it is only ever sent back to the room, on joining.
    public var password: String?

    public init(
        conversationId: Int64,
        jid: JID,
        nickname: String,
        name: String? = nil,
        subject: String? = nil,
        hasLeft: Bool = false,
        isBookmarked: Bool = false,
        isMembersOnly: Bool = false,
        isNonAnonymous: Bool = false,
        lastArchiveId: String? = nil,
        notify: Notify = .always,
        hasOccupantIds: Bool = false,
        password: String? = nil,
    ) {
        self.conversationId = conversationId
        self.jid = jid
        self.nickname = nickname
        self.name = name
        self.subject = subject
        self.hasLeft = hasLeft
        self.isBookmarked = isBookmarked
        self.isMembersOnly = isMembersOnly
        self.isNonAnonymous = isNonAnonymous
        self.lastArchiveId = lastArchiveId
        self.notify = notify
        self.hasOccupantIds = hasOccupantIds
        self.password = password
    }

    /// A private group, as Conversations calls it: the only kind OMEMO works in.
    public var isPrivate: Bool { isMembersOnly && isNonAnonymous }

    /// Whether `change` takes a private group out of being one: it stops
    /// being members only, or stops showing members' addresses to everyone.
    /// Mirrors `isPrivate`.
    public func wouldStopBeingPrivate(by change: RoomConfiguration?) -> Bool {
        guard isPrivate, let change else { return false }
        let membersOnly = change.isMembersOnly ?? isMembersOnly
        let showsAddresses = change.whoCanSeeAddresses.map { $0 == .anyone } ?? isNonAnonymous
        return !(membersOnly && showsAddresses)
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return jid.shortName
    }

    public static let databaseTableName = "groupChat"
    public static let conversation = belongsTo(Conversation.self)
}

/// Who wrote a message or reaction: an address, plus the nickname they used
/// in a group chat. In anonymous rooms the address is the room's own.
public struct Author: Hashable, Sendable {
    public var jid: JID
    public var nick: String?
    /// XEP-0421: the room's stable id for the occupant, when the room
    /// vouches for it. Survives nickname changes, unlike `nick`.
    public var occupantId: String?

    public init(jid: JID, nick: String? = nil, occupantId: String? = nil) {
        self.jid = jid
        self.nick = nick
        self.occupantId = occupantId
    }

    /// Whether `other` is the same person: by occupant id where both have
    /// one, else by address, and by nickname where the address is the room's.
    func isSame(as other: Author, room: JID?) -> Bool {
        if let mine = occupantId, let theirs = other.occupantId { return mine == theirs }
        guard jid == other.jid else { return false }
        return jid != room || nick == other.nick
    }
}
