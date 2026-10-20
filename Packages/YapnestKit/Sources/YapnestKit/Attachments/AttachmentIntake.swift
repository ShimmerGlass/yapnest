import Foundation
import UniformTypeIdentifiers

/// Decides what pasted or dropped items are, from the types they offer, so
/// the composer can tell a picture to send from text to type.
public enum AttachmentIntake {
    public enum Kind: Equatable, Sendable {
        /// Sent as a photo, re-encoded.
        case image
        /// Sent as it is.
        case file
        case text
        case other

        public var isAttachment: Bool { self == .image || self == .file }
    }

    /// What one item is. Images win over everything else it offers, since a
    /// copied picture usually brings along its URL or HTML; a file from the
    /// Finder offers its name as text, so a file URL wins over text.
    public static func kind(of typeIdentifiers: [String]) -> Kind {
        let types = typeIdentifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        if types.contains(where: { $0 == .fileURL }) { return .file }
        if types.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .audio) }) { return .file }
        // A vCard is text by type, but it is a contact to send, not words to type.
        if types.contains(where: { $0.conforms(to: .vCard) }) { return .file }
        if types.contains(where: { $0.conforms(to: .text) }) { return .text }
        if types.contains(where: { $0.conforms(to: .data) || $0.conforms(to: .item) }) { return .file }
        return .other
    }

    /// Whether an item offers text as well as what it is (a picture copied
    /// from a web page also offers its markup and address).
    public static func offersText(_ typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.compactMap { UTType($0) }.contains { $0.conforms(to: .text) && $0 != .fileURL }
    }

    /// Whether text that came with an image is only a label for it, such as
    /// its address or file name, rather than something written to go with
    /// it. Notes and Pages put real text next to a picture, and that's what
    /// pasting should give. Unrecognizable text isn't a label.
    public static func isLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard !trimmed.contains(where: \.isNewline), trimmed.count <= 2048 else { return false }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "data"].contains(scheme) {
            return true
        }
        // "IMG 1234.png": a name with a short extension.
        let ext = (trimmed as NSString).pathExtension
        return trimmed.count <= 255 && (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
