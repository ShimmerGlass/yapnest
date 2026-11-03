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
    var hasher = FileHasher()

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
        var facts: OutgoingFileFacts?
    }

    /// Takes the file into the store. Photos are scaled down and stripped of
    /// metadata, unless animated; other files go as they are. The stored file
    /// is final from here, so its hash and thumbnail are worked out now, once.
    func prepareFile(at url: URL, name: String? = nil, asPhoto: Bool = false) async throws -> PreparedFile {
        let imported = try await attachments.importFile(at: url, name: name ?? url.lastPathComponent, asPhoto: asPhoto)
        // Only pictures and sounds are described to the recipient, so only
        // they are hashed now; any other file is hashed when something first
        // needs it (a Jingle offer), and kept then. A file that can't be read
        // back is left for the first send to fail on.
        let mimeType = AttachmentStore.mimeType(for: imported.name)
        let facts = Attachment.isDescribedWhenSent(name: imported.name, mimeType: mimeType) ? try? OutgoingFileFacts.read(
            fileAt: attachments.directory.appending(path: imported.file), isImage: Attachment.isImage(name: imported.name, mimeType: mimeType), with: hasher,
        ) : nil
        return PreparedFile(imported: imported, facts: facts)
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
                        sha256: file.facts?.sha256,
                        ownThumbnail: file.facts?.thumbnail,
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
