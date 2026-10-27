import Foundation
import GRDB

/// Chat list actions on whole conversations.
extension AppDatabase {
    public func setPinned(_ pinned: Bool, conversationId: Int64) throws {
        try writer.write { db in
            guard let conversation = try Conversation.fetchOne(db, key: conversationId) else { return }
            try Self.setChatSetting(db, conversation.peer, "pinned", pinned ? "1" : nil)
        }
    }

    /// Archived conversations leave the main list until a new message arrives.
    /// The time is what other devices are told. A new message unarchives the
    /// chat without touching it: every device sees that message, so they all
    /// reach the same answer.
    public func setArchived(_ archived: Bool, conversationId: Int64) throws {
        try writer.write { db in
            guard let conversation = try Conversation.fetchOne(db, key: conversationId), conversation.isArchived != archived else { return }
            _ = try Conversation.filter(key: conversationId).updateAll(
                db, Column("isArchived").set(to: archived), Column("archivedAt").set(to: archived ? Date() : nil),
            )
            try Self.touch(db, item: Self.chatItem(conversation.peer), key: "archivedAt")
        }
    }

    /// What was typed in the composer and not sent. Empty or blank text clears
    /// it. Nothing that orders the chat list changes, so typing doesn't move
    /// the chat. A chat with no messages yet has no conversation, so a draft
    /// typed in it makes one, which the chat list shows with its draft; it
    /// sorts last until a message arrives. Clearing a draft makes none.
    public func setDraft(_ draft: String?, peer: JID) throws {
        let kept = draft.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        try writer.write { db in
            if kept != nil { _ = try Self.conversation(db, with: peer) }
            _ = try Conversation.filter(Column("peer") == peer).updateAll(db, Column("draft").set(to: kept))
        }
    }

    public func draft(peer: JID) throws -> String? {
        try reader.read { db in try Conversation.filter(Column("peer") == peer).fetchOne(db)?.draft }
    }

    /// Marks the latest incoming message that isn't retracted unread, so the conversation shows
    /// as unread until it's opened again.
    public func markUnread(conversationId: Int64) throws {
        try writer.write { db in
            guard var last = try Message
                .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.incoming && Column("isRetracted") == false)
                .order(Column("timestamp").desc, Column("id").desc)
                .fetchOne(db) else { return }
            last.isRead = false
            try last.update(db)
        }
    }

    /// Deletes the conversation and its messages from this device. Returns
    /// their attachments, whose rows are gone with them but whose files the
    /// caller still has to remove.
    @discardableResult
    public func deleteConversation(id: Int64) throws -> [Attachment] {
        let (peer, attachments) = try writer.write { db in
            let peer = try Conversation.fetchOne(db, key: id)?.peer
            if let peer { try Self.resetChatSettings(db, peer: peer) }
            let attachments = try Attachment.fetchAll(db, sql: """
                SELECT attachment.* FROM attachment
                JOIN message ON message.id = attachment.messageId
                WHERE message.conversationId = ?
                """, arguments: [id])
            _ = try Conversation.deleteOne(db, key: id)
            return (peer, attachments)
        }
        if let peer { ShareSuggestions.remove([peer]) }
        return attachments
    }

    /// How far back the server's archive has been read for the chat with `peer`.
    public func historyState(peer: JID) throws -> (isComplete: Bool, cursor: String?) {
        try reader.read { db in
            let conversation = try Conversation.filter(Column("peer") == peer).fetchOne(db)
            return (conversation?.historyComplete ?? false, conversation?.historyCursor)
        }
    }

    /// Records a page of older history: where the next one continues, and
    /// whether the archive has nothing older.
    public func setHistoryState(peer: JID, isComplete: Bool, cursor: String?) throws {
        try writer.write { db in
            _ = try Conversation.filter(Column("peer") == peer)
                .updateAll(db, Column("historyComplete").set(to: isComplete), Column("historyCursor").set(to: cursor))
        }
    }

    public func observeArchivedCount() -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try Conversation.filter(Column("isArchived") == true).fetchCount(db) }
    }
}
