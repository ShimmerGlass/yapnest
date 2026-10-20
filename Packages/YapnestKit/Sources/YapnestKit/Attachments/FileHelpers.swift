import Foundation

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

    /// Keeps the last path component, replaces `:` and control characters
    /// (NUL included), drops leading dots and blanks so it can't be hidden or
    /// be `..`, and caps the length while keeping the extension. Empty
    /// results become `fallback`.
    public static func make(_ name: String, fallback: String = "File") -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
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
