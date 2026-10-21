import Foundation
import GRDB

extension AppDatabase {
    public func isInRoster(_ jid: JID) throws -> Bool {
        try reader.read { db in try Contact.fetchOne(db, key: jid)?.isInRoster ?? false }
    }

    /// Whether a `subscribe` from `jid` needs no answer from the user: they
    /// already see our presence (we approved them before), we have a request
    /// to them outstanding (the server's `ask`, so every device and client of
    /// the user sees it), or the user added them on this device (for when
    /// they accepted ours and the server didn't keep the pre-approval). A
    /// roster item alone isn't consent, as the server can create one for a
    /// stranger.
    func hasApprovedOrAdded(_ jid: JID) throws -> Bool {
        try reader.read { db in
            guard let contact = try Contact.fetchOne(db, key: jid) else { return false }
            return contact.isAddedByUser || contact.isSubscriptionPending || contact.subscription == .from || contact.subscription == .both
        }
    }

    /// Applies `change` to the stored contact, or a new one, and saves only
    /// if it changed anything. Whether it did.
    @discardableResult
    static func updateContact(_ db: Database, _ jid: JID, _ change: (inout Contact) -> Void) throws -> Bool {
        var contact = try Contact.fetchOne(db, key: jid) ?? Contact(jid: jid)
        let before = contact
        change(&contact)
        guard contact != before else { return false }
        try contact.save(db)
        return true
    }

    /// Notes that the user chose to add `jid`, before the server can answer.
    func markAddedByUser(_ jid: JID) throws {
        try writer.write { db in try Self.updateContact(db, jid) { $0.isAddedByUser = true } }
    }

    public func updateRosterItem(jid: JID, name: String?, subscription: Contact.Subscription, isPending: Bool, groups: [String] = []) throws {
        try writer.write { db in
            var contact = try Contact.fetchOne(db, key: jid) ?? Contact(jid: jid)
            contact.name = name
            contact.rosterGroups = groups
            contact.subscription = subscription
            contact.isSubscriptionPending = isPending
            contact.isInRoster = true
            // Approved, here or on another device.
            if subscription == .from || subscription == .both {
                contact.subscriptionRequestedAt = nil
                contact.requestedNickname = nil
            }
            try contact.save(db)
        }
    }

    /// Records `jid`'s current avatar; nil when they have none.
    public func setAvatarHash(_ hash: String?, for jid: JID) throws {
        try writer.write { db in try Self.updateContact(db, jid) { $0.avatarHash = hash } }
    }

    /// Records the name `jid` publishes for themselves; nil when they have none.
    func setNickname(_ nickname: String?, for jid: JID) throws {
        try writer.write { db in try Self.updateContact(db, jid) { $0.nickname = nickname } }
    }

    /// Records when `jid` was last seen, or forgets it when nil.
    public func setLastSeen(_ date: Date?, for jid: JID) throws {
        try writer.write { db in
            guard var contact = try Contact.fetchOne(db, key: jid), contact.lastSeenAt != date else { return }
            contact.lastSeenAt = date
            try contact.save(db)
        }
    }

    func clearLastSeen() throws {
        try writer.write { db in try db.execute(sql: "UPDATE contact SET lastSeenAt = NULL WHERE lastSeenAt IS NOT NULL") }
    }

    /// Peers of our conversations, for refreshing their avatars.
    public func conversationPeers() throws -> [JID] {
        try reader.read { db in try JID.fetchAll(db, sql: "SELECT peer FROM conversation WHERE kind = 'chat'") }
    }

    /// Peers of the chats that hold a message.
    func peersWithMessages() throws -> Set<JID> {
        try reader.read { db in
            Set(try JID.fetchAll(db, sql: "SELECT DISTINCT peer FROM conversation WHERE kind = 'chat' AND id IN (SELECT conversationId FROM message)"))
        }
    }

