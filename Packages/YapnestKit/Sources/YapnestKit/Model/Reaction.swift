import GRDB

/// One emoji reaction by one sender on one message (XEP-0444).
public struct Reaction: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var messageId: Int64
    public var sender: JID
    /// In group chats: the reactor's nickname; empty otherwise. Tells apart
    /// occupants of anonymous rooms, who all share the room's address.
    public var nick: String
    public var emoji: String
    /// In rooms that vouch for XEP-0421 ids: the reactor's, which outlasts
    /// their nickname.
    public var occupantId: String?
    /// For our own reactions: the id of the stanza that carries them while the
    /// server hasn't acknowledged it. Nil once it has, and on anyone else's.
    public var pendingId: String?

    public init(messageId: Int64, sender: JID, nick: String = "", emoji: String, occupantId: String? = nil, pendingId: String? = nil) {
        self.messageId = messageId
        self.sender = sender
        self.nick = nick
        self.emoji = emoji
        self.occupantId = occupantId
        self.pendingId = pendingId
    }

    public var author: Author { Author(jid: sender, nick: nick.isEmpty ? nil : nick, occupantId: occupantId) }

    public static let databaseTableName = "reaction"
    public static let message = belongsTo(Message.self)
}
