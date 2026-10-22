import Foundation
import GRDB
import Martin

/// Stores outgoing messages as pending, without a connection. The session
/// sends from it, and so does the share extension, which writes its messages
/// before it knows whether it can get the session: whatever happens next, the
/// app finds them and sends them.
struct OutgoingMessages: Sendable {
    let database: AppDatabase
    let attachments: AttachmentStore
    let account: JID

    struct Reply: Sendable {
        var id: String
        var sender: JID
    }

    enum Item: Sendable {
        case text(String, reply: Reply? = nil)
        case file(PreparedFile)
    }

    /// A file already in the attachment store.
    struct PreparedFile: Sendable {
        var imported: AttachmentStore.Imported
    }

    /// Takes the file into the store. Photos are scaled down and stripped of
    /// metadata, unless animated; other files go as they are.
    func prepareFile(at url: URL, name: String? = nil, asPhoto: Bool = false) async throws -> PreparedFile {
        PreparedFile(imported: try await attachments.importFile(at: url, name: name ?? url.lastPathComponent, asPhoto: asPhoto))
    }

    /// Forgets files that were prepared but never made it into a message.
    func discard(_ files: [PreparedFile]) {
        for file in files {
            try? FileManager.default.removeItem(at: attachments.directory.appending(path: file.imported.file))
        }
    }

    /// Inserts `items` as pending messages to `peer`, in order, all or none.
    func stage(_ items: [Item], to peer: JID) throws -> [Message] {
        try database.writer.write { db in
            let conversation = try AppDatabase.conversation(db, with: peer)
            let nick = try GroupChat.filter(Column("jid") == peer).fetchOne(db)?.nickname
            var stored: [Message] = []
            for item in items {
                let id = OutboundStanza.newId()
                var message = Message(
                    conversationId: conversation.id!,
                    direction: .outgoing,
                    sender: account,
                    nick: nick,
                    body: "",
                    encryption: conversation.isEncrypted ? .omemo : .none,
                    remoteId: id,
                    originId: id,
                )
                message.isWrittenHere = true
                switch item {
                case .text(let text, let reply):
                    // Stored without what XML forbids, so the body, the offsets computed on it and the wire agree.
                    message.setBody(EscapeUtils.removingForbidden(text))
                    message.replyToId = reply?.id
                    message.replyToSender = reply?.sender
                    stored.append(try AppDatabase.insert(db, message).message)
                case .file(let file):
                    let imported = file.imported
                    message.link = nil
                    let inserted = try AppDatabase.insert(db, message).message
                    let attachment = Attachment(
                        messageId: inserted.id!,
                        url: nil,
                        name: imported.name,
                        mimeType: AttachmentStore.mimeType(for: imported.name),
                        size: imported.size,
                        width: imported.width.map(Double.init),
                        height: imported.height.map(Double.init),
                        duration: imported.duration,
                        localFile: imported.file,
                        state: .pendingUpload,
                    )
                    try attachment.insert(db)
                    stored.append(inserted)
                }
            }
            return stored
        }
    }
}
