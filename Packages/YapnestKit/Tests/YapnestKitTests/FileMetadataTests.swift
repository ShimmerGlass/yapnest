import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO
@preconcurrency import Martin
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// A 4x2 PNG, as Dino sends: at most 8 pixels on a side.
private let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEElEQVR4nGM4EaABRwzIHACHGgoBR/08xAAAAABJRU5ErkJggg=="

private func parse(_ xml: String) throws -> InboundMessage {
    try #require(InboundMessage(parseStanza(xml) as Martin.Message, account: me, source: .live))
}

/// What Dino sends before the upload: no body, the file's metadata, no sources
/// (libdino `file_sender.vala` and `sfs_metadata.vala`).
private func dinoAnnouncement(id: String = "m1", sharingId: String = "sfs-1", from sender: String = "alice@example.org/dino") -> String {
    """
    <message from='\(sender)' to='me@example.org/yapnest' type='chat' id='\(id)'>
      <file-sharing xmlns='urn:xmpp:sfs:0' id='\(sharingId)'>
        <file xmlns='urn:xmpp:file:metadata:0'>
          <name>cat.png</name>
          <media_type>image/png</media_type>
          <media-type>image/png</media-type>
          <size>48210</size>
          <date>2026-10-10T12:00:00Z</date>
          <width>1200</width>
          <height>800</height>
          <hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>2XarmwTlNxDAMkvymloX3S5+VbylNrJt/l5QyPa+YoU=</hash>
          <thumbnail xmlns='urn:xmpp:thumbs:1' uri='data:image/png;base64,\(tinyPNG)' media-type='image/png' width='4' height='2'/>
        </file>
      </file-sharing>
      <store xmlns='urn:xmpp:hints'/>
    </message>
    """
}

/// What Dino sends once the upload is done: the link, repeated as XEP-0066,
/// with the sources attached to the announcement.
private func dinoSources(id: String = "m2", sharingId: String = "sfs-1", from sender: String = "alice@example.org/dino", name: String = "cat.png") -> String {
    """
    <message from='\(sender)' to='me@example.org/yapnest' type='chat' id='\(id)'>
      <body>https://up.example/x/\(name)</body>
      <x xmlns='jabber:x:oob'><url>https://up.example/x/\(name)</url></x>
      <attach-to xmlns='urn:xmpp:message-attaching:1' id='m1'/>
      <sources xmlns='urn:xmpp:sfs:0' id='\(sharingId)'>
        <url-data xmlns='http://jabber.org/protocol/url-data' target='https://up.example/x/\(name)'/>
      </sources>
    </message>
    """
}

struct FileMetadataParsingTests {
    @Test func dinoAnnouncementCarriesMetadataAndNoBody() throws {
        let inbound = try parse(dinoAnnouncement())
        #expect(inbound.body == nil)
        #expect(inbound.fileSharingId == "sfs-1")
        let metadata = try #require(inbound.fileMetadata)
        #expect(metadata.mediaType == "image/png")
        #expect(metadata.size == 48210)
        #expect((metadata.width, metadata.height) == (1200, 800))
        #expect(metadata.thumbnail != nil)
    }

    @Test func dinoSourcesNameTheirAnnouncement() throws {
        let inbound = try parse(dinoSources())
        #expect(inbound.sourcesId == "sfs-1")
        #expect(inbound.fileMetadata == nil)
        #expect(inbound.body == "https://up.example/x/cat.png")
        #expect(inbound.oobURL == "https://up.example/x/cat.png")
    }

    @Test func legacyMediaTypeIsRead() throws {
        let inbound = try parse("""
            <message from='alice@example.org/dino' type='chat'><file-sharing xmlns='urn:xmpp:sfs:0'>
              <file xmlns='urn:xmpp:file:metadata:0'><media_type>image/jpeg</media_type></file></file-sharing></message>
            """)
        #expect(inbound.fileMetadata?.mediaType == "image/jpeg")
    }

