import Foundation
import GRDB

extension AppDatabase {
    /// Keeps the stanza of the placeholder `messageId` until its device is
    /// checked. A second hold for the same message is ignored.
    func hold(messageId: Int64, sender: JID, deviceId: Int32, stanza: String, source: InboundMessage.Source, isHistory: Bool, at: Date = Date()) throws {
        try writer.write { db in
            let held = HeldGroupMessage(messageId: messageId, sender: sender, deviceId: deviceId, stanza: stanza, source: source, isHistory: isHistory, heldAt: at)
            try held.insert(db, onConflict: .ignore)
        }
    }

    /// Every hold, in the order the messages arrived.
    func heldGroupMessages() throws -> [HeldGroupMessage] {
        try reader.read { try HeldGroupMessage.order(Column("id")).fetchAll($0) }
    }

    /// Drops the hold and leaves the placeholder as it is.
    func release(_ held: HeldGroupMessage) throws {
        _ = try writer.write { db in try HeldGroupMessage.deleteOne(db, key: held.id) }
    }

    /// The hold whose placeholder `inbound` is a copy of, in conversation
    /// `conversationId`, found as storing it recognised it.
    func hold(matching inbound: InboundMessage, in conversationId: Int64) throws -> HeldGroupMessage? {
        try reader.read { db in
            // Every decrypted copy asks, and there's almost never a hold.
            guard try HeldGroupMessage.limit(1).fetchOne(db) != nil else { return nil }
            let probe = Message(conversationId: conversationId, direction: .incoming, sender: inbound.sender, body: "",
                                remoteId: inbound.id, originId: inbound.originId, serverId: inbound.serverId)
            guard let placeholder = try Self.duplicate(of: probe, db), let id = placeholder.id else { return nil }
            return try HeldGroupMessage.filter(Column("messageId") == id).fetchOne(db)
        }
    }

    /// Swaps the placeholder for the message it was, as if it had arrived
    /// decrypted. Plain ingest, so the archive cursor doesn't move. Returns
    /// nil when the placeholder is gone or was changed (retracted), in which
    /// case nothing is stored.
    func replace(_ held: HeldGroupMessage, with inbound: InboundMessage) throws -> IngestResult? {
        let insecure = allowsInsecureLinks
        return try writer.write { db in
            defer { _ = try? HeldGroupMessage.deleteOne(db, key: held.id) }
            guard let placeholder = try Message.fetchOne(db, key: held.messageId), placeholder.encryption == .omemoUndecryptable, !placeholder.isRetracted else { return nil }
            let reactions = try Reaction.filter(Column("messageId") == held.messageId).fetchAll(db)
            // Deleted first so that the placeholder isn't taken for a duplicate of the message.
            try placeholder.delete(db)
            // The decrypted message is built outside the room stay the placeholder was stored in, and the message keeps its place in the chat.
            var inbound = inbound
            inbound.timestamp = placeholder.timestamp
            // The placeholder's time already has the floor for delayed messages applied.
            inbound.isDelayed = false
            if let session = placeholder.presenceSession { inbound.presenceSession = session }
            var result = try Self.ingest(db, inbound, allowsInsecureLinks: insecure)
            if let id = result.newMessage?.id {
                for var reaction in reactions {
                    reaction.messageId = id
                    try reaction.insert(db, onConflict: .ignore)
                }
            }
            if placeholder.isRead, var message = result.newMessage {
                message.isRead = true
                try message.update(db)
                result.newMessage = message
            }
            return result
        }
    }
}
