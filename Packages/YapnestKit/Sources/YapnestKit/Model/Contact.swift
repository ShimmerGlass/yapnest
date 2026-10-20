import Foundation
import GRDB

/// A roster entry, or a JID we have talked to without a roster entry.
public struct Contact: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public enum Subscription: String, Codable, Sendable, DatabaseValueConvertible {
        case none, to, from, both
    }

    public var jid: JID
    public var name: String?
    public var subscription: Subscription
    /// We asked for a subscription and are waiting for an answer.
    public var isSubscriptionPending: Bool
    public var isInRoster: Bool
    /// The user added this contact on this device (`addContact`). The server
    /// can put people in the roster the user never added: Openfire answers a
    /// stranger's unsolicited `subscribed` with a roster item. So being in the
    /// roster doesn't show that the user wants them to see our presence.
    public var isAddedByUser: Bool
    public var isBlocked: Bool
    /// SHA-1 (hex) of the contact's avatar image, cached by `AvatarStore`.
    public var avatarHash: String?
    /// When they asked to see our presence, while we haven't answered.
    public var subscriptionRequestedAt: Date?
    /// The name they gave with their request (XEP-0172). Their own claim,
    /// so it's never shown without their address.
    public var requestedNickname: String?
    /// The name they publish for themselves (XEP-0172), shown only when the
    /// roster has no name for them.
    public var nickname: String?
    /// The roster item's groups. Yapnest has no use for them, but a roster
    /// set replaces an item's groups, so renaming a contact has to send back
    /// the ones another client gave them.
    public var rosterGroups: [String]
    /// When they were last seen, as their server told us (XEP-0012). Only set
    /// while the user shares their own last seen, and cleared when they stop.
    public var lastSeenAt: Date?

    public init(
        jid: JID,
        name: String? = nil,
        subscription: Subscription = .none,
        isSubscriptionPending: Bool = false,
        isInRoster: Bool = false,
        isAddedByUser: Bool = false,
        isBlocked: Bool = false,
        avatarHash: String? = nil,
        subscriptionRequestedAt: Date? = nil,
        requestedNickname: String? = nil,
        nickname: String? = nil,
        rosterGroups: [String] = [],
        lastSeenAt: Date? = nil,
    ) {
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.isSubscriptionPending = isSubscriptionPending
        self.isInRoster = isInRoster
        self.isAddedByUser = isAddedByUser
        self.isBlocked = isBlocked
        self.avatarHash = avatarHash
        self.subscriptionRequestedAt = subscriptionRequestedAt
        self.requestedNickname = requestedNickname
        self.nickname = nickname
        self.rosterGroups = rosterGroups
        self.lastSeenAt = lastSeenAt
    }

    /// They asked to add us as a contact, and we haven't answered.
    public var hasContactRequest: Bool { subscriptionRequestedAt != nil && !isBlocked }

    /// Whether we receive their presence, so "offline" actually means offline.
    public var seesPresence: Bool { subscription == .to || subscription == .both }

    /// Whether the user chose this contact, so a name they publish may stand
    /// for them. Anyone else could call themselves "Mom".
    public var isKnown: Bool { isInRoster && (subscription != .none || isSubscriptionPending) }

    /// The roster name, else the name they publish if the user added them,
    /// else the bare address.
    public var displayName: String {
        // The name the user gave them always wins over the one they chose.
        if let name, !name.isEmpty { return name }
        if isKnown, let nickname, !nickname.isEmpty { return nickname }
        return jid.shortName
    }

    public static let databaseTableName = "contact"
}
