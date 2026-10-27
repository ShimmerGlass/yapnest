import Foundation
import GRDB

extension AppDatabase {
    public func attachment(messageId: Int64) throws -> Attachment? {
        try reader.read { db in try Attachment.fetchOne(db, key: messageId) }
    }

    static func attachments(_ db: Database, messageIds: some Collection<Int64>) throws -> [Int64: Attachment] {
        guard !messageIds.isEmpty else { return [:] }
        return Dictionary(
            try Attachment.filter(messageIds.contains(Column("messageId"))).fetchAll(db).map { ($0.messageId, $0) },
            uniquingKeysWith: { a, _ in a },
        )
    }

    /// Stores an outgoing message with its not-yet-uploaded file.
    func insert(_ message: Message, attachment: Attachment) throws -> (Message, Attachment) {
        try writer.write { db in
            let (stored, _) = try Self.insert(db, message)
            var attachment = attachment
            attachment.messageId = stored.id!
            try attachment.insert(db)
            return (stored, attachment)
        }
    }

    /// Records where our upload went; the message's body becomes its URL,
    /// which is what goes on the wire.
    func setUploaded(messageId: Int64, url: String) throws -> Message? {
        try writer.write { db in
            guard var attachment = try Attachment.fetchOne(db, key: messageId),
                  var message = try Message.fetchOne(db, key: messageId) else { return nil }
            attachment.url = url
            attachment.state = .ready
            try attachment.update(db)
            message.body = url
            try message.update(db)
            return message
        }
    }

    /// `duration` is what measuring a sound gave; a file that can't be
    /// measured keeps the length its sender announced.
    func setDownloaded(messageId: Int64, localFile: String, size: Int64, mimeType: String?, width: Int?, height: Int?, duration: TimeInterval? = nil) throws {
        try writer.write { db in
            guard var attachment = try Attachment.fetchOne(db, key: messageId) else { return }
            attachment.localFile = localFile
            attachment.size = size
            attachment.mimeType = attachment.mimeType ?? mimeType
            // A file that can't be measured must not erase a size we already
            // know, so the bubble doesn't change shape.
            if let width, let height {
                attachment.width = Double(width)
                attachment.height = Double(height)
            }
            if let duration { attachment.duration = duration }
            attachment.thumbnail = nil
            attachment.state = .ready
            try attachment.update(db)
        }
    }

    func setAttachmentState(_ state: Attachment.State, messageId: Int64) throws {
        try writer.write { db in
            guard var attachment = try Attachment.fetchOne(db, key: messageId) else { return }
            attachment.state = state
            try attachment.update(db)
        }
    }

    /// Records that a download stopped for being over its limit. That isn't
    /// a failure: the file is there to fetch by hand, and its size is worth
    /// showing.
    func setTooLarge(messageId: Int64, size: Int64?) throws {
        try writer.write { db in
            guard var attachment = try Attachment.fetchOne(db, key: messageId) else { return }
            if let size { attachment.size = size }
            attachment.state = .remote
            try attachment.update(db)
        }
    }

    /// Received images that should have downloaded on their own but haven't,
    /// newest first: still remote, or failed (but not for being too big),
    /// from someone `XMPPSession.trustsForAutoDownload` allows. Only recent
    /// ones, so a sweep doesn't pull years of history. `peer` narrows it to
    /// one conversation.
    func missedImages(since: Date, limit: Int, maxSize: Int64, peer: JID? = nil) throws -> [Attachment] {
        try reader.read { db in
            let trustsGroupMembers = try Self.flag(db, .downloadsFromGroupMembers, default: true)
            let rows = try Row.fetchCursor(db, sql: """
                SELECT attachment.*, message.direction = 'outgoing' AS isOutgoing, message.isWrittenHere AS isWrittenHere,
                       conversation.kind = 'groupchat' AS isGroup,
                       COALESCE(groupChat.isMembersOnly AND groupChat.isNonAnonymous, 0) AS isPrivateGroup,
                       COALESCE(contact.isAddedByUser OR contact.isSubscriptionPending OR contact.subscription IN ('to', 'from', 'both'), 0) AS hasConsent
                FROM attachment
                JOIN message ON message.id = attachment.messageId
                JOIN conversation ON conversation.id = message.conversationId
                LEFT JOIN groupChat ON groupChat.conversationId = conversation.id
                LEFT JOIN contact ON contact.jid = CASE conversation.kind WHEN 'chat' THEN conversation.peer ELSE message.sender END
                WHERE attachment.state IN ('remote', 'downloadFailed') AND attachment.url IS NOT NULL
                  AND (attachment.size IS NULL OR attachment.size <= ?)
                  AND message.timestamp >= ? AND NOT message.isRetracted
                  AND (? IS NULL OR conversation.peer = ?)
                ORDER BY message.timestamp DESC
                """, arguments: [maxSize, since, peer, peer])
            var found: [Attachment] = []
            while found.count < limit, let row = try rows.next() {
                let attachment = try Attachment(row: row)
                guard attachment.isImage, XMPPSession.trustsForAutoDownload(
                    isOutgoing: Message.isTrustedOutgoing(isOutgoing: row["isOutgoing"], isWrittenHere: row["isWrittenHere"], inGroup: row["isGroup"]),
                    isPrivateGroup: row["isGroup"] && row["isPrivateGroup"], trustsGroupMembers: trustsGroupMembers, isTrusted: row["hasConsent"],
                ) else { continue }
                found.append(attachment)
            }
            return found
        }
    }
}

/// What a `<file-sharing>` announcement said, kept until the message with the
/// file's link arrives (XEP-0447 allows it to follow, and Dino always sends it
/// that way).
private struct FileAnnouncement: Codable, FetchableRecord, PersistableRecord {
    var key: String
    var receivedAt: Date
    var mediaType: String?
    var size: Int64?
    var width: Int?
    var height: Int?
    var length: Double?
    var thumbnail: Data?

    static let databaseTableName = "fileAnnouncement"
    /// An announcement waits this long for its link...
    static let lifetime: TimeInterval = 24 * 60 * 60
    /// ...and no more than this many wait at once, as anyone can send them.
    static let limit = 100
}

extension AppDatabase {
    static func keepAnnouncement(_ db: Database, key: String, _ metadata: FileMetadata, now: Date = Date()) throws {
        try FileAnnouncement(
            key: key, receivedAt: now, mediaType: metadata.mediaType, size: metadata.size,
            width: metadata.width, height: metadata.height, length: metadata.length, thumbnail: metadata.thumbnail,
        ).save(db)
        try FileAnnouncement.filter(Column("receivedAt") < now.addingTimeInterval(-FileAnnouncement.lifetime)).deleteAll(db)
        try db.execute(sql: """
            DELETE FROM fileAnnouncement WHERE key NOT IN (SELECT key FROM fileAnnouncement ORDER BY receivedAt DESC LIMIT ?)
            """, arguments: [FileAnnouncement.limit])
    }

    /// The announcement under `key`, which is used up.
    static func takeAnnouncement(_ db: Database, key: String) throws -> FileMetadata? {
        guard let found = try FileAnnouncement.fetchOne(db, key: key) else { return nil }
        try found.delete(db)
        return FileMetadata(mediaType: found.mediaType, size: found.size, width: found.width, height: found.height, length: found.length, thumbnail: found.thumbnail)
    }
}