    @Test func specExampleWithCidThumbnailKeepsNoThumbnail() throws {
        // XEP-0447 example 1. The `cid:` thumbnail would need a request to be shown.
        let inbound = try parse("""
            <message from='alice@example.org/r' id='sharing-a-file'>
              <file-sharing xmlns='urn:xmpp:sfs:0' disposition='inline'>
                <file xmlns='urn:xmpp:file:metadata:0'>
                  <media-type>image/jpeg</media-type><name>summit.jpg</name><size>3032449</size>
                  <width>4096</width><height>2160</height>
                  <hash xmlns='urn:xmpp:hashes:2' algo='sha3-256'>2XarmwTlNxDAMkvymloX3S5+VbylNrJt/l5QyPa+YoU=</hash>
                  <desc>Photo from the summit.</desc>
                  <thumbnail xmlns='urn:xmpp:thumbs:1' uri='cid:sha1+ffd7c8d28e9c5e82afea41f97108c6b4@bob.xmpp.org' media-type='image/png' width='128' height='96'/>
                </file>
                <sources>
                  <url-data xmlns='http://jabber.org/protocol/url-data' target='https://download.montague.lit/4a771ac1/summit.jpg'/>
                </sources>
              </file-sharing>
            </message>
            """)
        let metadata = try #require(inbound.fileMetadata)
        #expect((metadata.width, metadata.height) == (4096, 2160))
        #expect(metadata.thumbnail == nil)
    }

    @Test func conversationsStyleLinkHasNoMetadata() throws {
        // Conversations, Monal and Gajim send the link and the XEP-0066 element only.
        let inbound = try parse("""
            <message from='alice@example.org/phone' type='chat' id='c1'>
              <body>https://up.example/x/cat.png</body>
              <x xmlns='jabber:x:oob'><url>https://up.example/x/cat.png</url></x>
            </message>
            """)
        #expect(inbound.fileMetadata == nil)
        #expect(inbound.fileSharingId == nil)
        #expect(inbound.sourcesId == nil)
    }

    @Test(arguments: [
        ("0", "10"), ("10", "0"), ("-4", "10"), ("20000", "10"), ("10", "99999999999999999999"), ("abc", "10"),
    ])
    func implausibleDimensionsAreDropped(width: String, height: String) throws {
        let inbound = try parse("""
            <message from='alice@example.org/r' type='chat'><file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'>
              <width>\(width)</width><height>\(height)</height><size>-5</size></file></file-sharing></message>
            """)
        let metadata = try #require(inbound.fileMetadata)
        #expect(metadata.width == nil && metadata.height == nil)
        #expect(metadata.size == nil)
    }

    @Test func oneSideAloneIsNoShape() throws {
        let inbound = try parse("""
            <message from='alice@example.org/r' type='chat'><file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'>
              <width>100</width></file></file-sharing></message>
            """)
        #expect(inbound.fileMetadata?.width == nil)
    }

    @Test func thumbnailsMustBeSmallDataImages() throws {
        func thumbnail(_ uri: String) -> Data? {
            FileMetadata.thumbnail(fromDataURI: uri)
        }
        #expect(thumbnail("data:image/png;base64,\(tinyPNG)") != nil)
        // Not a data URI: fetching it would tell the sender when we looked.
        #expect(thumbnail("https://example.org/t.png") == nil)
        #expect(thumbnail("cid:sha1+ab@bob.xmpp.org") == nil)
        // Not an image, not base64, not valid base64, not a picture.
        #expect(thumbnail("data:text/html;base64,\(tinyPNG)") == nil)
        #expect(thumbnail("data:image/png,\(tinyPNG)") == nil)
        #expect(thumbnail("data:image/png;base64,!!!not base64!!!") == nil)
        #expect(thumbnail("data:image/png;base64," + Data("hello".utf8).base64EncodedString()) == nil)
        // Over the size cap, as sent...
        let huge = Data(repeating: 0x41, count: FileMetadata.maxThumbnailBytes + 1).base64EncodedString()
        #expect(thumbnail("data:image/png;base64,\(huge)") == nil)
        // ...and a small file that claims a big canvas is not decoded.
        let claiming = AvatarImages.pngClaiming(side: 300).base64EncodedString()
        #expect(thumbnail("data:image/png;base64,\(claiming)") == nil)
        let real = try AvatarImages.png(side: 300).base64EncodedString()
        #expect(thumbnail("data:image/png;base64,\(real)") == nil)
    }

