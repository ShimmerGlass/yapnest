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
        /// Ended without the user needing to do anything more.
        case done(Done)
    }

    enum Done: Equatable {
        case sent
        /// Written, and Yapnest, which is running and holds the session, has
        /// been told to send it now.
        case handedToApp
        /// Written, to be sent by Yapnest when it next opens.
        case queued
        /// Written, but a message failed. It waits in Yapnest, where it can
        /// be retried.
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var items: [SharedItem] = []
    private(set) var recipients: [ChatListItem] = []
    private(set) var avatarURLs: [Int64: URL] = [:]
    var comment = ""
    var query = ""
    var selection: JID?
    /// Why the last attempt failed, to show in an alert.
    var failure: String?

    /// Ends the extension's request.
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    private let sender: ShareSender?
    private let folder = SharedItemLoader.makeFolder()

    init(items extensionItems: [NSExtensionItem], suggested: JID?) {
        sender = ShareSender.current()
        selection = suggested
        guard let sender else {
            phase = .signedOut
            return
        }
        nonisolated(unsafe) let extensionItems = extensionItems
        let folder = folder
        Task {
            async let loaded = SharedItemLoader(folder: folder).load(extensionItems)
            async let chats = Task.detached { try? sender.recipients() }.value
            items = await loaded
            let all = await chats ?? []
            recipients = all
            avatarURLs = Dictionary(uniqueKeysWithValues: all.compactMap { item in sender.avatarURL(for: item).map { (item.id, $0) } })
            if let selection, !all.contains(where: { $0.conversation.peer == selection }) { self.selection = nil }
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
        selection != nil && phase == .editing && !content.items().isEmpty
    }

    func send() {
        guard canSend, let sender, let peer = selection else { return }
        let content = content
        phase = .sending(sent: 0, total: content.items().count)
        Task {
            let outcome = await sender.send(content, to: peer) { sent, total in
                Task { @MainActor in self.progressed(sent, of: total) }
            }
            switch outcome {
            case .sent:
                phase = .done(.sent)
            case .handedToApp:
                phase = .done(.handedToApp)
            case .queued:
                phase = .done(.queued)
            case .failed(let reason):
                // Nothing was written, so trying again is safe.
                failure = reason
                phase = .editing
                return
            case .failedInApp(let reason):
                // Sending again would write everything anew, so the sheet
                // stays up until the user has read this.
                phase = .done(.failed(reason))
                return
            }
            // The preview stays up a moment, so the user sees it went.
            try? await Task.sleep(for: .milliseconds(phase == .done(.queued) ? 2200 : 700))
            done()
        }
    }

    private func progressed(_ sent: Int, of total: Int) {
        if case .sending = phase { phase = .sending(sent: sent, total: total) }
    }

    func dismiss() {
        try? FileManager.default.removeItem(at: folder)
        cancel()
    }

    /// For "Not Sent": the messages are already in Yapnest, so the request is
    /// complete rather than cancelled.
    func acknowledgeFailure() { done() }

    private func done() {
        try? FileManager.default.removeItem(at: folder)
        finish()
    }
}
