import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Attachment files on this device, sent and received.
public final class AttachmentStore: Sendable {
    public let directory: URL

    /// Sent photos are scaled to this many pixels on their long side.
    static let maxPhotoDimension = 2048
    /// Refuse to decode anything bigger, whatever its file size.
    static let maxImagePixels = 100_000_000

    public init(directory: URL) {
        self.directory = directory
    }

    /// A throwaway store, for tests and previews.
    public static func temporary() -> AttachmentStore {
        AttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "yapnest-attachments-\(UUID().uuidString)"))
    }

    public func url(for attachment: Attachment) -> URL? {
        attachment.localFile.map { directory.appending(path: $0) }
    }

    /// Deletes the file of an attachment that's gone, if we had it.
    func remove(_ attachment: Attachment) {
        guard let url = url(for: attachment) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: AnimatedImages.copyURL(for: url))
        try? FileManager.default.removeItem(at: AudioWaveform.cacheURL(for: url))
    }

    /// A random name with `name`'s extension, which is what tells viewers
    /// and other clients the type.
    static func freshName(keeping name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UUID().uuidString.lowercased() + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Stores `data` under a fresh name that keeps `name`'s extension, so
    /// viewers can tell the type.
    func save(_ data: Data, name: String) throws -> String {
        try FileManager.default.createProtectedDirectory(at: directory)
        let file = Self.freshName(keeping: name)
        try data.write(to: directory.appending(path: file), options: .atomic)
        return file
    }

    /// Takes over a finished download that was written inside the store (see
    /// `temporaryFile()`) under a fresh name that keeps `name`'s extension.
    func adopt(_ file: URL, name: String) throws -> String {
        let stored = Self.freshName(keeping: name)
        try FileManager.default.moveItem(at: file, to: directory.appending(path: stored))
        return stored
    }

    /// Prefix of the files being received, which a launch clears away: nothing
    /// resumes a transfer.
    static let partialPrefix = ".incoming-"

    /// A place to write a file as it arrives, which is not yet an attachment.
    func temporaryFile() throws -> URL {
        try FileManager.default.createProtectedDirectory(at: directory)
        return directory.appending(path: Self.partialPrefix + UUID().uuidString.lowercased())
    }

    /// Deletes what transfers that didn't finish left.
    func removePartialFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasPrefix(Self.partialPrefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }

    /// A file stored for sending.
    struct Imported {
        var file: String
        var name: String
        var size: Int64
        var width: Int?
        var height: Int?
        var duration: TimeInterval?
    }

    /// Stores the file at `url` for sending without reading it into memory,
    /// which the share extension can't afford: photos are scaled down by
    /// ImageIO straight into the store, and other files are copied. An
    /// animated image is copied too, since re-encoding would keep only its
    /// first frame. Videos and images copied as they are lose their location
    /// and, for images, the camera and owner details too, as photos do (a
    /// photo is rebuilt from its pixels, so nothing else comes along), since
    /// they are sent on to people the user may not want to tell where they
    /// were or what took them. Other files are copied untouched.
    func importFile(at url: URL, name: String, asPhoto: Bool) async throws -> Imported {
        try FileManager.default.createProtectedDirectory(at: directory)
        if asPhoto, let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1, let (width, height) = Self.pixelSize(of: source), width * height <= Self.maxImagePixels {
            let base = (name as NSString).deletingPathExtension
            let jpegName = (base.isEmpty ? "photo" : base) + ".jpg"
            let file = UUID().uuidString.lowercased() + ".jpg"
            let destination = directory.appending(path: file)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.maxPhotoDimension),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(output) {
                    return Imported(file: file, name: jpegName, size: destination.fileSize, width: image.width, height: image.height)
                }
            }
            try? FileManager.default.removeItem(at: destination)
        }
        let file = Self.freshName(keeping: name)
        let isVideo = Self.isVideo(name: name)
        let destination = directory.appending(path: file)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw XMPPSession.AttachmentError.unreadable
        }
        // Better to refuse a file than to send one that still says where it
        // was made.
        do {
            if isVideo {
                try await Self.stripVideoMetadata(at: destination)
            } else if Self.isImage(name: name) {
                // Only images go to ImageIO, so a PDF or an archive isn't parsed by it.
                // It does nothing to an image it can't read.
                try Self.stripMetadata(fromImageAt: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw XMPPSession.AttachmentError.unreadable
        }
        var dimensions: (width: Int, height: Int)?
        let duration = AudioFormat.isAudio(mimeType: nil, name: name) ? AudioWaveform.duration(of: destination) : nil
        if isVideo {
            dimensions = await Self.videoSize(of: destination)
        } else {
            dimensions = Self.imageSize(ofFileAt: destination)
        }
        return Imported(file: file, name: name, size: destination.fileSize, width: dimensions?.width, height: dimensions?.height, duration: duration)
    }

    struct MetadataError: Error {}

    /// Rewrites the image at `url` without the metadata that says who took it
    /// and where: location, camera make, model and serial, capture time,
    /// software, owner and IPTC fields. Every frame is kept, and so are the
    /// orientation and the colour profile, which the picture needs to be shown
    /// right. Images that carry nothing to remove are left alone, so nothing is
    /// re-encoded for no reason (and formats ImageIO can't write still go
    /// through).
    static func stripMetadata(fromImageAt url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return }
        let count = CGImageSourceGetCount(source)
        let frames = (0..<count).map { frameProperties(source, at: $0) }
        guard frames.contains(where: hasRemovableMetadata) else { return }
        let temporary = url.deletingLastPathComponent().appending(path: UUID().uuidString.lowercased() + "." + url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, type, count, nil) else { throw MetadataError() }
        // The container's own properties (a GIF's loop count) go along.
        if let container = CGImageSourceCopyProperties(source, nil) { CGImageDestinationSetProperties(output, container) }
        for index in 0..<count {
            // An empty metadata block replaces the image's own, which is where
            // XMP and the text a PNG keeps its author in live. The orientation
            // is set apart because the TIFF dictionary it also sits in is
            // dropped whole.
            var options: [CFString: Any] = [
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata: false,
            ]
            for key in removableDictionaries { options[key] = kCFNull }
            if let orientation = frames[index]?[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
            CGImageDestinationAddImageFromSource(output, source, index, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(output) else { throw MetadataError() }
        // Only a copy that came out clean replaces the original.
        guard let written = CGImageSourceCreateWithURL(temporary as CFURL, nil), CGImageSourceGetCount(written) == count,
              !(0..<count).contains(where: { hasRemovableMetadata(frameProperties(written, at: $0)) })
        else { throw MetadataError() }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// The property dictionaries that describe the photographer or the camera
    /// rather than the picture. The GIF and JFIF ones stay for the frame
    /// timing and density they hold.
    // CFString isn't Sendable, but these are constants nobody changes.
    nonisolated(unsafe) private static let removableDictionaries: [CFString] = [
        kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary,
        kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary, kCGImagePropertyCIFFDictionary, kCGImagePropertyDNGDictionary,
        kCGImagePropertyRawDictionary,
    ]

    /// Which entries of the dictionaries that hold both kinds are only about
    /// how the picture is stored.
    nonisolated(unsafe) private static let structuralKeys: [CFString: Set<CFString>] = [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
            kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
            kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
        ],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace],
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGGamma, kCGImagePropertyPNGsRGBIntent,
            kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter, kCGImagePropertyPNGChromaticities,
        ],
    ]

    private static func frameProperties(_ source: CGImageSource, at index: Int) -> [CFString: Any]? {
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    }

    private static func hasRemovableMetadata(_ properties: [CFString: Any]?) -> Bool {
        guard let properties else { return false }
        return removableDictionaries.contains { key in
            guard let entries = properties[key] as? [CFString: Any] else { return false }
            guard let structural = structuralKeys[key] else { return true }
            return entries.keys.contains { !structural.contains($0) }
        }
    }

    /// Re-exports the video at `url` without copying the streams, dropping
    /// the metadata that isn't fit for sharing, such as its location.
    static func stripVideoMetadata(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw MetadataError() }
        session.metadataItemFilter = .forSharing()
        let type: AVFileType = switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
        let temporary = url.deletingLastPathComponent().appending(path: UUID().uuidString.lowercased() + "." + url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await session.export(to: temporary, as: type)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Displayed size of an image file, after its EXIF orientation.
    static func imageSize(of data: Data) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(orientedSize(of:))
    }

    /// `imageSize(of:)` for a file, read in place so a large one isn't loaded.
    static func imageSize(ofFileAt url: URL) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(orientedSize(of:))
    }

    private static func orientedSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let (width, height) = pixelSize(of: source) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// Displayed size of the file `data` was saved as: an image's after its
    /// orientation, a video's after its rotation. Nil for anything else.
    static func displaySize(of data: Data, savedAs file: URL, name: String) async -> (width: Int, height: Int)? {
        if let size = imageSize(of: data) { return size }
        return isVideo(name: name) ? await videoSize(of: file) : nil
    }

    /// `displaySize(of:savedAs:name:)` for a file that isn't in memory.
    static func displaySize(ofFileAt file: URL, name: String) async -> (width: Int, height: Int)? {
        if let size = imageSize(ofFileAt: file) { return size }
        return isVideo(name: name) ? await videoSize(of: file) : nil
    }

    static func isVideo(name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .movie) ?? false
    }

    static func isImage(name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false
    }

    /// Displayed size of a video: its first track's natural size, turned by
    /// the track's transform so a portrait recording isn't reported sideways.
    static func videoSize(of url: URL) async -> (width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let size = natural.applying(transform)
        let width = Int(abs(size.width).rounded()), height = Int(abs(size.height).rounded())
        return width > 0 && height > 0 ? (width, height) : nil
    }

    static func pixelSize(of source: CGImageSource) -> (Int, Int)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func mimeType(for name: String) -> String? {
        // The system calls an .m4a "audio/x-m4a", which other clients don't
        // know as a voice message; it is MPEG-4 audio.
        if (name as NSString).pathExtension.lowercased() == "m4a" { return "audio/mp4" }
        return UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
    }
}
