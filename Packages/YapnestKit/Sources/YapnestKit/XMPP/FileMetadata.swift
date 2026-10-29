import CryptoKit
import Foundation
import ImageIO
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

    /// What to tell the recipient of `attachment`'s file, which is a picture
    /// or a sound in the store. Nil for anything else. Reads the file, so call
    /// it off the main thread.
    static func outgoing(for attachment: Attachment, in store: AttachmentStore) -> FileMetadata? {
        if attachment.isAudio {
            guard let file = store.url(for: attachment), let (size, hash) = try? FileCrypto.sizeAndHash(of: file) else { return nil }
            return FileMetadata(mediaType: attachment.mimeType, size: size, length: attachment.duration, name: attachment.name, sha256: hash)
        }
        guard attachment.isImage, let width = attachment.imageSize.map({ Int($0.width) }), let height = attachment.imageSize.map({ Int($0.height) }),
              let (data, hash) = contents(of: attachment, in: store),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return FileMetadata(
            mediaType: attachment.mimeType, size: Int64(data.count), width: width, height: height,
            thumbnail: pngThumbnail(of: source, maxSide: sentThumbnailSide), name: attachment.name, sha256: hash,
        )
    }

    /// The stored file and its SHA-256.
    private static func contents(of attachment: Attachment, in store: AttachmentStore) -> (Data, Data)? {
        guard let file = store.url(for: attachment), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return (data, Data(SHA256.hash(data: data)))
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
