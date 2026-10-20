import CryptoKit
import Foundation
import GRDB
import ImageIO
import os
import UniformTypeIdentifiers

/// Fetches link previews from this device and stores them for the
/// conversation view to show. Fetching reveals the device's IP address to the
/// linked site, so callers only ask once the user allowed previews in a
/// conversation.
public final class LinkPreviewer: Sendable {
    public let directory: URL
    private let database: AppDatabase
    private let fetcher: LinkFetching
    private let inFlight = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Links whose preview was fetched but couldn't be stored. Without this
    /// they would be fetched again every time their message shows.
    private let unstored = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let logger = Logger(subsystem: "Yapnest", category: "LinkPreviews")

    static let maxPageSize = 1024 * 1024
    static let maxImageSize = 10 * 1024 * 1024
    /// Larger images are scaled down to this many points on their long side.
    static let maxImageDimension = 1600
    /// Refuse to decode anything bigger, whatever its file size.
    static let maxImagePixels = 50_000_000

    /// - Parameter fetcher: for tests to replace the network. The default
    ///   fetcher keeps previews away from the local network and sends no
    ///   cookies, so nothing links fetches together.
    public convenience init(database: AppDatabase, directory: URL) {
        self.init(database: database, directory: directory, fetcher: SafeFetcher())
    }

    init(database: AppDatabase, directory: URL, fetcher: LinkFetching) {
        self.database = database
        self.directory = directory
        self.fetcher = fetcher
    }

    public func imageURL(for preview: LinkPreview) -> URL? {
        preview.imageFile.map { directory.appending(path: $0) }
    }

    /// Fetches `url`'s preview in the background unless it's stored or on its way.
    public func fetchIfNeeded(_ url: URL) {
        let key = url.absoluteString
        guard !unstored.withLock({ $0.contains(key) }), inFlight.withLock({ $0.insert(key).inserted }) else { return }
        Task.detached(priority: .utility) { [self] in
            defer { _ = inFlight.withLock { $0.remove(key) } }
            let stored = try? await database.reader.read { db in try LinkPreview.fetchOne(db, key: key) }
            guard stored == nil else { return }
            let preview: LinkPreview
            do {
                preview = try await fetch(url)
            } catch {
                // Offline or timed out: try again next time the message shows.
                return
            }
            do {
                try await database.writer.write { db in try preview.save(db) }
            } catch {
                _ = unstored.withLock { $0.insert(key) }
                Self.logger.error("Couldn't store the preview of a link: \(error)")
            }
        }
    }

    /// Downloads and describes `url`. Throws only for errors worth retrying
    /// (no connection, or a server that's failing or busy); a link with
    /// nothing to show yields a `.none` preview.
    func fetch(_ url: URL) async throws -> LinkPreview {
        let key = url.absoluteString
        guard url.scheme?.lowercased() == "https" else { return LinkPreview(url: key, kind: .none) }

        guard let page = try await download(url, limits: FetchLimits(
            maxBytes: max(Self.maxPageSize, Self.maxImageSize), maxHTMLBytes: Self.maxPageSize, stopAtEndOfHead: true,
        )), try Self.isUsable(page) else { return LinkPreview(url: key, kind: .none) }
        let mimeType = page.mimeType ?? ""

        if mimeType.hasPrefix("image/") {
            guard let image = saveImage(page.body, for: key) else { return LinkPreview(url: key, kind: .none) }
            return LinkPreview(url: key, kind: .image, imageFile: image.file, imageWidth: image.width, imageHeight: image.height)
        }

        guard mimeType == "text/html" || mimeType == "application/xhtml+xml" else { return LinkPreview(url: key, kind: .none) }
        let html = Self.decode(page.body, encodingName: page.charset)
        let graph = OpenGraph(html: html, base: page.url)
        guard !graph.isEmpty else { return LinkPreview(url: key, kind: .none) }

        var preview = LinkPreview(
            url: key,
            kind: .page,
            title: graph.title.map { String($0.prefix(300)) },
            summary: graph.description.map { String($0.prefix(500)) },
            siteName: graph.siteName.map { String($0.prefix(100)) } ?? page.url.host(),
        )
        // A transient failure here throws, so the whole preview is tried again
        // rather than stored for good without its picture.
        if let imageURL = graph.image, imageURL.scheme?.lowercased() == "https",
           let imageResponse = try await download(imageURL, limits: FetchLimits(
               maxBytes: Self.maxImageSize, maxHTMLBytes: Self.maxPageSize, stopAtEndOfHead: false,
           )), try Self.isUsable(imageResponse),
           let image = saveImage(imageResponse.body, for: key) {
            preview.imageFile = image.file
            preview.imageWidth = image.width
            preview.imageHeight = image.height
        }
        return preview
    }

    /// Whether the response is a success. Throws for the statuses that say
    /// try again later; any other failure means the link has nothing to show.
    static func isUsable(_ resource: FetchedResource) throws -> Bool {
        let status = resource.status
        if (500..<600).contains(status) || status == 429 || status == 408 {
            throw FetchError.unreachable("HTTP \(status)")
        }
        return (200..<300).contains(status)
    }

    /// Nil when the link is refused or its response is unusable; throws only
    /// when trying again later could work.
    private func download(_ url: URL, limits: FetchLimits) async throws -> FetchedResource? {
        do {
            return try await fetcher.fetch(url, limits: limits)
        } catch let error as FetchError where !error.isRetryable {
            return nil
        }
    }

    /// Scales the image down, re-encodes it and stores it under a name
    /// derived from the link. Nil if it isn't a usable image.
    private func saveImage(_ data: Data, for key: String) -> (file: String, width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= Self.maxImagePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.maxImageDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let file = Self.fileName(for: key) + (hasAlpha ? ".png" : ".jpg")
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (output as Data).write(to: directory.appending(path: file), options: .atomic)
        } catch {
            return nil
        }
        return (file, Double(image.width), Double(image.height))
    }

    static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cf != kCFStringEncodingInvalidId,
               let string = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return string
            }
        }
        // A page cut off mid-character isn't valid UTF-8; drop just that
        // character. Anything else invalid is replaced character by character.
        if let string = String(data: data.dropLast(truncatedTailLength(data)), encoding: .utf8) { return string }
        return String(decoding: data, as: UTF8.self)
    }

    /// The length of a UTF-8 sequence cut off at the end of `data`, else 0.
    private static func truncatedTailLength(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        for back in 1...min(3, data.count) {
            let byte = data[data.endIndex - back]
            if byte & 0xC0 == 0x80 { continue }  // a continuation byte: look further back
            let expected = (0xF0...0xF4).contains(byte) ? 4 : (0xE0..<0xF0).contains(byte) ? 3 : (0xC2..<0xE0).contains(byte) ? 2 : 1
            return expected > back ? back : 0
        }
        return 0
    }
}
