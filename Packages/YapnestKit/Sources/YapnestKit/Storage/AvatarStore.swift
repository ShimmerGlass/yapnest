import CryptoKit
import Foundation
import ImageIO

/// Avatar images on disk, named by the SHA-1 of their contents, which is how
/// both XEP-0084 and XEP-0153 identify them.
public final class AvatarStore: Sendable {
    public let directory: URL

    /// Larger images are ignored; avatars are meant to be small.
    static let maxSize = 1024 * 1024

    /// The longest side an avatar may have. A file's size says little about
    /// its pixels: a solid-colour PNG of 15000 by 15000 is under 1 MB and
    /// takes about 900 MB to decode, which would take the app, or the
    /// extensions with their small memory limits, down.
    public static let maxDimension = 4096

    /// Past this side, an interlaced PNG or one with 16 bits per channel is
    /// refused. ImageIO decodes those in full even for a thumbnail, at 70 to
    /// 140 MB for 4096 pixels, which the notification extension's limit of
    /// about 24 MB can't take. The file is named by its hash, so it can't be
    /// re-encoded smaller: it is refused instead.
    static let maxHeavyDimension = 1024

    public init(directory: URL) {
        self.directory = directory
    }

    /// A throwaway store, for tests and previews.
    public static func temporary() -> AvatarStore {
        AvatarStore(directory: FileManager.default.temporaryDirectory.appending(path: "yapnest-avatars-\(UUID().uuidString)"))
    }

    public func url(for hash: String) -> URL {
        directory.appending(path: hash.lowercased())
    }

    /// Where `contact`'s picture is, if they have one.
    public func url(for contact: Contact?) -> URL? {
        contact?.avatarHash.map(url(for:))
    }

    public func contains(_ hash: String) -> Bool {
        Self.isValidHash(hash) && FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    /// Stores `data` if it really hashes to `hash`, so a contact can't make
    /// another's avatar show up by claiming its hash.
    func save(_ data: Data, hash: String) -> Bool {
        guard data.count <= Self.maxSize, Self.hash(of: data) == hash.lowercased(),
              let source = CGImageSourceCreateWithData(data as CFData, nil), Self.hasAcceptableSize(source) else { return false }
        do {
            try FileManager.default.createProtectedDirectory(at: directory)
            try data.write(to: url(for: hash), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Whether the image's header, read without decoding it, gives a size
    /// we're willing to decode, and a way of storing the pixels that doesn't
    /// make decoding cost far more than the size says. Anything that isn't an image doesn't.
    static func hasAcceptableSize(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        guard width > 0, height > 0, max(width, height) <= maxDimension else { return false }
        guard max(width, height) > maxHeavyDimension else { return true }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let isInterlaced = (png?[kCGImagePropertyPNGInterlaceType] as? Int ?? 0) != 0
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        return !isInterlaced && depth <= 8
    }

    /// The image scaled down to fit `pixels` on its longest side, never
    /// decoded in full. Nil if it isn't an image or is oversized, which files
    /// stored before the size check may be.
    public static func thumbnail(of source: CGImageSource, pixels: Int) -> CGImage? {
        guard hasAcceptableSize(source) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    public static func thumbnail(at url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(of: source, pixels: pixels)
    }

    /// A hex SHA-1, as avatars are named; anything else, which may come
    /// from anyone, could point outside the store.
    static func isValidHash(_ hash: String) -> Bool {
        hash.count == 40 && hash.allSatisfy(\.isHexDigit)
    }

    /// A vCard's photo, decoded only if it could fit `maxSize`: the stanza
    /// can be tens of megabytes, and decoding comes before the size check.
    static func data(fromBase64 binval: String) -> Data? {
        guard binval.utf8.count <= maxSize * 4 / 3 + 4096 else { return nil }
        return Data(base64Encoded: binval, options: .ignoreUnknownCharacters)
    }

    static func hash(of data: Data) -> String {
        Data(Insecure.SHA1.hash(data: data)).hex
    }
}
