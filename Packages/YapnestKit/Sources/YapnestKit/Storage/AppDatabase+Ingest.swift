import Foundation
import GRDB

/// What happened when an inbound stanza was applied, for the caller to act on
/// (notifications, receipts, typing indicators).
public struct IngestResult: Sendable, Equatable {
    /// A message stored for the first time.
    public var newMessage: Message?
    /// The file the new message carries, not downloaded yet.
    public var newAttachment: Attachment?
    /// A message we hold that an incoming correction just changed, so that a
    /// notification still showing its old text can be replaced.
    public var editedMessage: Message?
    public var conversationId: Int64?
    /// The peer's typing state, if the stanza carried one.
    public var chatState: InboundMessage.ChatState?
    /// The file of a message that was just retracted, to delete.
    public var retractedAttachment: Attachment?

    public static let ignored = IngestResult()
}

extension AppDatabase {
    /// Applies an inbound stanza to the database.
    @discardableResult
    public func ingest(_ inbound: InboundMessage) throws -> IngestResult {
        try writer.write { db in try Self.ingest(db, inbound, allowsInsecureLinks: allowsInsecureLinks) }
    }

    /// Applies several stanzas in one transaction, such as a page of the
    /// archive, so observers redraw once for all of them.
    public func ingest(_ batch: [InboundMessage]) throws -> [IngestResult] {
        guard !batch.isEmpty else { return [] }
        let insecure = allowsInsecureLinks
        return try writer.write { db in try batch.map { try Self.ingest(db, $0, allowsInsecureLinks: insecure) } }
    }

