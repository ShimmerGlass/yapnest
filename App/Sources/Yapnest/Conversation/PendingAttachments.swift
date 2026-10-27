import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import YapnestKit

/// Something added to the composer to go out with the next send: a file
/// (a picture, a video, a contact's vCard or anything else) that has been
/// copied into a folder of our own, or a place.
struct PendingAttachment: Identifiable {
    enum Content {
        case file(URL, isPhoto: Bool)
        case location(GeoLocation)
    }

    let id = UUID()
    let content: Content
}

extension ConversationModel {
    /// Whether anything can be added to the composer. If not, says so, since
    /// the picker or paste that asked would otherwise seem to do nothing.
    func refuseUnlessCanSend() -> Bool {
        guard canSendAttachments else {
            prompt = .notice(title: String(localized: "Can't send here"), message: String(localized: "You can't send messages in this chat right now."))
            return false
        }
        return true
    }

    func stage(_ file: URL, isPhoto: Bool) {
        pendingAttachments.append(PendingAttachment(content: .file(file, isPhoto: isPhoto)))
    }

    func stageLocation(_ location: GeoLocation) {
        guard refuseUnlessCanSend() else { return }
        pendingAttachments.append(PendingAttachment(content: .location(location)))
    }

    func openGifPicker() {
        guard refuseUnlessCanSend() else { return }
        showsGifPicker = true
    }

    /// Downloads the GIF to send, which is larger than the one the picker
    /// showed, and adds it to the composer like any other picture.
    func addGif(_ gif: Gif) {
        guard refuseUnlessCanSend() else { return }
        preparing {
            await self.stage(isPhoto: true) { try await GifDownload.fetch(gif) }
        }
    }

    /// Runs `work` with the attach button's spinner showing.
    func preparing(_ work: @escaping @MainActor () async -> Void) {
        preparingAttachments += 1
        Task {
            defer { preparingAttachments -= 1 }
            await work()
        }
    }

    /// Stages the file `make` produces, or reports why there isn't one.
    func stage(isPhoto: Bool, _ make: () async throws -> URL) async {
        do {
            stage(try await make(), isPhoto: isPhoto)
        } catch {
            reportAttachFailure(error)
        }
    }

    /// Copies pasted or dropped items aside, since their files go away when
    /// the pasteboard or drag does, and adds them to the composer.
    func offerAttachments(_ providers: [NSItemProvider]) {
        guard refuseUnlessCanSend() else { return }
        preparing {
            // In order, so they are sent the way they were put there.
            for (provider, kind) in AttachmentIntake.attachments(in: providers) {
                await self.stage(isPhoto: kind == .image) { try await Self.copyOut(provider, kind: kind) }
            }
        }
    }

    /// Text too long to type (`LongText`) is staged as a .txt file, so the
    /// user can still look at it and remove it before sending. While a
    /// message is being edited the text is the edit, and the caller types it
    /// (a staged file would wait for the next message, not join the edit).
    /// Returns whether the text was taken.
    @discardableResult
    func offerLongText(_ text: String) -> Bool {
        guard editingItem == nil else { return false }
        guard refuseUnlessCanSend() else { return true }
        preparing {
            await self.stage(isPhoto: false) {
                try await Task.detached(priority: .userInitiated) {
                    try LongText.write(text, under: FileManager.default.temporaryDirectory)
                }.value
            }
        }
        return true
    }

    func removePendingAttachment(_ id: PendingAttachment.ID) {
        guard let item = pendingAttachments.first(where: { $0.id == id }) else { return }
        pendingAttachments.removeAll { $0.id == id }
        if case .file(let file, _) = item.content { AttachmentPicker.discardCopy(file) }
    }

    private static func copyOut(_ provider: NSItemProvider, kind: AttachmentIntake.Kind) async throws -> URL {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let type: UTType?
        if kind == .image {
            type = types.first { $0.conforms(to: .image) }
        } else {
            type = types.first { $0 != .fileURL && $0 != .url && $0.conforms(to: .data) } ?? .item
        }
        if let type {
            do { return try await AttachmentPicker.copy(from: provider, type: type) } catch where kind != .image { throw error }
        }
        // A picture that only exists as an object, with no file behind it.
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                if let image = image as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        return try await AttachmentPicker.writeJPEG(image)
    }
}

/// Accepts pictures and files dropped on the message list, with a cue while
/// they're over it. Text is left for the composer to take.
struct AttachmentDropDelegate: DropDelegate {
    let model: ConversationModel
    @Binding var isTargeted: Bool

    private func attachments(_ info: DropInfo) -> [NSItemProvider] {
        AttachmentIntake.attachments(in: info.itemProviders(for: [.item])).map(\.provider)
    }

    func validateDrop(info: DropInfo) -> Bool { AttachmentIntake.containsAttachment(info.itemProviders(for: [.item])) }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = attachments(info)
        guard !providers.isEmpty else { return false }
        model.offerAttachments(providers)
        return true
    }
}

/// Fetches the GIF to send into a folder of its own, like the other copies
/// the composer holds, so clearing it removes the file.
enum GifDownload {
    struct NotAGif: LocalizedError {
        var errorDescription: String? { String(localized: "That GIF couldn't be downloaded.") }
    }

    static func fetch(_ gif: Gif) async throws -> URL {
        let data: Data
        do {
            data = try await GifService.download(gif.shared.url)
        } catch is GifService.DownloadError {
            throw NotAGif()
        }
        // A service error page or another format would otherwise be sent as a GIF.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier
        else { throw NotAGif() }
        return try await Task.detached(priority: .userInitiated) {
            try AttachmentPicker.writeIntoOwnFolder(data, named: fileName(for: gif) + ".gif")
        }.value
    }

    /// The slug as a file name: letters, digits, dashes and underscores only.
    nonisolated static func fileName(for gif: Gif) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(gif.slug.unicodeScalars.filter { allowed.contains($0) }.prefix(60).map(Character.init))
        return cleaned.isEmpty ? "gif" : cleaned
    }
}