    /// Everyone in our roster, by name, for picking group members.
    public func roster() throws -> [Contact] {
        try reader.read { db in
            try Contact.filter(Column("isInRoster") == true).fetchAll(db)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    public func removeRosterItem(jid: JID) throws {
        try writer.write { db in
            guard var contact = try Contact.fetchOne(db, key: jid) else { return }
            contact.isInRoster = false
            contact.isAddedByUser = false
            contact.subscription = .none
            contact.isSubscriptionPending = false
            try contact.update(db)
        }
    }

    /// 1:1 outgoing messages in `since..<before` that never reached the
    /// server: written to a connection that dropped before the server
    /// acknowledged them (XEP-0198). Group chats confirm by echoing, after
    /// each room's own catch-up.
    func unconfirmedOutgoing(before: Date, since: Date) throws -> [(Message, JID)] {
        try reader.read { db in
            let chats = try Conversation.fetchAll(db, sql: "SELECT * FROM conversation WHERE kind = 'chat'")
            let peers = Dictionary(uniqueKeysWithValues: chats.compactMap { chat in chat.id.map { ($0, chat.peer) } })
            let messages = try Message
                .filter(peers.keys.contains(Column("conversationId")))
                .filter(Column("direction") == Message.Direction.outgoing)
                .filter(Column("timestamp") < before && Column("timestamp") >= since)
                .filter(Column("isRetracted") == false)
                .filter(Column("status") == Message.Status.pending)
                .order(Column("timestamp"))
                .fetchAll(db)
            return messages.compactMap { message in peers[message.conversationId].map { (message, $0) } }
        }
    }

    /// The server received our message `remoteId` to `peer`.
    func markSent(peer: JID, remoteId: String) throws {
        try writer.write { db in
            guard let id = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return }
            try Self.updateStatus(db, .sent, conversationId: id, remoteId: remoteId)
        }
    }

    /// The server has our reactions stanza `id`.
    func clearPendingReactions(id: String) throws {
        try writer.write { db in
            try Reaction.filter(Column("pendingId") == id).updateAll(db, Column("pendingId").set(to: nil))
        }
    }

    /// Our reactions the server hasn't acknowledged, as the message they are
    /// on, its conversation's peer, and the id of the stanza that carries them.
    func pendingReactions() throws -> [(message: Message, peer: JID, id: String)] {
        try reader.read { db in
            let rows = try Reaction.filter(Column("pendingId") != nil).fetchAll(db)
            var seen = Set<Int64>()
            let messages = Dictionary(uniqueKeysWithValues: try Message.fetchAll(db, keys: Set(rows.map(\.messageId))).compactMap { message in
                message.id.map { ($0, message) }
            })
            let peers = Dictionary(uniqueKeysWithValues: try Conversation.fetchAll(db, keys: Set(messages.values.map(\.conversationId))).compactMap { chat in
                chat.id.map { ($0, chat.peer) }
            })
            return rows.compactMap { row in
                guard let id = row.pendingId, seen.insert(row.messageId).inserted,
                      let message = messages[row.messageId], let peer = peers[message.conversationId] else { return nil }
                return (message, peer, id)
            }
        }
    }

    /// Gives up on reactions that can no longer be sent, so they don't stay
    /// marked as sending for good.
    func clearPendingReactions(messageId: Int64) throws {
        try writer.write { db in
            try Reaction.filter(Column("messageId") == messageId).updateAll(db, Column("pendingId").set(to: nil))
        }
    }

    /// The server has our correction or retraction stanza `id`.
    func clearPendingAction(id: String) throws {
        try writer.write { db in
            try Message.filter(Column("actionPendingId") == id).updateAll(db, Column("actionPendingId").set(to: nil))
        }
    }

    /// Our corrections and retractions the server hasn't acknowledged, as the
    /// message they are of, its conversation's peer, and the stanza's id.
    func pendingActions() throws -> [(message: Message, peer: JID, id: String)] {
        try reader.read { db in
            let messages = try Message.filter(Column("actionPendingId") != nil).fetchAll(db)
            let peers = Dictionary(uniqueKeysWithValues: try Conversation.fetchAll(db, keys: Set(messages.map(\.conversationId))).compactMap { chat in
                chat.id.map { ($0, chat.peer) }
            })
            return messages.compactMap { message in
                guard let id = message.actionPendingId, let peer = peers[message.conversationId] else { return nil }
                return (message, peer, id)
            }
        }
    }

    public func reactions(on message: Message, from sender: JID) throws -> Set<String> {
        try reader.read { db in
            Set(try message.request(for: Message.reactions).filter(Column("sender") == sender).fetchAll(db).map(\.emoji))
        }
    }

    /// The newest message the peer sent; with `markable`, the newest that
    /// asked for a displayed marker (XEP-0333).
    func lastIncoming(conversationId: Int64, markable: Bool = false, through date: Date = .distantFuture) throws -> Message? {
        try reader.read { db in
            var request = Message
                .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.incoming
                    && Column("timestamp") <= date)
            if markable { request = request.filter(Column("isMarkable") == true) }
            return try request.order(Column("timestamp").desc).fetchOne(db)
        }
    }
}

