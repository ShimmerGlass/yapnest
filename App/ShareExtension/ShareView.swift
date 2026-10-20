import QuickLookThumbnailing
import SwiftUI
import YapnestKit

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Yapnest")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Once it's over, a cancel would report a share that went.
                    if !isDone {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.dismiss() }
                                .disabled(isSending)
                        }
                    }
                    if model.phase != .signedOut, !isDone {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") { model.send() }
                                .fontWeight(.semibold)
                                .disabled(!model.canSend)
                        }
                    }
                }
        }
        .errorAlert("Couldn't send", $model.failure)
    }

    private var isSending: Bool {
        if case .sending = model.phase { true } else { false }
    }

    private var isDone: Bool {
        if case .done = model.phase { true } else { false }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .signedOut:
            ContentUnavailableView(
                "Sign In First",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Open Yapnest and sign in, then share again."),
            )
        case .editing, .sending:
            form
        case .done(.failed(let reason)):
            ContentUnavailableView {
                Label("Not Sent", systemImage: "exclamationmark.circle.fill")
            } description: {
                Text("\(reason) The message is in Yapnest, where you can try again.")
            } actions: {
                Button("Done") { model.acknowledgeFailure() }
                    .buttonStyle(.borderedProminent)
            }
        case .done(let done):
            ContentUnavailableView(
                done == .sent ? "Sent" : "Saved",
                systemImage: done == .sent ? "checkmark.circle.fill" : "clock.badge.checkmark",
                description: done == .sent ? nil : Text("Yapnest will send it the next time it opens."),
            )
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            let visible = model.visibleRecipients
            List {
                Section {
                    SharedItemsPreview(items: model.items)
                    TextField("Add a message…", text: $model.comment, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("Send to") {
                    ForEach(visible) { item in
                        Button {
                            model.selection = item.conversation.peer
                        } label: {
                            RecipientRow(item: item, avatarURL: model.avatarURLs[item.id], isSelected: model.selection == item.conversation.peer)
                        }
                        .buttonStyle(.plain)
                        .id(item.conversation.peer)
                    }
                    if visible.isEmpty {
                        Text(model.query.isEmpty ? "No chats yet." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .disabled(isSending)
            .overlay { if case .sending(let sent, let total) = model.phase { SendingOverlay(sent: sent, total: total) } }
            .onChange(of: model.recipients.count) {
                if let selection = model.selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }
}

private struct RecipientRow: View {
    let item: ChatListItem
    let avatarURL: URL?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: item.title, seed: item.conversation.peer.description, imageURL: avatarURL, isGroup: item.groupChat != nil)
                .frame(width: 40, height: 40)
            Text(item.title)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SendingOverlay: View {
    let sent: Int
    let total: Int

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(total > 1 ? "Sending \(min(sent + 1, total)) of \(total)…" : "Sending…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Thumbnails of what's being shared, and its text or link.
private struct SharedItemsPreview: View {
    let items: [SharedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let files = items.filter { if case .text = $0.content { false } else { true } }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(files) { item in
                            switch item.content {
                            case .file(let file, let size): FileThumbnail(file: file, size: size)
                            case .unsupported(let name, let reason): UnsupportedTile(name: name, reason: reason)
                            case .text: EmptyView()
                            }
                        }
                    }
                }
            }
            ForEach(items) { item in
                if case .text(let text, let isLink) = item.content {
                    Label {
                        Text(text).lineLimit(3)
                    } icon: {
                        Image(systemName: isLink ? "link" : "text.alignleft")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            if items.isEmpty {
                Text("Nothing here can be sent.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FileThumbnail: View {
    let file: ShareContent.File
    let size: Int64
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(file.name ?? file.url.lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 72)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(file.name ?? file.url.lastPathComponent), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"))
        .task {
            // Quick Look decodes at the size asked for, so a big photo doesn't fill the extension's memory.
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 72, height: 72), scale: 3, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}

private struct UnsupportedTile: View {
    let name: String
    let reason: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .frame(width: 72, height: 72)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 72)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name): \(reason)"))
    }
}
