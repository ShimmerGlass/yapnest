import Foundation
import GRDB

extension AppDatabase {
    /// Returns the conversation with `peer`, creating it if needed.
    @discardableResult
    public func conversation(with peer: JID, kind: Conversation.Kind = .chat) throws -> Conversation {
        try writer.write { db in try Self.conversation(db, with: peer, kind: kind) }
    }

    static func existingConversation(_ db: Database, peer: JID) throws -> Conversation? {
        try Conversation.filter(Column("peer") == peer).fetchOne(db)
    }

    static func conversationId(_ db: Database, peer: JID) throws -> Int64? {
        try Conversation.filter(Column("peer") == peer).select(Column("id"), as: Int64.self).fetchOne(db)
    }

    static func conversation(_ db: Database, with peer: JID, kind: Conversation.Kind = .chat) throws -> Conversation {
        if let existing = try Self.existingConversation(db, peer: peer) {
            return existing
        }
        // Sorts last until its first message sets the real time.
        var conversation = Conversation(peer: peer, kind: kind, lastActivityAt: .distantPast, isEncrypted: try encryptsByDefault(db, with: peer))
        try conversation.insert(db)
        guard try applyStoredChatEntries(db, peer: peer) else { return conversation }
        return try Conversation.fetchOne(db, key: conversation.id) ?? conversation
    }

    /// A bare domain is a component, such as a gateway to another network,
    /// which publishes no OMEMO devices: encrypting to it could only fail. So
    /// do the people behind a gateway we chat with or have as a contact, such
    /// as `<phone>@whatsapp.example`, whose messages it relays in the clear.
    /// The user can also turn encryption off for chats started from now on.
    static func encryptsByDefault(_ db: Database, with peer: JID) throws -> Bool {
        guard peer.localPart != nil else { return false }
        guard try setting(db, .encryptsNewChats) != "0" else { return false }
        guard let gateway = JID(peer.domain) else { return true }
        let known = try Conversation.filter(Column("peer") == gateway).fetchCount(db) > 0
            || Contact.filter(Column("jid") == gateway).fetchCount(db) > 0
        return !known
    }

    /// Whether any message in the conversation carries the room's stanza-id.
    func hasStanzaIds(conversationId: Int64) throws -> Bool {
        try reader.read { try !Message.filter(Column("conversationId") == conversationId && Column("serverId") != nil).isEmpty($0) }
    }

    /// Stores `message` unless it is a duplicate of a stored one (same server
    /// stanza-id, or same sender and origin/remote id), in which case the stored
    /// copy is returned with its server id filled in.
    @discardableResult
    public func insert(_ message: Message) throws -> Message {
        try writer.write { db in try Self.insert(db, message).message }
    }

    static func insert(_ db: Database, _ message: Message) throws -> (message: Message, inserted: Bool) {
        var message = message
        if let existing = try duplicate(of: message, db) {
            return (try confirm(existing, serverId: message.serverId, db), false)
        }
        try refreshAddressesMe(db, &message)
        try message.insert(db)
        try refreshReplies(db, toOutgoing: message)
        // Older history leaves a chat where it is in the list, so it only
        // moves one that has no place yet: one restored from the archive.
        // Its newest message is when it last had news, and it mustn't sort
        // below chats that were never used.
        if var conversation = try Conversation.fetchOne(db, key: message.conversationId),
           message.timestamp > conversation.lastActivityAt {
            conversation.lastActivityAt = message.timestamp
            try conversation.update(db)
        }
        try unarchive(db, conversationId: message.conversationId, ifNewerThan: message.timestamp)
        return (message, true)
    }

    /// A message newer than the time a chat was archived brings it back,
    /// whatever else it does to the chat: that is the rule the other devices
    /// judge by, so all of them reach the same answer. The archiving time and
    /// its version stay as they were.
    static func unarchive(_ db: Database, conversationId: Int64, ifNewerThan timestamp: Date) throws {
        _ = try Conversation.filter(key: conversationId)
            .filter(Column("isArchived") == true && (Column("archivedAt") == nil || Column("archivedAt") < timestamp))
            .updateAll(db, Column("isArchived").set(to: false))
    }

    /// Records the server's id for a message we already have.
    private static func confirm(_ existing: Message, serverId: String?, _ db: Database) throws -> Message {
        guard existing.serverId == nil, let serverId else { return existing }
        var existing = existing
        existing.serverId = serverId
        // The archive has our message, so the server got it.
        if existing.direction == .outgoing, existing.status < .sent {
            existing.status = .sent
        }
        try existing.update(db)
        try refreshReplies(db, toOutgoing: existing)
        return existing
    }

    /// Marks what came before `inbound`, a message of ours, read.
    func markRead(before inbound: InboundMessage) throws {
        try writer.write { db in
            guard let id = try Self.conversationId(db, peer: inbound.peer) else { return }
            try Self.markRead(db, conversationId: id, through: inbound.timestamp)
        }
    }

