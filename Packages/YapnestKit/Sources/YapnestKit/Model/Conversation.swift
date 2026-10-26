import Foundation
import GRDB

public struct Conversation: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        case chat
        case groupchat
    }

    public var id: Int64?
    public var peer: JID
    public var kind: Kind
    public var lastActivityAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var draft: String?
    /// Whether outgoing messages are OMEMO-encrypted.
    public var isEncrypted: Bool
    /// Whether to fetch link previews; nil until the user decides.
    public var linkPreviews: Bool?
    /// Whether the server's archive has nothing older than what we have, so
    /// scrolling back stops asking.
    public var historyComplete: Bool
    /// The archive id of the oldest message the last request for older
    /// history returned; the next one continues before it. Without it the
    /// next starts from the oldest message we have.
    public var historyCursor: String?
    /// The sound of this chat's notifications: nil for the system's, else
    /// what `NotificationSound` stores.
    public var notificationSound: String?
    /// For a group that notifies for every message: the minutes after a
    /// notification during which the next messages arrive silently. nil is off.
    public var notificationInterval: Int?
    /// When this device last notified loudly about the chat. It starts the
    /// interval, and is never synced: each device has been told on its own.
    public var lastLoudNotificationAt: Date?
    /// When the chat was archived. The chat is archived while this is set and
    /// nothing newer than it has arrived, which is what the other devices
    /// are told; `isArchived` is that answer.
    public var archivedAt: Date?

    public init(
        id: Int64? = nil,
        peer: JID,
        kind: Kind = .chat,
        lastActivityAt: Date = Date(),
        isPinned: Bool = false,
        isArchived: Bool = false,
        draft: String? = nil,
        isEncrypted: Bool = true,
        linkPreviews: Bool? = nil,
        historyComplete: Bool = false,
        historyCursor: String? = nil,
        notificationSound: String? = nil,
        notificationInterval: Int? = nil,
        lastLoudNotificationAt: Date? = nil,
        archivedAt: Date? = nil,
    ) {
        self.id = id
        self.peer = peer
        self.kind = kind
        self.lastActivityAt = lastActivityAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.draft = draft
        self.isEncrypted = isEncrypted
        self.linkPreviews = linkPreviews
        self.historyComplete = historyComplete
        self.historyCursor = historyCursor
        self.notificationSound = notificationSound
        self.notificationInterval = notificationInterval
        self.lastLoudNotificationAt = lastLoudNotificationAt
        self.archivedAt = archivedAt
    }

    public static let databaseTableName = "conversation"
    public static let messages = hasMany(Message.self)
    public static let contact = belongsTo(Contact.self, using: ForeignKey(["peer"], to: ["jid"]))
    public static let groupChat = hasOne(GroupChat.self)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