    static func ingest(_ db: Database, _ inbound: InboundMessage, allowsInsecureLinks: Bool = false) throws -> IngestResult {
        var result = IngestResult()
        result.chatState = inbound.isOutgoing ? nil : inbound.chatState

        // Dino announces a file in a message of its own, with no body, and
        // sends the link afterwards. There is nothing to show yet, but the
        // link's message wants what this one said.
        if inbound.body == nil, !inbound.isError, let id = inbound.fileSharingId, let metadata = inbound.fileMetadata {
            try Self.keepAnnouncement(db, key: inbound.announcementKey(forSharingId: id), metadata)
        }

        let hasContent = inbound.body != nil && !inbound.isError
        let conversation: Conversation?
        if hasContent, !inbound.isGroupChat {
            conversation = try Self.conversation(db, with: inbound.peer)
        } else {
            conversation = try Conversation.filter(Column("peer") == inbound.peer).fetchOne(db)
        }
        guard let conversation, let conversationId = conversation.id else { return result }
        result.conversationId = conversationId

        if let subject = inbound.subject {
            try GroupChat.filter(Column("conversationId") == conversationId)
                .updateAll(db, Column("subject").set(to: subject.isEmpty ? nil : subject))
        }

        if inbound.isError {
            if let id = inbound.id {
                try Self.bounceOutgoing(db, conversationId: conversationId, remoteId: id, to: .failed, error: inbound.errorText)
            }
            return result
        }

        let room = conversation.kind == .groupchat ? conversation.peer : nil
        if let target = inbound.retractionOf {
            if var original = try Self.ownedMessage(db, conversationId: conversationId, ref: target, by: inbound.author, outgoing: inbound.isOutgoing, room: room) {
                // Our own change still on its way is moot now.
                original.actionPendingId = nil
                result.retractedAttachment = try Self.retract(db, &original)
            } else if try Self.referencedMessage(db, conversationId: conversationId, id: target) == nil {
                try Self.retractStandIns(db, of: Self.fittingPending(db, .correct, conversationId: conversationId, ref: target, by: inbound.author, outgoing: inbound.isOutgoing, room: room))
                try Self.keepPending(db, .retract, ref: target, inbound, conversationId: conversationId, standInId: nil)
            }
            return result
        }
        if let target = inbound.correctionOf, let body = inbound.body, inbound.encryption != .omemoUndecryptable,
           var original = try Self.ownedMessage(db, conversationId: conversationId, ref: target, by: inbound.author, outgoing: inbound.isOutgoing, room: room) {
            // A correction can't change how a message was protected: a
            // plain one of an encrypted message could come from anyone
            // able to forge the sender, such as a server.
            guard inbound.encryption == original.encryption else { return result }
            if let edited = try Self.applyCorrection(
                db, to: &original, body: body, at: inbound.timestamp, mentionsMe: inbound.mentionsMe,
                quickResponses: inbound.quickResponses, omemoDevice: inbound.omemoDevice, omemoTrust: inbound.omemoTrust,
                outgoing: inbound.isOutgoing,
            ), !inbound.isOutgoing {
                result.editedMessage = edited
            }
            return result
        }
        // Only a correction of a message we never got stands in for it. One of
        // a message we hold but can't apply it to (retracted, someone else's,
        // or not decryptable) must not appear as a message of its own: a
        // replay of it would bring back what was deleted.
        if let target = inbound.correctionOf, try Self.referencedMessage(db, conversationId: conversationId, id: target) != nil {
            return result
        }

        // A second correction of a message we still don't have changes the
        // stand-in of the first, not a message of its own.
        if let target = inbound.correctionOf, let body = inbound.body, inbound.encryption != .omemoUndecryptable,
           try Self.fittingPending(db, .retract, conversationId: conversationId, ref: target, by: inbound.author, outgoing: inbound.isOutgoing, room: room).isEmpty {
            for edit in try Self.fittingPending(db, .correct, conversationId: conversationId, ref: target, by: inbound.author, outgoing: inbound.isOutgoing, room: room)
            where edit.encryption == inbound.encryption {
                if let id = edit.standInId, var standIn = try Message.fetchOne(db, key: id), !standIn.isRetracted {
                    _ = try Self.applyCorrection(
                        db, to: &standIn, body: body, at: inbound.timestamp, mentionsMe: inbound.mentionsMe,
                        quickResponses: inbound.quickResponses, omemoDevice: inbound.omemoDevice, omemoTrust: inbound.omemoTrust,
                        outgoing: inbound.isOutgoing,
                    )
                    return result
                }
            }
        }

        if let body = inbound.body {
            var timestamp = inbound.timestamp
            if inbound.isDelayed, !inbound.isHistory {
                // A delay is the server's word, and a forged one would put the
                // message in old history, unread and unannounced. Real offline
                // messages are stamped after we last looked, so the newest of
                // what's stored and the last notification claim is a floor
                // they never fall under.
                let newest = try Date.fetchOne(db, Message.filter(Column("conversationId") == conversationId).select(max(Column("timestamp"))))
                let claimed = try Self.lastNotifiedAt(db)
                if let floor = [newest, claimed].compactMap({ $0 }).max() { timestamp = max(timestamp, floor) }
            }
            var message = Message(
                conversationId: conversationId,
                direction: inbound.isOutgoing ? .outgoing : .incoming,
                sender: inbound.sender,
                // A room nick is the sender's own claim, like any remote name.
                nick: XMPPSession.normalizedNickname(inbound.nick),
                occupantId: inbound.occupantId,
                body: body,
                timestamp: timestamp,
                status: inbound.isOutgoing ? .sent : .received,
                encryption: inbound.encryption,
                remoteId: inbound.id,
                originId: inbound.originId,
                serverId: inbound.serverId,
                replyToId: inbound.reply?.id,
                replyToSender: inbound.reply?.to.flatMap(JID.init(_:)),
                replyFallback: inbound.reply?.fallback,
                omemoDevice: inbound.omemoDevice,
                omemoTrust: inbound.omemoTrust,
            )
            if inbound.isGroupChat, !inbound.isOutgoing, inbound.sender == inbound.peer, let originId = inbound.originId,
               let ours = try Message.filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.outgoing
                                             && Column("originId") == originId).fetchOne(db) {
                // An archived item with no address is taken as a stranger's, but
                // one that carries the origin-id of a message we sent is our own
                // message coming back, and mustn't be stored a second time.
                message.direction = .outgoing
                message.sender = ours.sender
            }
            // A correction of something we never got stands in for it.
            if inbound.correctionOf != nil { message.editedAt = timestamp }
            message.mentionsMe = inbound.mentionsMe
            message.quickResponses = inbound.quickResponses
            // Read before the user scrolled back to it, or no marker or
            // notification may follow.
            if inbound.isHistory { message.isRead = true }
            message.isMarkable = inbound.isMarkable && !inbound.isOutgoing && !inbound.isGroupChat
            let file = AttachmentLink.parse(body: body, oob: inbound.oobURL, allowsInsecure: allowsInsecureLinks)
            if file != nil { message.link = nil }
            let (insertedMessage, inserted) = try Self.insert(db, message)
            var stored = insertedMessage
            if inserted {
                result.newMessage = stored
                if let file {
                    var attachment = Attachment(
                        messageId: stored.id!,
                        url: file.url.absoluteString,
                        name: file.name,
                        mimeType: AttachmentStore.mimeType(for: file.name),
                        state: .remote,
                    )
                    // Its own metadata, else what the announcement it names said. The
                    // key holds the sender, so only they can have it applied.
                    let announced = try inbound.sourcesId.flatMap { try Self.takeAnnouncement(db, key: inbound.announcementKey(forSharingId: $0)) }
                    if let metadata = inbound.fileMetadata ?? announced { attachment.apply(metadata) }
                    try attachment.insert(db)
                    result.newAttachment = attachment
                }
                if let target = inbound.correctionOf, inbound.encryption != .omemoUndecryptable, let id = stored.id {
                    if try Self.fittingPending(db, .retract, conversationId: conversationId, ref: target, by: inbound.author, outgoing: inbound.isOutgoing, room: room).isEmpty {
                        // A stand-in with a file is never linked: nothing would delete it.
                        if file == nil {
                            try Self.keepPending(db, .correct, ref: target, inbound, conversationId: conversationId, standInId: id)
                        }
                    } else {
                        // Retracted already, so its text never shows. It stays linked,
                        // so the original takes this tombstone with it.
                        try Self.keepPending(db, .correct, ref: target, inbound, conversationId: conversationId, standInId: id)
                        result.retractedAttachment = try Self.retract(db, &stored)
                        result.newMessage = stored
                        result.newAttachment = nil
                    }
                }
                if let applied = try Self.applyPending(db, to: &stored, room: room) {
                    result.newMessage = stored
                    if applied.retracted {
                        result.retractedAttachment = applied.attachment
                        result.newAttachment = nil
                    }
                }
            }
        }

