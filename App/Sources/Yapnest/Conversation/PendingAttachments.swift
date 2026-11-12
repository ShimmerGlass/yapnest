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
    var content: Content
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
        let item = PendingAttachment(content: .file(file, isPhoto: isPhoto))
        pendingAttachments.append(item)
        if !isPhoto, AttachmentStore.isVideo(name: file.lastPathComponent) { checkSize(ofVideo: file, id: item.id) }
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
                await self.stage(isPhoto: kind == .image) { try await ProviderCopy.copyOut(provider, kind: kind, under: FileManager.default.temporaryDirectory) }
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
                try await offMain {
                    try LongText.write(text, under: FileManager.default.temporaryDirectory)
                }
            }
        }
        return true
    }

    func removePendingAttachment(_ id: PendingAttachment.ID) {
        guard let item = pendingAttachments.first(where: { $0.id == id }) else { return }
        pendingAttachments.removeAll { $0.id == id }
        oversizedVideos.removeAll { $0 == id }
        // The task takes its folder away as it stops.
        shrinks.removeValue(forKey: id)?.task.cancel()
        if case .file(let file, _) = item.content { AttachmentPicker.discardCopy(file) }
    }
}

/// A smaller copy of a staged video being made.
struct VideoShrinkRun {
    var task: Task<URL?, Never>
    var progress: Double = 0
}

typealias ShrinkVideo = @Sendable (_ source: URL, _ folder: URL, _ limit: Int64, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL

extension ConversationModel {
    /// Asks the server's limit for a video just staged. Nothing happens when
    /// it isn't known, as offline: the video goes as it always did.
    func checkSize(ofVideo file: URL, id: PendingAttachment.ID) {
        let lookup = uploadLimitLookup, session = session, encrypted = chatIsEncrypted
        // Weak: the answer can take as long as the server does, and is of no use once the chat is left.
        Task { [weak self] in
            guard let limit = await lookup(session, encrypted), let self, file.fileSize > limit,
                  pendingAttachments.contains(where: { $0.id == id }) else { return }
            oversizedLimit = limit
            oversizedVideos.append(id)
            raiseVideoPrompt()
        }
    }

    /// One alert for every video waiting. Another prompt that is showing
    /// isn't replaced, and raising this one as that one closes could leave
    /// neither on screen: the videos wait for the next one found too large,
    /// or go as they are.
    private func raiseVideoPrompt() {
        guard prompt == nil, !oversizedVideos.isEmpty else { return }
        prompt = .videoTooLarge(limit: oversizedLimit)
    }

    func keepOriginalVideos() {
        oversizedVideos = []
        if case .videoTooLarge? = prompt { prompt = nil }
    }

    func sendSmallerVideos() {
        let ids = oversizedVideos, limit = oversizedLimit
        oversizedVideos = []
        if case .videoTooLarge? = prompt { prompt = nil }
        for id in ids { startShrink(id, limit: limit) }
    }

    private func startShrink(_ id: PendingAttachment.ID, limit: Int64) {
        guard let item = pendingAttachments.first(where: { $0.id == id }), case .file(let original, _) = item.content else { return }
        // A folder of its own directly under the temporary one, which is what `discardCopy` takes away.
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let shrink = shrinkVideo
        let task = Task<URL?, Never> { [weak self] in
            // The export is stopped when the app is suspended, so it asks for the time iOS gives to finish.
            let background = BackgroundTaskBox()
            background.id = UIApplication.shared.beginBackgroundTask(withName: "Shrink video") { background.end() }
            defer { background.end() }
            let result: Result<URL, Error>
            do {
                result = .success(try await shrink(original, folder, limit) { fraction in
                    Task { @MainActor in self?.shrinkProgressed(fraction, for: id) }
                })
            } catch {
                result = .failure(error)
            }
            if let self, !Task.isCancelled, let smaller = shrinkFinished(id, result, replacing: original) { return smaller }
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        shrinks[id] = VideoShrinkRun(task: task)
        composer.bar?.setShrinkProgress(0, for: id)
    }

    /// Ends a shrink that wasn't stopped. Returns the copy if it was staged in the original's place.
    private func shrinkFinished(_ id: PendingAttachment.ID, _ result: Result<URL, Error>, replacing original: URL) -> URL? {
        // Removing the video took its entry away, and its copy isn't wanted.
        guard shrinks.removeValue(forKey: id) != nil else { return nil }
        composer.bar?.setShrinkProgress(nil, for: id)
        switch result {
        case .success(let smaller):
            guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return nil }
            pendingAttachments[index].content = .file(smaller, isPhoto: false)
            AttachmentPicker.discardCopy(original)
            return smaller
        case .failure(let error):
            if !(error is CancellationError) {
                prompt = .notice(title: String(localized: "Couldn't make the video smaller"), message: error.localizedDescription)
            }
            return nil
        }
    }

    private func shrinkProgressed(_ fraction: Double, for id: PendingAttachment.ID) {
        guard shrinks[id] != nil else { return }
        shrinks[id]?.progress = fraction
        composer.bar?.setShrinkProgress(fraction, for: id)
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
        return try await offMain {
            try AttachmentPicker.writeIntoOwnFolder(data, named: fileName(for: gif) + ".gif")
        }
    }

    /// The slug as a file name: letters, digits, dashes and underscores only.
    nonisolated static func fileName(for gif: Gif) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(gif.slug.unicodeScalars.filter { allowed.contains($0) }.prefix(60).map(Character.init))
        return cleaned.isEmpty ? "gif" : cleaned
    }
}