    /// Records the server id of an archived copy of a message we already
    /// have but can't parse again, such as our own OMEMO messages, which
    /// aren't encrypted for the sending device.
    public func confirmArchived(_ inbound: InboundMessage) throws {
        guard let serverId = inbound.serverId else { return }
        try writer.write { db in
            guard let id = try Self.conversationId(db, peer: inbound.peer) else { return }
            let probe = Message(conversationId: id, direction: inbound.isOutgoing ? .outgoing : .incoming, sender: inbound.sender, body: "",
                                remoteId: inbound.id, originId: inbound.originId, serverId: serverId)
            if let existing = try Self.duplicate(of: probe, db) {
                _ = try Self.confirm(existing, serverId: serverId, db)
            }
        }
    }

    static func duplicate(of message: Message, _ db: Database) throws -> Message? {
        if let serverId = message.serverId,
           let found = try Message
            .filter(Column("serverId") == serverId && Column("conversationId") == message.conversationId)
            .fetchOne(db) {
            return found
        }
        let ids = [message.originId, message.remoteId].compactMap { $0 }
        guard !ids.isEmpty else { return nil }
        // The conversation is in each branch of the OR: SQLite doesn't carry
        // it in from outside, and would scan the whole conversation.
        let conversation = Column("conversationId") == message.conversationId
        return try Message
            .filter(Column("sender") == message.sender)
            .filter((conversation && ids.contains(Column("originId"))) || (conversation && ids.contains(Column("remoteId"))))
            .fetchOne(db)
    }

    /// Finds the message a XEP-0444 reaction or XEP-0461 reply refers to.
    ///
    /// In 1:1 chats the reference is the referenced stanza's `id` attribute,
    /// though some clients send the origin-id; in group chats it is the
    /// stanza-id assigned by the room. `direction` limits the search to
    /// messages we sent or received, for what only one side can have caused.
    /// When several match, `Message.ReferenceRank` says which is meant.
    public static func referencedMessage(_ db: Database, conversationId: Int64, id: String, direction: Message.Direction? = nil) throws -> Message? {
        try referencedMessages(db, conversationId: conversationId, id: id, direction: direction)
            .bestMatch(for: id)
    }

    /// Every message the reference could mean, in no particular order.
    static func referencedMessages(_ db: Database, conversationId: Int64, id: String, direction: Message.Direction? = nil) throws -> [Message] {
        try referenceRequest(conversationId: conversationId, id: id, direction: direction).fetchAll(db)
    }

    static func referenceRequest(conversationId: Int64, id: String, direction: Message.Direction? = nil) -> QueryInterfaceRequest<Message> {
        var request = Message.filter(repliedTo([id], in: conversationId))
        if let direction { request = request.filter(Column("direction") == direction) }
        return request
    }

    /// The message of ours with stanza id `remoteId` that the server hasn't acknowledged.
    func pendingOutgoing(remoteId: String) throws -> Message? {
        try reader.read { db in
            try Message
                .filter(Column("remoteId") == remoteId)
                .outgoingOnly()
                .notYetSent()
                .fetchOne(db)
        }
    }

    static func outgoingMessage(_ db: Database, conversationId: Int64, remoteId: String) throws -> Message? {
        try referencedMessage(db, conversationId: conversationId, id: remoteId, direction: .outgoing)
    }

    /// Moves our message `remoteId` to the status an error naming it leads to.
    /// Only while it is pending or sent: once the recipient's side confirmed
    /// it, an error naming it is not to be believed.
    static func bounceOutgoing(_ db: Database, conversationId: Int64, remoteId: String, to status: Message.Status, error: String?) throws {
        try updateOutgoing(db, conversationId: conversationId, remoteId: remoteId) { message in
            guard message.status == .pending || message.status == .sent else { return false }
            message.status = status
            message.error = error
            return true
        }
    }

    /// Saves our message `remoteId` as `change` leaves it, if it returns true.
    static func updateOutgoing(_ db: Database, conversationId: Int64, remoteId: String, _ change: (inout Message) -> Bool) throws {
        guard var message = try outgoingMessage(db, conversationId: conversationId, remoteId: remoteId), change(&message) else { return }
        try message.update(db)
    }

    /// Replaces `author`'s reactions on the referenced message, as XEP-0444
    /// requires: each reactions element carries the full set. Returns false if
    /// the message isn't stored, or is retracted: a replay would otherwise
    /// put back reactions that retracting removed. `pendingId` marks ours as
    /// not yet acknowledged by the server.
    @discardableResult
    public func setReactions(_ emojis: Set<String>, from author: Author, conversationId: Int64, messageRef: String, pendingId: String? = nil) throws -> Bool {
        try writer.write { db in
            try Self.setReactions(db, emojis, from: author, conversationId: conversationId, messageRef: messageRef, pendingId: pendingId)
        }
    }

