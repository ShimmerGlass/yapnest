import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
@preconcurrency import Martin

/// What a message says about a file before it is downloaded: XEP-0446 file
/// metadata, carried by XEP-0447 `<file-sharing>`, with XEP-0264 thumbnails.
/// Dino sends it (with a thumbnail of at most 8 pixels on a side); Conversations,
/// Monal and Gajim send only the XEP-0066 link, so most files have none.
///
/// Everything here is outside the OMEMO payload, so it travels in the clear:
/// we only ever send it in chats that aren't encrypted. Received, it is the
/// sender's claim, and it's checked before it is kept.
public struct FileMetadata: Sendable, Equatable {
    /// The claimed type, lower-cased.
    public var mediaType: String?
    public var size: Int64?
    public var width: Int?
    public var height: Int?
    /// How long a sound plays, in seconds (XEP-0446 sends milliseconds).
    public var length: TimeInterval?
    /// A small PNG to draw, blurred, until the file is downloaded. Already
    /// checked and re-encoded: see `normalizedThumbnail`.
    public var thumbnail: Data?
    /// Only for sending; a received name is not used, as the link names the file.
    public var name: String?
    /// SHA-256 of the file, only for sending.
    public var sha256: Data?

    public init(mediaType: String? = nil, size: Int64? = nil, width: Int? = nil, height: Int? = nil, length: TimeInterval? = nil, thumbnail: Data? = nil, name: String? = nil, sha256: Data? = nil) {
        self.mediaType = mediaType
        self.size = size
        self.width = width
        self.height = height
        self.length = length
        self.thumbnail = thumbnail
        self.name = name
        self.sha256 = sha256
    }

    /// A side of a claimed picture is believed up to this long.
    static let maxDimension = 16384
    /// A claimed length is believed up to a day.
    static let maxLengthMilliseconds: Int64 = 24 * 60 * 60 * 1000
    /// Thumbnails larger than this, as sent, are ignored.
    static let maxThumbnailBytes = 32 * 1024
    /// A thumbnail claiming more pixels than this on a side is ignored without
    /// being decoded: a small file can declare a huge canvas.
    static let maxThumbnailSide = 256
    /// What we send: larger than the 8 pixels Dino sends.
    static let sentThumbnailSide = 16

    /// Whether the claimed type leaves room for a picture or video.
    var describesMedia: Bool {
        guard let mediaType else { return true }
        return mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/")
    }

    // MARK: Receiving

