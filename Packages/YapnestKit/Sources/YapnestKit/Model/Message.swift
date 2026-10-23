import Foundation
import GRDB

public struct Message: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public enum Direction: String, Codable, Sendable, DatabaseValueConvertible {
        case incoming, outgoing
    }

    /// Delivery state of an outgoing message. Incoming messages are always `.received`.
    public enum Status: String, Codable, Sendable, DatabaseValueConvertible, Comparable {
        case failed, pending, sent, received, delivered, displayed

        private var rank: Int {
            switch self {
            case .failed: 0
            case .pending: 1
            case .sent: 2
            case .received: 3
            case .delivered: 4
            case .displayed: 5
            }
        }

        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rank < rhs.rank }
    }

    public enum Encryption: String, Codable, Sendable, DatabaseValueConvertible {
        case none
        case omemo
        /// An OMEMO message we could not decrypt; `body` holds no content.
        case omemoUndecryptable
    }

    public var id: Int64?
    public var conversationId: Int64
    public var direction: Direction
    /// In group chats: the occupant's real address if the room shows it,
    /// otherwise the room's; ours for our own messages.
    public var sender: JID
    /// In group chats: the sender's nickname.
    public var nick: String?
    /// In rooms that vouch for XEP-0421 ids: the sender's.
    public var occupantId: String?
    public var body: String
    public var timestamp: Date
    public var status: Status
    public var isRead: Bool
    public var encryption: Encryption

    /// The `id` attribute of the `<message>` stanza. XEP-0444 and XEP-0461
    /// reference 1:1 messages by this value.
    public var remoteId: String?
    /// XEP-0359 `<origin-id>`.
    public var originId: String?
    /// XEP-0359 `<stanza-id>` assigned by our own server, or by the room in
    /// group chats, where replies and reactions reference it. Dedupes MAM results.
    public var serverId: String?

    /// XEP-0461: id of the message this one replies to, as written by the sender.
    public var replyToId: String?
    public var replyToSender: JID?
    /// XEP-0428 fallback quote, shown if the replied-to message isn't stored.
    public var replyFallback: String?

    /// Why an outgoing message failed, for display.
    public var error: String?

    /// For decrypted messages: the OMEMO device that sent it.
    public var omemoDevice: Int32?
    /// For OMEMO messages: how far the sending device was trusted (incoming),
    /// or the least trusted recipient device (outgoing).
    public var omemoTrust: OMEMODevice.Trust?

    /// The link the message's preview is for, found once when stored.
    public var link: String?

    /// When its sender last corrected it (XEP-0308).
    public var editedAt: Date?
    /// Its sender took it back (XEP-0424): it stays as a tombstone, with
    /// its content gone, so archive catch-ups don't bring it back.
    public var isRetracted = false
    /// A moderator took it back (XEP-0425) rather than its author. Only
    /// meaningful with `isRetracted`.
    public var isModerated = false
    /// A group message that names us in a XEP-0372 mention.
    public var mentionsMe = false
    /// An incoming message whose sender asked to know when we've read it
    /// (XEP-0333). Only those get a displayed marker.
    public var isMarkable = false
    /// Stored by this device when the user wrote it, rather than read from a
    /// server. In a group chat only this vouches that an "outgoing" message is
    /// ours: the room decides what it says is ours, and can say it of anything.
    public var isWrittenHere = false

    /// The replies and actions the sender offered with it (XEP-0439), stored
    /// as JSON. Only ever on a plain incoming message.
    public var quickResponses: QuickResponses?

    /// Set on the rows that stand for a call (see `call`). `remoteId` holds
    /// the call's Jingle session id, and `body` is empty.
    public var callOutcome: CallOutcome?
    /// How long an answered call lasted.
    public var callDuration: TimeInterval?
    /// When an answered call was picked up, which its end measures from.
    public var callAnsweredAt: Date?
    /// Whether the call was proposed with video.
    public var callIsVideo = false

    /// The stanza id of our correction or retraction of this message that the
    /// server hasn't acknowledged. A later one replaces it, as only the latest
    /// state needs to reach the peer.
    public var actionPendingId: String?

    public init(
        id: Int64? = nil,
        conversationId: Int64,
        direction: Direction,
        sender: JID,
        nick: String? = nil,
        occupantId: String? = nil,
        body: String,
        timestamp: Date = Date(),
        status: Status? = nil,
        isRead: Bool? = nil,
        encryption: Encryption = .none,
        remoteId: String? = nil,
        originId: String? = nil,
        serverId: String? = nil,
        replyToId: String? = nil,
        replyToSender: JID? = nil,
        replyFallback: String? = nil,
        error: String? = nil,
        omemoDevice: Int32? = nil,
        omemoTrust: OMEMODevice.Trust? = nil,
    ) {
        self.id = id
        self.conversationId = conversationId
        self.direction = direction
        self.sender = sender
        self.nick = nick
        self.occupantId = occupantId
        self.body = body
        self.timestamp = timestamp
        self.status = status ?? (direction == .incoming ? .received : .pending)
        self.isRead = isRead ?? (direction == .outgoing)
        self.encryption = encryption
        self.remoteId = remoteId
        self.originId = originId
        self.serverId = serverId
        self.replyToId = replyToId
        self.replyToSender = replyToSender
        self.replyFallback = replyFallback
        self.error = error
        self.omemoDevice = omemoDevice
        self.omemoTrust = omemoTrust
        self.link = Self.previewLink(for: body, encryption: encryption)
    }

    /// Whether an outgoing message gets the trust our own words do (images
    /// fetched unasked, links previewed). A 1:1 chat's outgoing messages come
    /// from our own server, but a room's from the room, which can make
    /// anything look like ours, so there only what was written here counts.
    public static func isTrustedOutgoing(isOutgoing: Bool, isWrittenHere: Bool, inGroup: Bool) -> Bool {
        isOutgoing && (isWrittenHere || !inGroup)
    }

    public var author: Author { Author(jid: sender, nick: nick, occupantId: occupantId) }

    /// What a "/me" message (XEP-0245) says its author does, to show after
    /// their name, as in "/me waves" for "Alice waves".
    public var meAction: String? {
        guard !isRetracted, encryption != .omemoUndecryptable else { return nil }
        return Self.meAction(in: body)
    }

    /// The command only counts at the very start of the body, as typed.
    public static func meAction(in body: String) -> String? {
        guard body.hasPrefix("/me "), case let action = body.dropFirst(4), !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(action)
    }

    /// Replaces the text, keeping the preview link in step.
    mutating func setBody(_ body: String) {
        self.body = body
        link = Self.previewLink(for: body, encryption: encryption)
    }

    private static func previewLink(for body: String, encryption: Encryption) -> String? {
        encryption == .omemoUndecryptable ? nil : LinkDetector.previewLink(in: body)?.absoluteString
    }

    public static let databaseTableName = "message"
    public static let conversation = belongsTo(Conversation.self)
    public static let reactions = hasMany(Reaction.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Message {
    /// How well a message fits a reference to it, for choosing among several
    /// that carry the same id. A sender picks the `id` and `originId` of what
    /// they send, so anyone can copy another's; only `serverId` is assigned by
    /// the room or our server. It therefore wins, and the newest of the rest.
    struct ReferenceRank: Comparable {
        var isServerId: Bool
        var timestamp: Date
        var id: Int64

        static func < (a: Self, b: Self) -> Bool {
            (a.isServerId ? 1 : 0, a.timestamp, a.id) < (b.isServerId ? 1 : 0, b.timestamp, b.id)
        }
    }

    /// Nil if `reference` isn't one of this message's ids.
    func referenceRank(for reference: String) -> ReferenceRank? {
        guard serverId == reference || remoteId == reference || originId == reference else { return nil }
        return ReferenceRank(isServerId: serverId == reference, timestamp: timestamp, id: id ?? 0)
    }
}

extension Message {
    /// One of our stored messages whose text a correction may replace, a
    /// file aside, which only the caller can look up. A call row is ours with
    /// no words, and its remote id is the call's session id: a correction to
    /// it would turn the call into text.
    public var isEditableText: Bool {
        direction == .outgoing && !isRetracted && encryption != .omemoUndecryptable && callOutcome == nil && id != nil
    }
}

extension QuickResponses {
    /// Notes `actionId` as chosen. False if it isn't offered or was chosen already.
    mutating func choose(_ actionId: String) -> Bool {
        guard actions.contains(where: { $0.id == actionId }), !chosen.contains(actionId) else { return false }
        chosen.append(actionId)
        return true
    }
}
