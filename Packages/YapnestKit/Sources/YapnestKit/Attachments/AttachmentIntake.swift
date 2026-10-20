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

    /// What one pasted or dropped item is. A text file dragged from the
    /// Finder or the Files app may offer only its own type, `public.plain-text`,
    /// and no file URL, so by type alone it looks like words to type; being
    /// backed by a file is what tells it from those. Callers classify once and
    /// keep the answer, as this asks the provider each time.
    public static func kind(of provider: NSItemProvider) -> Kind {
        let kind = kind(of: provider.registeredTypeIdentifiers)
        return kind == .text && isFileBacked(provider) ? .file : kind
    }

    /// The items that are pictures or files, with what each is.
    public static func attachments(in providers: [NSItemProvider]) -> [(provider: NSItemProvider, kind: Kind)] {
        providers.map { ($0, kind(of: $0)) }.filter { $0.1.isAttachment }
    }

    /// Whether any item is a picture or a file, which the text field's own
    /// drop must then stand aside for. Asked on every drag move.
    public static func containsAttachment(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { kind(of: $0).isAttachment }
    }

    /// Whether the item is a file rather than content made for the drag. Text
    /// selected in a browser or note is registered as data; a file is
    /// registered to be opened in place. A name alone says nothing, as a link
    /// dragged from a page has one too.
    public static func isFileBacked(_ provider: NSItemProvider) -> Bool {
        !provider.registeredTypeIdentifiers(fileOptions: [.openInPlace]).isEmpty
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