        if let reactions = inbound.reactions {
            try Self.setReactions(db, reactions.emojis, from: inbound.author, conversationId: conversationId, messageRef: reactions.id)
        }

        if inbound.isOutgoing, let action = inbound.actionSelected {
            try Self.markActionChosen(db, action, conversationId: conversationId, through: inbound.timestamp)
        }

        if let id = inbound.receiptFor, !inbound.isOutgoing {
            try Self.updateStatus(db, .delivered, conversationId: conversationId, remoteId: id)
        }

        if let id = inbound.displayedMarkerFor {
            if inbound.isOutgoing {
                // Another of our devices displayed the peer's messages.
                if let target = try Self.referencedMessage(db, conversationId: conversationId, id: id) {
                    try Self.markRead(db, conversationId: conversationId, through: target.timestamp)
                }
            } else if let target = try Self.referencedMessage(db, conversationId: conversationId, id: id, direction: .outgoing) {
                // A marker covers everything up to the message it names.
                try Self.markDisplayed(db, conversationId: conversationId, through: target.timestamp)
            }
        }

        if inbound.isOutgoing, inbound.body != nil {
            // Writing from another device means we've read the conversation.
            try Self.markRead(db, conversationId: conversationId, through: inbound.timestamp)
        }

        return result
    }

    /// Notes that another of our devices chose the action `actionId`, on the
    /// newest offer of it that existed by `date`. Later offers are not its
    /// answer, which matters when the archive replays an old choice. If that
    /// offer already has the choice, as when this device made it, nothing
    /// changes: looking further back would answer an older offer.
    static func markActionChosen(_ db: Database, _ actionId: String, conversationId: Int64, through date: Date) throws {
        let offers = try Message
            .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.incoming)
            .filter(Column("quickResponses") != nil && Column("timestamp") <= date)
            .order(Column("timestamp").desc, Column("id").desc)
            .limit(50)
            .fetchAll(db)
        guard var message = offers.first(where: { $0.quickResponses?.actions.contains { $0.id == actionId } == true }),
              var offer = message.quickResponses, offer.choose(actionId) else { return }
        message.quickResponses = offer
        try message.update(db)
    }

    /// The peer read our messages up to `date` (XEP-0333). A message still
    /// pending hasn't been sent (an upload under way, or queued offline), so
    /// nothing was read of it, and it must stay pending to be sent.
    static func markDisplayed(_ db: Database, conversationId: Int64, through date: Date) throws {
        _ = try Message
            .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.outgoing)
            .filter(Column("timestamp") <= date && Column("isRetracted") == false)
            .filter([Message.Status.sent, .received, .delivered].contains(Column("status")))
            .updateAll(db, Column("status").set(to: Message.Status.displayed))
    }

    /// The message `ref` points at, if `author` wrote it and may still
    /// change it: corrections and retractions only count from the sender
    /// (XEP-0308, XEP-0424). In groups that's the same occupant, by the
    /// room's occupant id where it vouches for them.
    static func ownedMessage(_ db: Database, conversationId: Int64, ref: String, by author: Author, outgoing: Bool, room: JID?) throws -> Message? {
        // Of those that fit, not just the best match: someone who copied the
        // id of a message mustn't shadow its author's own.
        try referencedMessages(db, conversationId: conversationId, id: ref)
            .filter { message in
                !message.isRetracted
                    && (message.direction == .outgoing) == outgoing
                    && (outgoing || message.author.isSame(as: author, room: room))
            }
            .max { $0.referenceRank(for: ref)! < $1.referenceRank(for: ref)! }
    }

    /// Changes `original` to the correcting message's text, unless that is
    /// older than its last change or the message is a file. Returns the
    /// message when it changed.
    static func applyCorrection(
        _ db: Database, to original: inout Message, body: String, at timestamp: Date, mentionsMe: Bool,
        quickResponses: QuickResponses?, omemoDevice: Int32?, omemoTrust: OMEMODevice.Trust?, outgoing: Bool,
    ) throws -> Message? {
        // Archive catch-ups may replay an older correction. A call row's
        // remote id is the call's session id, which a correction can name:
        // it would turn the call into text.
        let isAttachment = try Attachment.filter(Column("messageId") == original.id).isEmpty(db) == false
        guard !isAttachment, original.callOutcome == nil, timestamp >= original.editedAt ?? .distantPast else { return nil }
        original.setBody(body)
        original.editedAt = timestamp
        // The text shown isn't the edit that failed any more. A change still
        // in flight keeps its pending id: it has its own.
        original.actionError = nil
        original.mentionsMe = mentionsMe
        // The offer is the correcting message's, which may make none.
        // Actions already chosen stay chosen if the correction still offers them.
        original.quickResponses = quickResponses.map { offer in
            var offer = offer
            let ids = Set(offer.actions.map(\.id))
            offer.chosen = (original.quickResponses?.chosen ?? []).filter(ids.contains)
            return offer
        }
        // The text now shown is the correcting device's.
        if original.encryption == .omemo, !outgoing {
            original.omemoDevice = omemoDevice
            original.omemoTrust = omemoTrust
        }
        try original.update(db)
        return original
    }

    /// Empties `message` into a tombstone, and returns its file to delete.
    static func retract(_ db: Database, _ message: inout Message, moderated: Bool = false) throws -> Attachment? {
        guard let id = message.id else { return nil }
        let attachment = try Attachment.filter(Column("messageId") == id).fetchOne(db)
        try Attachment.filter(Column("messageId") == id).deleteAll(db)
        try Reaction.filter(Column("messageId") == id).deleteAll(db)
        message.isRetracted = true
        message.actionError = nil
        message.isModerated = moderated
        message.body = ""
        message.link = nil
        message.replyFallback = nil
        message.quickResponses = nil
        message.editedAt = nil
        // Nothing left to read, or to count as unread.
        message.isRead = true
        try message.update(db)
        return attachment
    }
}
