import Foundation
import GRDB

extension AppDatabase {
    public func groupChat(_ jid: JID) throws -> GroupChat? {
        try reader.read { db in try GroupChat.filter(Column("jid") == jid).fetchOne(db) }
    }

    public func groupChats() throws -> [GroupChat] {
        try reader.read { db in try GroupChat.order(Column("jid")).fetchAll(db) }
    }

    public func observeGroupChat(_ jid: JID) -> ValueObservation<ValueReducers.Fetch<GroupChat?>> {
        ValueObservation.tracking { db in try GroupChat.filter(Column("jid") == jid).fetchOne(db) }
    }

    /// Records that we're in the room at `jid`, creating its conversation if
    /// needed. An existing group we had left is rejoined; its nickname and
    /// name are kept unless given.
    @discardableResult
    public func joinGroupChat(_ jid: JID, nickname: String, name: String? = nil, isBookmarked: Bool? = nil) throws -> GroupChat {
        try writer.write { db in
            var conversation = try Self.conversation(db, with: jid, kind: .groupchat)
            // A chat opened with the room's address before joining it is the
            // room's conversation now. Its unsent messages go to the room.
            if conversation.kind != .groupchat {
                conversation.kind = .groupchat
                conversation.isEncrypted = false
                try conversation.update(db)
            }
            if var group = try GroupChat.fetchOne(db, key: conversation.id) {
                group.hasLeft = false
                let renamed = group.nickname != nickname
                group.nickname = nickname
                if let name { group.name = name }
                if let isBookmarked { group.isBookmarked = isBookmarked }
                try group.update(db)
                if renamed { try Self.refreshAddressesMe(db, conversationId: group.conversationId, nickname: nickname) }
                return group
            }
            // Encryption waits until we know the room is private.
            try Conversation.filter(key: conversation.id).updateAll(db, Column("isEncrypted").set(to: false))
            let group = GroupChat(conversationId: conversation.id!, jid: jid, nickname: nickname, name: name, isBookmarked: isBookmarked ?? false)
            try group.insert(db)
            try Self.refreshAddressesMe(db, conversationId: group.conversationId, nickname: nickname)
            return group
        }
    }

    /// Applies `change` to the stored group; does nothing if there is none.
    public func updateGroupChat(_ jid: JID, _ change: (inout GroupChat) -> Void) throws {
        try writer.write { db in
            guard var group = try GroupChat.filter(Column("jid") == jid).fetchOne(db) else { return }
            let before = group
            change(&group)
            if group != before { try group.update(db) }
            // Mention-only groups count by the stored decision, which has to
            // follow the nickname in use now.
            if group.nickname != before.nickname {
                try Self.refreshAddressesMe(db, conversationId: group.conversationId, nickname: group.nickname)
            }
        }
    }

    /// Stores a message the room delivered live after its catch-up, and moves
    /// the room's archive cursor to its stanza-id in the same write. Ids
    /// aren't ordered, so the cursor can't tell newer from older; this is
    /// only for stanzas that arrive in the archive's order, after the sync.
    func ingestLive(_ inbound: InboundMessage, in group: GroupChat) throws -> IngestResult {
        let insecure = allowsInsecureLinks
        return try writer.write { db in
            let result = try Self.ingest(db, inbound, allowsInsecureLinks: insecure)
            if let serverId = inbound.serverId, serverId != group.lastArchiveId {
                try GroupChat.filter(Column("conversationId") == group.conversationId)
                    .updateAll(db, Column("lastArchiveId").set(to: serverId))
            }
            return result
        }
    }

    /// Records what the room's configuration says about its privacy. A group
    /// that turns out to be private encrypts by default while we haven't
    /// written in it yet; others can't encrypt at all.
    func setRoomInfo(_ jid: JID, name: String?, isMembersOnly: Bool, isNonAnonymous: Bool, hasOccupantIds: Bool = false) throws {
        try writer.write { db in
            guard var group = try GroupChat.filter(Column("jid") == jid).fetchOne(db),
                  var conversation = try Conversation.fetchOne(db, key: group.conversationId) else { return }
            let wasPrivate = group.isPrivate
            group.isMembersOnly = isMembersOnly
            group.isNonAnonymous = isNonAnonymous
            group.hasOccupantIds = hasOccupantIds
            if let name, !name.isEmpty { group.name = name }
            try group.update(db)

            if !group.isPrivate {
                conversation.isEncrypted = false
            } else if !wasPrivate {
                if try Message
                    .filter(Column("conversationId") == conversation.id && Column("direction") == Message.Direction.outgoing)
                    .isEmpty(db) { conversation.isEncrypted = true }
            }
            try conversation.update(db)
        }
    }

    /// Outgoing messages of one conversation in `since..<before` that the
    /// server hasn't confirmed, like `unconfirmedOutgoing(before:since:)`.
    func unconfirmedOutgoing(conversationId: Int64, before: Date, since: Date) throws -> [Message] {
        try reader.read { db in
            try Message
                .filter(Column("conversationId") == conversationId)
                .outgoingOnly()
                .filter(Column("timestamp") < before && Column("timestamp") >= since)
                .filter(Column("isRetracted") == false)
                .filter(Column("status") == Message.Status.pending
                    || (Column("status") == Message.Status.sent && Column("serverId") == nil))
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    /// Messages of a conversation that were never sent, however old, or
    /// written after the room's catch-up began.
    func pendingOutgoing(conversationId: Int64) throws -> [Message] {
        try reader.read { db in
            try Message
                .filter(Column("conversationId") == conversationId)
                .outgoingOnly()
                .filter(Column("isRetracted") == false && Column("status") == Message.Status.pending)
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    /// When the newest message from someone else in `peer` was sent, to ask a
    /// room without an archive for what came after. Our own don't count: one
    /// written offline carries the time it was written, and would skip what
    /// the room held for us meanwhile.
    func lastIncomingMessageDate(in peer: JID) throws -> Date? {
        try reader.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MAX(message.timestamp) FROM message JOIN conversation ON conversation.id = message.conversationId
                WHERE conversation.peer = ? AND message.direction = 'incoming'
                """, arguments: [peer])
        }
    }
}