extension AppDatabase {
    /// `jid` asked to see our presence. The server repeats unanswered
    /// requests each time we sign in, so the first time is kept.
    func recordContactRequest(from jid: JID, nickname: String?, at date: Date = Date()) throws {
        try writer.write { db in
            var contact = try Contact.fetchOne(db, key: jid) ?? Contact(jid: jid)
            if contact.subscriptionRequestedAt == nil { contact.subscriptionRequestedAt = date }
            if let nickname, !nickname.isEmpty { contact.requestedNickname = nickname }
            try contact.save(db)
        }
    }

    /// Answered, withdrawn, or no longer waiting on the server.
    func clearContactRequest(from jid: JID) throws {
        try writer.write { db in
            guard var contact = try Contact.fetchOne(db, key: jid), contact.subscriptionRequestedAt != nil else { return }
            contact.subscriptionRequestedAt = nil
            contact.requestedNickname = nil
            try contact.update(db)
        }
    }

    /// Drops requests the server no longer has, such as ones another
    /// device answered: those it didn't repeat when we signed in.
    func clearContactRequests(except repeated: Set<JID>) throws {
        try writer.write { db in
            for var contact in try Contact.filter(Column("subscriptionRequestedAt") != nil).fetchAll(db) where !repeated.contains(contact.jid) {
                contact.subscriptionRequestedAt = nil
                contact.requestedNickname = nil
                try contact.update(db)
            }
        }
    }

    /// People waiting for an answer to their contact request, newest first.
    public func observeContactRequests() -> ValueObservation<ValueReducers.Fetch<[Contact]>> {
        ValueObservation.tracking(Self.contactRequests)
    }

    static func contactRequests(_ db: Database) throws -> [Contact] {
        try Contact
            .filter(Column("subscriptionRequestedAt") != nil && Column("isBlocked") == false)
            .order(Column("subscriptionRequestedAt").desc)
            .fetchAll(db)
    }

    /// Makes the server's blocklist (XEP-0191) ours: exactly these are blocked.
    func setBlocklist(_ blocked: Set<JID>) throws {
        var newlyBlocked: [JID] = []
        defer { ShareSuggestions.remove(newlyBlocked) }
        try writer.write { db in
            newlyBlocked = []
            for var contact in try Contact.filter(Column("isBlocked") == true).fetchAll(db) where !blocked.contains(contact.jid) {
                contact.isBlocked = false
                try contact.update(db)
            }
            for jid in blocked {
                if try Self.updateContact(db, jid, { $0.isBlocked = true }) { newlyBlocked.append(jid) }
            }
        }
    }

    func setBlocked(_ blocked: Bool, _ jid: JID) throws {
        try writer.write { db in try Self.updateContact(db, jid) { $0.isBlocked = blocked } }
        // Blocked people shouldn't come up as someone to share with.
        if blocked { ShareSuggestions.remove([jid]) }
    }

    public func isBlocked(_ jid: JID) throws -> Bool {
        try reader.read { db in try Contact.fetchOne(db, key: jid)?.isBlocked ?? false }
    }

    /// The stanza-ids our server gave the latest messages `jid` sent us.
    func lastServerIds(from jid: JID, limit: Int) throws -> [String] {
        try reader.read { db in
            guard let conversation = try Conversation.filter(Column("peer") == jid && Column("kind") == Conversation.Kind.chat).fetchOne(db) else { return [] }
            return try Message
                .filter(Column("conversationId") == conversation.id && Column("direction") == Message.Direction.incoming && Column("serverId") != nil)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
                .compactMap(\.serverId)
        }
    }
}