    @discardableResult
    public func setReactions(_ emojis: Set<String>, from sender: JID, conversationId: Int64, messageRef: String) throws -> Bool {
        try setReactions(emojis, from: Author(jid: sender), conversationId: conversationId, messageRef: messageRef)
    }

    @discardableResult
    static func setReactions(_ db: Database, _ emojis: Set<String>, from author: Author, conversationId: Int64, messageRef: String, pendingId: String? = nil) throws -> Bool {
        guard let message = try referencedMessage(db, conversationId: conversationId, id: messageRef), let messageId = message.id, !message.isRetracted else {
            return false
        }
        var byAddress = Column("sender") == author.jid
        // Occupants of anonymous rooms all have the room's address; only
        // their nicknames tell them apart.
        if try Conversation.fetchOne(db, key: conversationId)?.peer == author.jid {
            byAddress = byAddress && Column("nick") == (author.nick ?? "")
        }
        // The room's id for them holds across nickname changes. Reactions
        // stored without one (our own, before the room echoed them) still
        // go by address.
        let previous = if let occupantId = author.occupantId {
            Column("occupantId") == occupantId || (Column("occupantId") == nil && byAddress)
        } else {
            byAddress
        }
        try Reaction.filter(Column("messageId") == messageId).filter(previous).deleteAll(db)
        for emoji in emojis {
            try Reaction(messageId: messageId, sender: author.jid, nick: author.nick ?? "", emoji: emoji, occupantId: author.occupantId, pendingId: pendingId).insert(db)
        }
        return true
    }

    /// Advances the status of the outgoing message with id `remoteId`. Status
    /// never goes backwards, except to `.failed` from `.pending`, or from any
    /// state when `force` is set (a stanza error from the server).
    public func updateStatus(_ status: Message.Status, conversationId: Int64, remoteId: String, force: Bool = false) throws {
        try writer.write { db in
            try Self.updateStatus(db, status, conversationId: conversationId, remoteId: remoteId, force: force)
        }
    }

    static func updateStatus(_ db: Database, _ status: Message.Status, conversationId: Int64, remoteId: String, force: Bool = false) throws {
        try updateOutgoing(db, conversationId: conversationId, remoteId: remoteId) { message in
            let allowed = force || status > message.status || (status == .failed && message.status == .pending)
            guard allowed, status != message.status else { return false }
            message.status = status
            return true
        }
    }

    /// How far one of our messages has got, and why it failed; nil if it's gone.
    func observeDeliveryState(id: Int64) -> ValueObservation<ValueReducers.Fetch<(status: Message.Status, error: String?)?>> {
        ValueObservation.tracking { db in
            try Message.fetchOne(db, key: id).map { ($0.status, $0.error) }
        }
    }

    /// Marks every incoming message in the conversation up to `date` as read.
    public func markRead(conversationId: Int64, through date: Date = .distantFuture) throws {
        try writer.write { db in try Self.markRead(db, conversationId: conversationId, through: date) }
    }

    /// Whether an incoming message up to `date` is still unread, so reading
    /// through it would move the read point forward.
    func hasUnread(conversationId: Int64, through date: Date) throws -> Bool {
        try reader.read { db in
            try Message
                .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.incoming && Column("timestamp") <= date)
                .unread()
                .isEmpty(db) == false
        }
    }

    static func markRead(_ db: Database, conversationId: Int64, through date: Date) throws {
        _ = try Message
            .filter(Column("conversationId") == conversationId && Column("timestamp") <= date)
            .unread()
            .updateAll(db, Column("isRead").set(to: true))
    }
}

extension AppDatabase {
    /// Marks an outgoing message as failed for a reason worth showing.
    public func markFailed(conversationId: Int64, remoteId: String, error: String) throws {
        try writer.write { db in
            try Self.updateOutgoing(db, conversationId: conversationId, remoteId: remoteId) { message in
                message.status = .failed
                message.error = error
                return true
            }
        }
    }

    /// Records the trust of the devices an outgoing message was encrypted for.
    public func setTrust(_ trust: OMEMODevice.Trust, conversationId: Int64, remoteId: String) throws {
        try writer.write { db in
            try Self.updateOutgoing(db, conversationId: conversationId, remoteId: remoteId) { message in
                message.omemoTrust = trust
                return true
            }
        }
    }

    /// Re-stamps the messages a device sent after the user changed its trust.
    public func setTrust(_ trust: OMEMODevice.Trust, sender: JID, device: Int32) throws {
        try writer.write { db in
            _ = try Message
                .filter(Column("sender") == sender && Column("omemoDevice") == device)
                .updateAll(db, Column("omemoTrust").set(to: trust))
        }
    }

