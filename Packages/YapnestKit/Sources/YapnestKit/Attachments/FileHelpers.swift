import Foundation
import ImageIO
import UniformTypeIdentifiers

extension URL {
    /// The file's size in bytes, or 0 if it can't be read.
    public var fileSize: Int64 {
        Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

extension FileManager {
    /// Copies `source` into a folder of its own under `folder`, so two files
    /// named alike don't collide, and returns the copy. `name` replaces the
    /// file's own name.
    public func copyIntoUniqueFolder(_ source: URL, named name: String? = nil, under folder: URL) throws -> URL {
        let directory = folder.appending(path: UUID().uuidString)
        // The name may come from another app or a sender; it must stay a plain file name.
        let destination = directory.appending(path: SafeFileName.make(name ?? source.lastPathComponent), directoryHint: .notDirectory)
        try createDirectory(at: directory, withIntermediateDirectories: true)
        try copyItem(at: source, to: destination)
        return destination
    }
}

/// Turns a name that someone else chose into one that is safe as a single
/// path component.
public enum SafeFileName {
    public static let maxLength = 120
    private static let keptFormatCharacters: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    /// Removes format characters (category Cf): bidi overrides and isolates,
    /// zero-width spaces, the soft hyphen. A right-to-left override turns
    /// `photo<RLO>gnp.exe` into a name that reads `photoexe.png`. The joiner
    /// and non-joiner stay, as Persian, Indic and emoji sequences need them
    /// and they can't reorder what is shown.
    public static func removingFormatCharacters(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format || keptFormatCharacters.contains($0) }))
    }

    /// Keeps the last path component, removes format characters, replaces `:`
    /// and control characters (NUL included), drops leading dots and blanks
    /// so it can't be hidden or be `..`, and caps the length while keeping the extension. Empty
    /// results become `fallback`.
    public static func make(_ name: String, fallback: String = "File") -> String {
        let last = removingFormatCharacters(name).split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.map {
            $0 == ":" || $0.properties.generalCategory == .control ? "-" : $0
        }))
        var result = String(cleaned.drop(while: { $0 == "." || $0.isWhitespace }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > maxLength {
            let ext = (result as NSString).pathExtension
            if !ext.isEmpty, ext.count <= 16 {
                result = String(result.dropLast(ext.count + 1).prefix(maxLength - ext.count - 1)) + "." + ext
            } else {
                result = String(result.prefix(maxLength))
            }
        }
        return result.isEmpty ? fallback : result
    }
}

extension CGImage {
    /// The image encoded as `type`, with `quality` (0 to 1) for lossy ones.
    func encoded(as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, self, options)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

extension CGImageSource {
    /// Frame `index` decoded no larger than `maxPixelSize` on its longest
    /// side, with its orientation applied and without decoding it in full.
    func thumbnail(at index: Int = 0, maxPixelSize: Int, cacheImmediately: Bool = false) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if cacheImmediately { options[kCGImageSourceShouldCacheImmediately] = true }
        return CGImageSourceCreateThumbnailAtIndex(self, index, options as CFDictionary)
    }
}
