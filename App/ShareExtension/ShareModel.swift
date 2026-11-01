import Foundation
import Observation
import YapnestKit

/// What the share sheet shows and does: what's being shared, who to, and how
/// the send is going.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case signedOut
        case editing
        /// With how many messages the server has, of how many.
        case sending(sent: Int, total: Int)
        /// Ended: the messages are written, and the user reads how it went.
        case done(ShareEnding)
    }

    private(set) var phase = Phase.loading
    private(set) var items: [SharedItem] = []
    /// The files are still being copied.
    private(set) var isLoadingItems = true
    private(set) var recipients: [ChatListItem] = []
    private(set) var avatarURLs: [Int64: URL] = [:]
    var comment = ""
    var query = ""
    var selection: JID?
    /// Why the last attempt failed, to show in an alert.
    var failure: String?
    /// Why the chats couldn't be listed, so an empty list isn't mistaken for no chats.
    private(set) var recipientsFailure: String?

    /// Ends the extension's request.
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    private let sender: ShareSender?
    private let folder = SharedItemLoader.makeFolder()
    private var loading: Task<Void, Never>?

    init(items extensionItems: [NSExtensionItem], suggested: JID?) {
        sender = ShareSender.current()
        selection = suggested
        guard let sender else {
            phase = .signedOut
            return
        }
        nonisolated(unsafe) let extensionItems = extensionItems
        let folder = folder
        // The chats show as soon as they are read: copying a big file takes
        // longer, and the user can pick who to send to meanwhile.
        loading = Task {
            items = await SharedItemLoader(folder: folder).load(extensionItems)
            isLoadingItems = false
        }
        Task {
            let result = await Task.detached { try sender.recipients() }.result
            switch result {
            case .success(let all):
                recipients = all
                avatarURLs = Dictionary(uniqueKeysWithValues: all.compactMap { item in sender.avatarURL(for: item).map { (item.id, $0) } })
                if let selection, !all.contains(where: { $0.conversation.peer == selection }) { self.selection = nil }
            case .failure(let error):
                recipientsFailure = ServerError.userMessage(for: error)
            }
            phase = .editing
        }
    }

    var visibleRecipients: [ChatListItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recipients }
        return recipients.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.conversation.peer.description.localizedCaseInsensitiveContains(query) }
    }

    private var content: ShareContent {
        var content = ShareContent(comment: comment)
        for item in items {
            switch item.content {
            case .file(let file, _): content.files.append(file)
            case .text(let text, _): content.texts.append(text)
            case .unsupported: break
            }
        }
        return content
    }

    var canSend: Bool {
        selection != nil && phase == .editing && !isLoadingItems && !content.items().isEmpty
    }

    func send() {
        guard canSend, let sender, let peer = selection else { return }
        let content = content
        phase = .sending(sent: 0, total: content.items().count)
        Task {
            let outcome = await sender.send(content, to: peer) { sent, total in
                Task { @MainActor in self.progressed(sent, of: total) }
            }
            guard let ending = ShareEnding(outcome) else {
                // Nothing was written, so trying again is safe.
                if case .failed(let reason) = outcome { failure = reason }
                phase = .editing
                return
            }
            phase = .done(ending)
            // The preview stays up a moment, so the user sees it went. Where
            // there is a reason to read, it waits for Done.
            guard let linger = ending.linger else { return }
            try? await Task.sleep(for: linger)
            done()
        }
    }

    private func progressed(_ sent: Int, of total: Int) {
        if case .sending = phase { phase = .sending(sent: sent, total: total) }
    }

    func dismiss() {
        Task {
            await stopLoading()
            cancel()
        }
    }

    /// For the endings that wait for a tap: the messages are already in
    /// Yapnest, so the request is complete rather than cancelled.
    func acknowledge() { done() }

    private func done() {
        try? FileManager.default.removeItem(at: folder)
        finish()
    }

    /// Removes the folder only once the loader has stopped writing to it,
    /// which would otherwise leave copies behind.
    private func stopLoading() async {
        loading?.cancel()
        await loading?.value
        try? FileManager.default.removeItem(at: folder)
    }
}