    @Test func storedThumbnailIsASmallPNG() throws {
        let data = try #require(FileMetadata.thumbnail(fromDataURI: "data:image/png;base64,\(try AvatarImages.png(side: 200).base64EncodedString())"))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 32)
    }
}

struct FileMetadataIngestTests {
    private func attachment(afterIngesting xmls: [String], into db: AppDatabase) throws -> YapnestKit.Attachment? {
        var last: IngestResult?
        for xml in xmls { last = try db.ingest(try parse(xml)) }
        return last?.newAttachment
    }

    @Test func announcementReachesTheLinksMessage() throws {
        let db = try AppDatabase.inMemory()
        let file = try #require(try attachment(afterIngesting: [dinoAnnouncement(), dinoSources()], into: db))
        #expect((file.width, file.height) == (1200, 800))
        #expect(file.size == 48210)
        #expect(file.thumbnail != nil)
        #expect(file.state == .remote)
        // The announcement made no message of its own.
        let messages = try db.reader.read { try Message.fetchCount($0) }
        #expect(messages == 1)
        // The stored row has it too.
        #expect(try db.attachment(messageId: file.messageId)?.imageSize == CGSize(width: 1200, height: 800))
    }

    @Test func announcementIsUsedOnce() throws {
        let db = try AppDatabase.inMemory()
        _ = try attachment(afterIngesting: [dinoAnnouncement(), dinoSources()], into: db)
        let again = try attachment(afterIngesting: [dinoSources(id: "m3", name: "dog.png")], into: db)
        #expect(again?.width == nil)
    }

    @Test func announcementOfSomeoneElseIsNotApplied() throws {
        let db = try AppDatabase.inMemory()
        let other = "mallory@example.org/x"
        _ = try db.ingest(try parse(dinoAnnouncement(from: other)))
        let file = try attachment(afterIngesting: [dinoSources()], into: db)
        #expect(file?.width == nil && file?.thumbnail == nil)
    }

    @Test func announcementWithAnotherIdIsNotApplied() throws {
        let db = try AppDatabase.inMemory()
        let file = try attachment(afterIngesting: [dinoAnnouncement(sharingId: "sfs-1"), dinoSources(sharingId: "sfs-2")], into: db)
        #expect(file?.width == nil)
    }

    @Test func sourcesWithoutAnnouncementAreAPlainFile() throws {
        let db = try AppDatabase.inMemory()
        let file = try #require(try attachment(afterIngesting: [dinoSources()], into: db))
        #expect(file.name == "cat.png")
        #expect(file.width == nil && file.thumbnail == nil && file.size == nil)
    }