    /// The metadata of the `<file-sharing>` in `stanza`, if any.
    init?(_ stanza: Martin.Message) {
        guard let sharing = stanza.firstChild(name: "file-sharing", xmlns: NS.sfs),
              let file = sharing.firstChild(name: "file", xmlns: NS.fileMetadata) else { return nil }
        // Dino's older builds wrote `media_type`.
        mediaType = (file.firstChild(name: "media-type")?.value ?? file.firstChild(name: "media_type")?.value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty || $0.count > 127 ? nil : $0 }
        size = file.firstChild(name: "size")?.value.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 >= 0 ? $0 : nil }
        let dimensions = Self.dimensions(width: file.firstChild(name: "width")?.value, height: file.firstChild(name: "height")?.value)
        width = dimensions?.width
        height = dimensions?.height
        length = file.firstChild(name: "length")?.value
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { (1...Self.maxLengthMilliseconds).contains($0) ? TimeInterval($0) / 1000 : nil }
        thumbnail = file.filterChildren(name: "thumbnail", xmlns: NS.thumbnails).lazy
            .compactMap { $0.getAttribute("uri") }
            .compactMap(Self.thumbnail(fromDataURI:))
            .first
    }

    /// Both sides, or nothing: a picture with one side is no use for a shape.
    static func dimensions(width: String?, height: String?) -> (width: Int, height: Int)? {
        guard let width = width.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              let height = height.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              (1...maxDimension).contains(width), (1...maxDimension).contains(height) else { return nil }
        return (width, height)
    }

    /// The picture in a `data:image/...;base64,` URI. A `cid:` or web URI is
    /// not fetched: that would tell the sender when we looked.
    static func thumbnail(fromDataURI uri: String) -> Data? {
        let prefix = "data:image/"
        // Base64 is a third longer than what it holds.
        guard uri.utf8.count <= maxThumbnailBytes * 4 / 3 + 128, uri.prefix(prefix.count).lowercased() == prefix,
              let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[..<comma].lowercased()
        guard header.hasSuffix(";base64"),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters),
              data.count <= maxThumbnailBytes else { return nil }
        return normalizedThumbnail(data)
    }

    /// `data` as a PNG of at most 32 pixels on a side (plenty to blur), if it
    /// is a picture we're willing to decode: of a common type, claiming a
    /// canvas of sensible size. Re-encoding drops everything else the file carried.
    static func normalizedThumbnail(_ data: Data) -> Data? {
        guard data.count <= maxThumbnailBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              [UTType.png, .jpeg, .gif, .webP].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maxThumbnailSide).contains(width), (1...maxThumbnailSide).contains(height) else { return nil }
        return pngThumbnail(of: source, maxSide: 32)
    }

    private static func pngThumbnail(of source: CGImageSource, maxSide: Int) -> Data? {
        source.thumbnail(maxPixelSize: maxSide)?.encoded(as: .png)
    }

    // MARK: Sending

    /// What to tell the recipient of `attachment`, which is a picture or a
    /// sound in the store, from what its row remembers of the file (see
    /// `OutgoingFileFacts`). Nil for anything else, or a row not yet filled in.
    static func outgoing(for attachment: Attachment) -> FileMetadata? {
        guard let hash = attachment.sha256, let size = attachment.size else { return nil }
        if attachment.isAudio {
            return FileMetadata(mediaType: attachment.mimeType, size: size, length: attachment.duration, name: attachment.name, sha256: hash)
        }
        guard attachment.isImage, let width = attachment.imageSize.map({ Int($0.width) }), let height = attachment.imageSize.map({ Int($0.height) }) else { return nil }
        return FileMetadata(
            mediaType: attachment.mimeType, size: size, width: width, height: height,
            thumbnail: attachment.ownThumbnail, name: attachment.name, sha256: hash,
        )
    }

    /// A PNG of the picture at `file`, at most `sentThumbnailSide` on a side.
    static func sentThumbnail(ofFileAt file: URL) -> Data? {
        CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { pngThumbnail(of: $0, maxSide: sentThumbnailSide) }
    }

    /// The `<file-sharing>` element for a file at `url`.
    func sharing(url: String) -> Element {
        let file = Element(name: "file", xmlns: NS.fileMetadata)
        if let mediaType { file.addChild(Element(name: "media-type", cdata: mediaType)) }
        if let name { file.addChild(Element(name: "name", cdata: name)) }
        if let size { file.addChild(Element(name: "size", cdata: String(size))) }
        if let width, let height {
            file.addChild(Element(name: "width", cdata: String(width)))
            file.addChild(Element(name: "height", cdata: String(height)))
        }
        if let length, length > 0 { file.addChild(Element(name: "length", cdata: String(Int((length * 1000).rounded())))) }
        if let sha256 {
            let hash = Element(name: "hash", cdata: sha256.base64EncodedString(), xmlns: NS.hashes)
            hash.setAttribute("algo", value: "sha-256")
            file.addChild(hash)
        }
        if let thumbnail {
            let element = Element(name: "thumbnail", xmlns: NS.thumbnails)
            element.setAttribute("uri", value: "data:image/png;base64," + thumbnail.base64EncodedString())
            element.setAttribute("media-type", value: "image/png")
            file.addChild(element)
        }
        let sources = Element(name: "sources", children: [
            Element(name: "url-data", xmlns: NS.urlData).with(attribute: "target", url),
        ])
        return Element(name: "file-sharing", xmlns: NS.sfs, children: [file, sources]).with(attribute: "disposition", "inline")
    }
}

/// Hashes files and counts them, so that a test can tell when a file is read
/// again. Reading a file to hash it is the cost `OutgoingFileFacts` exists to
/// pay only once.
final class FileHasher: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var filesHashed: Int { count.withLock { $0 } }

    func sizeAndHash(of file: URL) throws -> (size: Int64, sha256: Data) {
        count.withLock { $0 += 1 }
        return try FileCrypto.sizeAndHash(of: file)
    }
}

/// What a file we send is, worked out the first time something needs it (the
/// metadata of an unencrypted message, a Jingle offer): its hash, and for a
/// picture the thumbnail we announce it with. They are kept on the attachment's
/// row, as the stored file is written once under a fresh name and never
/// changes, so a message sent again, after a relaunch too, and a Jingle offer
/// don't read the file again.
struct OutgoingFileFacts: Sendable {
    var size: Int64
    var sha256: Data
    var thumbnail: Data?

    /// Reads the file, so call it off the main thread.
    static func read(fileAt file: URL, isImage: Bool, with hasher: FileHasher) throws -> OutgoingFileFacts {
        let (size, hash) = try hasher.sizeAndHash(of: file)
        return OutgoingFileFacts(size: size, sha256: hash, thumbnail: isImage ? FileMetadata.sentThumbnail(ofFileAt: file) : nil)
    }

    /// `attachment` with its hash and thumbnail: as it is if the row has them,
    /// else worked out and stored now. Reads the file in that case, so call it off the main thread.
    static func completing(_ attachment: Attachment, in store: AttachmentStore, database: AppDatabase, with hasher: FileHasher) throws -> Attachment {
        if attachment.sha256 != nil, attachment.size != nil { return attachment }
        guard let file = store.url(for: attachment),
              let facts = try? read(fileAt: file, isImage: attachment.isImage, with: hasher)
        else { throw XMPPSession.AttachmentError.unreadable }
        var completed = attachment
        completed.sha256 = facts.sha256
        completed.ownThumbnail = facts.thumbnail
        completed.size = attachment.size ?? facts.size
        // Only a cache: if it isn't stored the next send reads the file again.
        try? database.setOutgoingFacts(facts, messageId: attachment.messageId)
        return completed
    }
}
