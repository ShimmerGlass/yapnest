import SwiftUI
import YapnestKit

/// What a long press, or on the Mac a right click, offers on a message:
/// reactions, replying and editing (not on the Mac, whose hover bar has
/// them), copying and deleting, a group moderator's removal of what others
/// wrote, links, sharing a file, and how the sender's device is trusted.
struct MessageMenu: View {
    let row: MessageRow
    let model: ConversationModel

    private var item: ConversationItem { row.item }
    private var message: Message { row.message }
    private var id: Int64 { row.id }

    var body: some View {
        // The Mac's hover bar already has the reactions, Reply and Edit, a
        // click away.
        if !Platform.isMac {
            reactions
            Button("Reply", systemImage: "arrowshape.turn.up.left") { model.reply(to: id) }
        }
        if message.direction == .outgoing, message.status == .failed {
            Button("Try Again", systemImage: "arrow.clockwise") { model.retry(id) }
        }
        if item.attachment?.state == .offered {
            Button("Decline", systemImage: "xmark", role: .destructive) { model.declineOffer(id) }
        }
        if item.attachment != nil {
            if let file = model.shareableFile(of: item) {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                if Platform.isMac, let name = item.attachment?.name {
                    Button("Save As…", systemImage: "square.and.arrow.down") { MacFileActions.saveAs(file, named: name) }
                }
            }
        } else if message.encryption != .omemoUndecryptable {
            // An undecryptable message's body is only the sender's fallback notice.
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
        }
        if let location = row.content.location {
            Button("Open in Maps", systemImage: "map") { location.openInMaps() }
        }
        links
        if message.direction == .outgoing {
            Section {
                if !Platform.isMac, model.canEdit(item) {
                    Button("Edit", systemImage: "pencil") { model.startEditing(id) }
                }
                Button("Delete for Everyone", systemImage: "trash", role: .destructive) { model.confirmRetraction(of: id) }
            }
        }
        if model.canModerate(message) {
            Section {
                Button("Remove for Everyone", systemImage: "trash", role: .destructive) { model.confirmModeration(of: id) }
            }
        }
        Section { security }
    }

    /// The quick reactions, in a row, with one more to pick any emoji.
    private var reactions: some View {
        let mine = Set(item.reactions.filter(\.includesMe).map(\.emoji))
        return ControlGroup {
            ForEach(model.quickReactions, id: \.self) { emoji in
                Toggle(isOn: Binding(get: { mine.contains(emoji) }, set: { _ in react(emoji) })) {
                    // Palette items only show their image, so the emoji is drawn into one.
                    Label { Text(emoji) } icon: { Image(uiImage: Self.emojiImage(emoji)) }
                }
                .accessibilityLabel(emoji)
            }
            Button("More Reactions", systemImage: "face.smiling") { model.emojiPicker = EmojiPickerRequest(id: id, anchor: nil) }
        }
        .controlGroupStyle(.palette)
        // Toggles in a palette keep the menu open by default, as if picking
        // several; a reaction is one choice, so the menu goes once it's made.
        .menuActionDismissBehavior(.enabled)
    }

    /// While the menu closes, the lifted bubble is drawn above the whole
    /// screen, so a chip added then shows under it until it lands. Reacting
    /// once it has lets the chip appear where it belongs.
    private func react(_ emoji: String) {
        Task {
            try? await Task.sleep(for: Self.menuDismissal)
            model.react(emoji, to: id)
        }
    }

    private static let menuDismissal: Duration = .milliseconds(450)

    @ViewBuilder
    private var links: some View {
        let urls = item.attachment == nil && message.encryption != .omemoUndecryptable ? LinkDetector.links(in: message.body).map(\.url) : []
        if urls.count == 1, let url = urls.first {
            Section { linkButtons(url) }
        } else if urls.count > 1 {
            Menu("Links", systemImage: "link") {
                ForEach(urls, id: \.self) { url in
                    Menu(url.absoluteString) { linkButtons(url) }
                }
            }
        }
    }

    @ViewBuilder
    private func linkButtons(_ url: URL) -> some View {
        Button("Open Link", systemImage: "safari") { model.open(link: url) }
        Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
    }

    /// How it was protected. The menu is as wide as the system makes it, so
    /// the device goes underneath.
    @ViewBuilder
    private var security: some View {
        let security = message.security
        let label = Label {
            Text(security.title)
            if let detail = security.detail { Text(detail) }
        } icon: {
            Image(systemName: security.symbol)
        }
        if let device = model.sendingDevice(of: message) {
            Menu {
                trust(device)
            } label: {
                label
            }
        } else {
            Button {} label: {
                label
            }
            .disabled(true)
        }
    }

    /// Its fingerprint to compare, then what to make of it.
    @ViewBuilder
    private func trust(_ device: OMEMODevice) -> some View {
        Section("Compare with the fingerprint on their device:") {
            Button(FingerprintText.grouped(device.fingerprint)) {}.disabled(true)
        }
        Section {
            trustChoice(.verified, "Mark as Verified", "checkmark.seal", for: device)
            trustChoice(.trusted, "Trust Without Verifying", "lock", for: device)
            trustChoice(.compromised, "Block Device", "xmark.octagon", for: device)
        }
        Button("All Devices…", systemImage: "list.bullet") { model.devicesSheet = device.jid }
    }

    private func trustChoice(_ trust: OMEMODevice.Trust, _ title: LocalizedStringKey, _ symbol: String, for device: OMEMODevice) -> some View {
        Toggle(isOn: Binding(get: { device.trust == trust }, set: { _ in model.setTrust(trust, for: device) })) {
            Label(title, systemImage: symbol)
        }
    }

    /// Drawn once each, not every time the menu is built.
    @MainActor private static var emojiImages: [String: UIImage] = [:]

    @MainActor private static func emojiImage(_ emoji: String) -> UIImage {
        if let drawn = emojiImages[emoji] { return drawn }
        let image = draw(emoji)
        emojiImages[emoji] = image
        return image
    }

    private static func draw(_ emoji: String) -> UIImage {
        let font = UIFont.systemFont(ofSize: 28)
        let text = emoji as NSString
        let size = text.size(withAttributes: [.font: font])
        return UIGraphicsImageRenderer(size: size).image { _ in
            text.draw(at: .zero, withAttributes: [.font: font])
        }.withRenderingMode(.alwaysOriginal)
    }
}