    @Test func announcementsAreLimitedAndExpire() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            let now = Date()
            let limit = 100
            for index in 0..<(limit + 20) {
                try AppDatabase.keepAnnouncement(db, key: "k\(index)", FileMetadata(width: 1, height: 1), now: now.addingTimeInterval(Double(index)))
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fileAnnouncement") == limit)
            // The newest are the ones kept.
            #expect(try AppDatabase.takeAnnouncement(db, key: "k0") == nil)
            #expect(try AppDatabase.takeAnnouncement(db, key: "k\(limit + 19)") != nil)
            // A day later, whatever is left has expired.
            try AppDatabase.keepAnnouncement(db, key: "fresh", FileMetadata(width: 1, height: 1), now: now.addingTimeInterval(3 * 24 * 60 * 60))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fileAnnouncement") == 1)
        }
    }

    @Test func metadataInTheMessageItselfIsApplied() throws {
        let db = try AppDatabase.inMemory()
        let stanza = """
            <message from='alice@example.org/r' type='chat' id='x1'>
              <body>https://up.example/x/cat.jpg</body>
              <x xmlns='jabber:x:oob'><url>https://up.example/x/cat.jpg</url></x>
              <file-sharing xmlns='urn:xmpp:sfs:0' disposition='inline'>
                <file xmlns='urn:xmpp:file:metadata:0'><media-type>image/jpeg</media-type><width>640</width><height>480</height></file>
                <sources><url-data xmlns='http://jabber.org/protocol/url-data' target='https://up.example/x/cat.jpg'/></sources>
              </file-sharing>
            </message>
            """
        let file = try #require(try attachment(afterIngesting: [stanza], into: db))
        #expect((file.width, file.height) == (640, 480))
    }

    @Test func encryptedMessageIgnoresPlaintextMetadata() throws {
        // The element sits outside the OMEMO payload, so a server could have put it there.
        let stanza = """
            <message from='alice@example.org/r' type='chat' id='x2'>
              <body>https://up.example/x/cat.jpg</body>
              <file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'><width>640</width><height>480</height><size>9</size></file></file-sharing>
              <sources xmlns='urn:xmpp:sfs:0' id='sfs-1'/>
            </message>
            """
        let inbound = try #require(InboundMessage(parseStanza(stanza) as Martin.Message, account: me, source: .live, encryption: .omemo))
        #expect(inbound.fileMetadata == nil && inbound.sourcesId == nil && inbound.fileSharingId == nil)
        let db = try AppDatabase.inMemory()
        _ = try db.ingest(try parse(dinoAnnouncement()))
        let encrypted = try #require(InboundMessage(parseStanza(dinoSources(name: "cat.jpg")) as Martin.Message, account: me, source: .live, encryption: .omemo))
        let file = try #require(try db.ingest(encrypted).newAttachment)
        #expect(file.width == nil && file.thumbnail == nil && file.size == nil)
    }

    @Test func claimedImageDoesNotMakeAFileOne() throws {
        let db = try AppDatabase.inMemory()
        let stanza = """
            <message from='alice@example.org/r' type='chat' id='x1'>
              <body>https://up.example/x/report.pdf</body>
              <x xmlns='jabber:x:oob'><url>https://up.example/x/report.pdf</url></x>
              <file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'>
                <media-type>image/png</media-type><size>1000</size><width>640</width><height>480</height></file></file-sharing>
            </message>
            """
        let file = try #require(try attachment(afterIngesting: [stanza], into: db))
        #expect(file.isImage == false)
        // The size is worth showing for any file; the shape is for pictures.
        #expect(file.size == 1000)
        #expect(file.width == nil && file.thumbnail == nil)
    }

    @Test func claimedNonImageTypeDropsTheShape() throws {
        let db = try AppDatabase.inMemory()
        let stanza = """
            <message from='alice@example.org/r' type='chat' id='x1'>
              <body>https://up.example/x/cat.png</body>
              <x xmlns='jabber:x:oob'><url>https://up.example/x/cat.png</url></x>
              <file-sharing xmlns='urn:xmpp:sfs:0'><file xmlns='urn:xmpp:file:metadata:0'>
                <media-type>application/pdf</media-type><width>640</width><height>480</height></file></file-sharing>
            </message>
            """
        let file = try #require(try attachment(afterIngesting: [stanza], into: db))
        #expect(file.width == nil)
    }

    @Test func downloadDropsTheThumbnailAndKeepsTheShape() throws {
        let db = try AppDatabase.inMemory()
        let file = try #require(try attachment(afterIngesting: [dinoAnnouncement(), dinoSources()], into: db))
        try db.setDownloaded(messageId: file.messageId, localFile: "a.png", size: 100, mimeType: nil, width: nil, height: nil)
        let stored = try #require(try db.attachment(messageId: file.messageId))
        #expect(stored.thumbnail == nil)
        #expect((stored.width, stored.height) == (1200, 800))
        #expect(stored.state == .ready)
    }

    @Test func migrationKeepsAttachments() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v22-roster-groups")
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "INSERT INTO attachment (messageId, url, name, width, height, state) VALUES (7, 'https://up.example/a.png', 'a.png', 640, 480, 'remote')")
        }
        let before = try queue.read { db in try db.columns(in: "attachment").map(\.name) }
        #expect(!before.contains("thumbnail"))
        try AppDatabase.migrator.migrate(queue)
        let (after, kept, announcements) = try queue.read { db in
            (try db.columns(in: "attachment").map(\.name), try YapnestKit.Attachment.fetchOne(db, key: 7), try db.tableExists("fileAnnouncement"))
        }
        #expect(after.contains("thumbnail"))
        #expect(announcements)
        #expect(kept?.width == 640)
        #expect(kept?.thumbnail == nil)
    }
}

