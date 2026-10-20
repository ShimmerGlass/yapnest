import Foundation
import GRDB

extension AppDatabase {
    /// Stores a contact's Jingle file offer (XEP-0234) as an incoming message
    /// with its file, in one transaction so that a notification built from
    /// the message already finds the file's name. `remoteId` is the Jingle
    /// session id, as it is for a call. Nil if the offer was stored before.
    func insertFileOffer(from peer: JID, sid: String, offer: JingleFileOffer, now: Date = Date()) throws -> Message? {
        try writer.write { db in
            let conversation = try Self.conversation(db, with: peer)
            var message = Message(
                conversationId: conversation.id!, direction: .incoming, sender: peer, body: "",
                timestamp: now, status: .received, remoteId: sid,
            )
            message.link = nil
            let (stored, inserted) = try Self.insert(db, message)
            guard inserted, let id = stored.id else { return nil }
            try Attachment(
                messageId: id, url: nil, name: offer.name,
                mimeType: offer.mediaType ?? AttachmentStore.mimeType(for: offer.name),
                size: offer.size, state: .offered,
            ).insert(db)
            return stored
        }
    }

    /// Offers don't survive the session that took them, so those still
    /// waiting or coming in have ended.
    func expireFileOffers() throws {
        try writer.write { db in
            try Attachment.filter(Column("state") == Attachment.State.offered)
                .updateAll(db, Column("state").set(to: Attachment.State.unavailable))
        }
    }

    /// Ends an offer that didn't bring its file. Only one still waiting or
    /// coming in is changed, so a late failure can't undo a file that arrived.
    func setOfferUnavailable(messageId: Int64) throws {
        try writer.write { db in
            try Attachment.filter(Column("messageId") == messageId && Column("state") == Attachment.State.offered)
                .updateAll(db, Column("state").set(to: Attachment.State.unavailable))
        }
    }

    /// Our file went to the contact over Jingle: there is no message stanza
    /// to send, so the message is as good as delivered.
    func setFileSentOverJingle(messageId: Int64) throws {
        try writer.write { db in
            guard var attachment = try Attachment.fetchOne(db, key: messageId),
                  var message = try Message.fetchOne(db, key: messageId) else { return }
            attachment.state = .ready
            try attachment.update(db)
            message.status = max(message.status, .delivered)
            message.error = nil
            try message.update(db)
        }
    }
}
