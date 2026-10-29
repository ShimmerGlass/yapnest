import Foundation
import GRDB

/// A row of the chat list: a conversation with its contact, last message and
/// unread count.
public struct ChatListItem: Hashable, Sendable, Identifiable {
    public var conversation: Conversation
    public var contact: Contact?
    public var groupChat: GroupChat?
    public var lastMessage: Message?
    /// The file `lastMessage` carries, if any.
    public var lastAttachment: Attachment?
    /// All unread messages, which mark read and unread go by.
    public var unreadCount: Int
    /// The unread messages that notify, by the rule the app badge uses. A
    /// quiet group can have unread messages and none of these, and the row
    /// then shows a dot instead of a count the user was never told about.
    public var notifyingUnreadCount: Int

    public var id: Int64 { conversation.id! }

    public var title: String {
        groupChat?.displayName ?? contact?.displayName ?? conversation.peer.shortName
    }

    /// Conversations with their contact; `lastMessage` and the unread counts are
    /// filled in by `fetch` because GRDB can't express "latest child" as an
    /// association.
    private struct Row: Decodable, FetchableRecord {
        var conversation: Conversation
        var contact: Contact?
        var groupChat: GroupChat?
    }

    static func fetch(_ db: Database, archived: Bool) throws -> [ChatListItem] {
        let rows = try Conversation
            .filter(Column("isArchived") == archived)
            .including(optional: Conversation.contact.forKey("contact"))
            .including(optional: Conversation.groupChat.forKey("groupChat"))
            .order(Column("isPinned").desc, Column("lastActivityAt").desc)
            .asRequest(of: Row.self)
            .fetchAll(db)

        // One index lookup per listed conversation, rather than ranking
        // every message stored.
        let latest = try Message.fetchAll(db, sql: """
            SELECT message.* FROM conversation
            JOIN message ON message.id = (
                SELECT id FROM message WHERE conversationId = conversation.id AND \(AppDatabase.isNotEvent)
                ORDER BY timestamp DESC, id DESC LIMIT 1
            )
            WHERE conversation.isArchived = ?
            """, arguments: [archived])
        let latestByConversation = Dictionary(uniqueKeysWithValues: latest.map { ($0.conversationId, $0) })
        let attachments = try AppDatabase.attachments(db, messageIds: latest.compactMap(\.id))

        let counts = Dictionary(
            try AppDatabase.unreadCounts(db, archived: archived).map { ($0.id, (unread: $0.unread, notifying: $0.notifying)) },
            uniquingKeysWith: { a, _ in a },
        )

        return rows.map { row in
            ChatListItem(
                conversation: row.conversation,
                contact: row.contact,
                groupChat: row.groupChat,
                lastMessage: latestByConversation[row.conversation.id!],
                lastAttachment: latestByConversation[row.conversation.id!].flatMap { $0.id }.flatMap { attachments[$0] },
                unreadCount: counts[row.conversation.id!]?.unread ?? 0,
                notifyingUnreadCount: counts[row.conversation.id!]?.notifying ?? 0,
            )
        }
    }
}

extension AppDatabase {
    public func chatList(archived: Bool = false) throws -> [ChatListItem] {
        try reader.read { db in try ChatListItem.fetch(db, archived: archived) }
    }

    /// Emits the chat list whenever it changes.
    public func observeChatList(archived: Bool = false) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[ChatListItem]>>> {
        ValueObservation.tracking { db in try ChatListItem.fetch(db, archived: archived) }.removeDuplicates()
    }
}