struct FileMetadataSendingTests {
    private func wire(_ message: Martin.Message) -> String { message.element.stringValue }

    private func store(with image: Data, named name: String) throws -> (AttachmentStore, YapnestKit.Attachment) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "meta-\(UUID().uuidString)")
        let store = AttachmentStore(directory: directory)
        let file = try store.save(image, name: name)
        let attachment = YapnestKit.Attachment(
            messageId: 1, url: "https://up.example/x/\(name)", name: name, mimeType: "image/png", size: Int64(image.count),
            width: 40, height: 20, localFile: file, state: .ready,
        )
        return (store, attachment)
    }

    @Test func outgoingMetadataDescribesThePicture() throws {
        let png = try AvatarImages.png(side: 120)
        let (store, attachment) = try store(with: png, named: "cat.png")
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let metadata = try #require(FileMetadata.outgoing(for: attachment, in: store))
        #expect(metadata.size == Int64(png.count))
        #expect((metadata.width, metadata.height) == (40, 20))
        #expect(metadata.sha256 == Data(SHA256.hash(data: png)))
        let thumbnail = try #require(metadata.thumbnail)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 16)
        // Not a picture: nothing to say.
        var pdf = attachment
        pdf.name = "a.pdf"
        pdf.mimeType = "application/pdf"
        #expect(FileMetadata.outgoing(for: pdf, in: store) == nil)
    }

    @Test func unencryptedFileCarriesMetadataAndTheLink() throws {
        let png = try AvatarImages.png(side: 120)
        let (store, attachment) = try store(with: png, named: "cat.png")
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let url = "https://up.example/x/cat.png"
        let stanza = OutboundStanza.text(url, to: .direct(alice), id: "m1")
        OutboundStanza.addFile(url: url, metadata: FileMetadata.outgoing(for: attachment, in: store), encrypted: false, to: stanza)

        // The link is still where clients that know nothing else look.
        let text = wire(stanza)
        #expect(text.contains("jabber:x:oob"))
        #expect(stanza.body == url)
        // What a receiver makes of it.
        stanza.from = Martin.JID(me.martin)
        let inbound = try parse(text)
        #expect(inbound.oobURL == url)
        let metadata = try #require(inbound.fileMetadata)
        #expect((metadata.width, metadata.height) == (40, 20))
        #expect(metadata.thumbnail != nil)
        #expect(metadata.size == Int64(png.count))
        // Dino ignores a file-sharing without a supported hash.
        #expect(text.contains("urn:xmpp:hashes:2"))
        #expect(text.contains("sha-256"))
    }

    @Test func encryptedFileCarriesNoMetadataNorLink() throws {
        let png = try AvatarImages.png(side: 120)
        let (store, attachment) = try store(with: png, named: "cat.png")
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let url = "aesgcm://up.example/x/cat.png#0123"
        let stanza = OutboundStanza.text(url, to: .direct(alice), id: "m1")
        let before = wire(stanza)
        // Even if metadata is passed, an encrypted chat sends none of it.
        OutboundStanza.addFile(url: url, metadata: FileMetadata.outgoing(for: attachment, in: store), encrypted: true, to: stanza)
        let after = wire(stanza)
        #expect(after == before)
        for forbidden in ["file-sharing", "urn:xmpp:sfs:0", "file:metadata", "thumbs", "thumbnail", "hashes", "url-data", "oob", "width", "height", "media-type"] {
            #expect(!after.contains(forbidden), "\(forbidden)")
        }
    }
}