    public func markPending(conversationId: Int64, remoteId: String) throws {
        try writer.write { db in
            try Self.updateOutgoing(db, conversationId: conversationId, remoteId: remoteId) { message in
                message.status = .pending
                message.error = nil
                return true
            }
        }
    }

    public func isEncrypted(with peer: JID) throws -> Bool {
        try reader.read { db in
            try Self.existingConversation(db, peer: peer)?.isEncrypted ?? Self.encryptsByDefault(db, with: peer)
        }
    }

    /// Notes that the user chose the action `actionId` offered by `messageId`.
    /// Whether it was newly noted: the check and the note are one write, so of
    /// two windows choosing at once only one is told yes and sends the action.
    @discardableResult
    public func recordChosenAction(_ actionId: String, on messageId: Int64) throws -> Bool {
        try writer.write { db in
            guard var message = try Message.fetchOne(db, key: messageId), var offer = message.quickResponses,
                  offer.choose(actionId) else { return false }
            message.quickResponses = offer
            try message.update(db)
            return true
        }
    }

    /// Takes back a note from `recordChosenAction` whose action never went out.
    func forgetChosenAction(_ actionId: String, on messageId: Int64) throws {
        try writer.write { db in
            guard var message = try Message.fetchOne(db, key: messageId), var offer = message.quickResponses,
                  offer.chosen.contains(actionId) else { return }
            offer.chosen.removeAll { $0 == actionId }
            message.quickResponses = offer
            try message.update(db)
        }
    }

    public func setEncrypted(_ encrypted: Bool, with peer: JID) throws {
        try writer.write { db in
            var conversation = try Self.conversation(db, with: peer)
            conversation.isEncrypted = encrypted
            try conversation.update(db)
        }
    }
}

extension AppDatabase {
    /// Our own correction of `message` (XEP-0308), stored before it's sent.
    public func applyEdit(_ body: String, to messageId: Int64, at date: Date = Date(), marksEdited: Bool = true, actionId: String? = nil) throws -> Message? {
        try writer.write { db in
            guard var message = try Message.fetchOne(db, key: messageId), !message.isRetracted else { return nil }
            message.setBody(body)
            if let actionId { message.actionPendingId = actionId; message.actionError = nil }
            if marksEdited { message.editedAt = date }
            try message.update(db)
            return message
        }
    }

    /// Our own retraction of `message` (XEP-0424); returns its file to delete.
    /// `actionId` is the stanza that carries it, kept until acknowledged.
    public func applyRetraction(of messageId: Int64, actionId: String? = nil) throws -> Attachment? {
        try writer.write { db in
            guard var message = try Message.fetchOne(db, key: messageId), !message.isRetracted else { return nil }
            if let actionId { message.actionPendingId = actionId; message.actionError = nil }
            return try Self.retract(db, &message)
        }
    }

    /// A moderator's retraction (XEP-0425) of the room's message `target`,
    /// which is its stanza-id. Whoever wrote it, ours included; the caller
    /// has made sure the room itself said so. Returns its file to delete.
    public func applyModeratedRetraction(in room: JID, target: String) throws -> Attachment? {
        try writer.write { db in
            guard let conversationId = try Self.conversationId(db, peer: room),
                  var message = try Message.filter(Column("conversationId") == conversationId && Column("serverId") == target && Column("isRetracted") == false).fetchOne(db)
            else { return nil }
            message.actionPendingId = nil
            return try Self.retract(db, &message, moderated: true)
        }
    }
}

extension AppDatabase {
    /// Another of our devices read the chat with `peer` up to the message
    /// the server or room numbered `stanzaId` (XEP-0490). Read state only
    /// moves forward; a message we don't have is ignored.
    @discardableResult
    public func applyDisplayed(peer: JID, stanzaId: String) throws -> Bool {
        try writer.write { try Self.applyDisplayed($0, peer: peer, stanzaId: stanzaId) }
    }

    private static func applyDisplayed(_ db: Database, peer: JID, stanzaId: String) throws -> Bool {
        guard let id = try Self.conversationId(db, peer: peer),
              let message = try Message.filter(Column("conversationId") == id && Column("serverId") == stanzaId).fetchOne(db) else { return false }
        try markRead(db, conversationId: id, through: message.timestamp)
        return true
    }

    /// `applyDisplayed` for many chats in one transaction, so a catch-up over
    /// every chat writes once. Returns the peers whose message we had.
    public func applyDisplayed(_ states: [(peer: JID, stanzaId: String)]) throws -> Set<JID> {
        guard !states.isEmpty else { return [] }
        return try writer.write { db in
            var applied = Set<JID>()
            for (peer, stanzaId) in states where try Self.applyDisplayed(db, peer: peer, stanzaId: stanzaId) { applied.insert(peer) }
            return applied
        }
    }
}
