import Foundation
import UniformTypeIdentifiers
import YapnestKit

/// One thing from the share sheet, ready to show and send.
struct SharedItem: Identifiable {
    enum Content {
        case file(ShareContent.File, size: Int64)
        /// Text, or a link.
        case text(String, isLink: Bool)
        /// Left out, and why.
        case unsupported(name: String, reason: String)
    }

    let id = UUID()
    var content: Content
}

/// Turns what other apps share into files and text. The system's copies of
/// shared files vanish when its callback returns, and a file can be big, so
/// each is copied once into a folder of the shared container, which goes when
/// the extension is done.
struct SharedItemLoader: Sendable {
    /// Larger files aren't taken: the server won't have them either.
    static let maxFileSize: Int64 = 200 * 1024 * 1024

    let folder: URL

    static var staging: URL { SharedContainer.url.appending(path: "share-staging") }

    /// A new folder for one share; older ones left by an extension that was
    /// killed are removed.
    static func makeFolder() -> URL {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for old in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? fm.removeItem(at: old)
            }
        }
        let folder = staging.appending(path: UUID().uuidString)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func load(_ items: [NSExtensionItem]) async -> [SharedItem] {
        var loaded: [SharedItem] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if let content = await load(provider) { loaded.append(SharedItem(content: content)) }
            }
        }
        // A page shared from Safari comes as its link and its title; the
        // link is what to send.
        if loaded.contains(where: { if case .text(_, true) = $0.content { true } else { false } }) {
            loaded.removeAll { if case .text(_, false) = $0.content { true } else { false } }
        }
        // After the rule above, which has to see this as text.
        return loaded.map { item in
            guard case .text(let text, false) = item.content, let file = longTextFile(text) else { return item }
            return SharedItem(content: file)
        }
    }

    private func load(_ provider: NSItemProvider) async -> SharedItem.Content? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let type = types.first(where: { $0.conforms(to: .image) }) ?? types.first(where: { $0.conforms(to: .movie) }) {
            return await file(from: provider, type: type, isPhoto: Self.isPhoto(type))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await fileFromURL(of: provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return .text(url.absoluteString, isLink: true)
            }
        }
        // A text file from the Files app may offer only its text type; it is a
        // file to send, which the fallback below does.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), !AttachmentIntake.isFileBacked(provider) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return .text(text, isLink: false)
            }
            return nil
        }
        if let type = types.first(where: { $0.conforms(to: .data) }) {
            return await file(from: provider, type: type, isPhoto: false)
        }
        return nil
    }

    /// Shared text too long for a message (`LongText`), as a file to send.
    private func longTextFile(_ text: String) -> SharedItem.Content? {
        guard LongText.isLong(text),
              let file = try? LongText.write(text, prefix: String(localized: "Shared text"), under: folder)
        else { return nil }
        return .file(.init(url: file, name: file.lastPathComponent, isPhoto: false), size: file.fileSize)
    }

    /// The provider's own file, copied before its callback returns.
    private func file(from provider: NSItemProvider, type: UTType, isPhoto: Bool) async -> SharedItem.Content? {
        let folder = folder
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                continuation.resume(returning: Self.copy(url, into: folder, isPhoto: isPhoto))
            }
        }
    }

    /// A file shared by its address, from the Files app or the Finder.
    private func fileFromURL(of provider: NSItemProvider) async -> SharedItem.Content? {
        guard let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL, url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        return Self.copy(url, into: folder, isPhoto: Self.isPhoto(type))
    }

    private static func isPhoto(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .gif)
    }

    private static func copy(_ url: URL, into folder: URL, isPhoto: Bool) -> SharedItem.Content {
        let size = url.fileSize
        guard size <= maxFileSize else {
            return .unsupported(name: url.lastPathComponent, reason: String(localized: "Too large to send"))
        }
        let destination: URL
        do {
            destination = try FileManager.default.copyIntoUniqueFolder(url, under: folder)
        } catch {
            return .unsupported(name: url.lastPathComponent, reason: String(localized: "Couldn't be read"))
        }
        return .file(.init(url: destination, name: url.lastPathComponent, isPhoto: isPhoto), size: size)
    }
}
