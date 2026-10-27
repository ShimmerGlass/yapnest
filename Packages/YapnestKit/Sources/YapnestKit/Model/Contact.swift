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
    /// The user added this contact on this device (`addContact`). It covers
    /// the time before the server confirms the subscription, or if it drops
    /// our request.
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
    public var isKnown: Bool { isInRoster && hasConsent }

    /// Whether the user added or approved them: they added them here, asked
    /// them and are waiting for the answer (the server's `ask`), subscribed
    /// to their presence (`to`, which only exists because our account asked
    /// for it, from here or another app), or approved them so they see ours.
    /// A roster item with no subscription is not consent, nor is a request
    /// from them we haven't answered. Everything a stranger mustn't get (a
    /// ringing phone, receipts, automatic downloads, being told our presence
    /// or last seen) hangs on this, never on `isInRoster`.
    /// This is for what the UI shows; whether to act for them is `mayReceive`.
    /// `AppDatabase.missedImages` repeats `mayReceive` in SQL.
    public var hasConsent: Bool {
        isAddedByUser || isSubscriptionPending || subscription != .none
    }

    /// Whether they get what only those we consented to get: consent, and not
    /// blocked. A server's block can miss sessions already online (Openfire's
    /// first block does), and what still reaches us mustn't earn a receipt, a
    /// ringing phone, a download or a conversation.
    public var mayReceive: Bool { hasConsent && !isBlocked }

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
