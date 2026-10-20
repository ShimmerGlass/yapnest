import SwiftUI
import YapnestKit

/// The quick actions the Mac shows over a message while the pointer is on it.
/// Right click has all of them and more; this saves the trip for the common
/// ones. It's drawn as an overlay, as the row's height can't change with the
/// pointer.
struct MessageHoverBar: View {
    let row: MessageRow
    let model: ConversationModel
    /// Reports the pointer being on the bar, which sits partly outside the row.
    let onHover: (Bool) -> Void
    /// Reports the More menu opening. The pointer is then in the menu, off
    /// the bar, and the bar has to stay for the menu to stay. Catalyst never
    /// says when the menu closes.
    let onMenuOpen: () -> Void

    /// The quick reactions as they were when the bar appeared. A pick reorders
    /// the model's list, and the emoji under the pointer would jump to another
    /// slot; the next hover makes a new bar, with the new order.
    @State private var quickReactions: [String]
    /// The More Reactions button, in the window, for the character viewer to
    /// open by. It follows the button through every scroll frame but is read
    /// only on a click, so it's kept where a write doesn't redraw the bar.
    @State private var pickerButton = FrameBox()

    private final class FrameBox {
        var frame: CGRect?
    }

    init(row: MessageRow, model: ConversationModel, onHover: @escaping (Bool) -> Void, onMenuOpen: @escaping () -> Void) {
        self.row = row
        self.model = model
        self.onHover = onHover
        self.onMenuOpen = onMenuOpen
        _quickReactions = State(initialValue: Array(model.quickReactions.prefix(3)))
    }

    var body: some View {
        let mine = Set(row.item.reactions.filter(\.includesMe).map(\.emoji))
        bar(mine: mine)
            .onHover(perform: onHover)
            .accessibilityHidden(true)
    }

    private func bar(mine: Set<String>) -> some View {
        HStack(spacing: 2) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button { model.react(emoji, to: row.id) } label: {
                    Text(emoji)
                        .frame(width: 28, height: 28)
                        .background(mine.contains(emoji) ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                }
                .help(mine.contains(emoji) ? "Remove \(emoji)" : "React with \(emoji)")
            }
            icon("face.smiling", help: "More Reactions") {
                model.emojiPicker = EmojiPickerRequest(id: row.id, anchor: pickerButton.frame)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pickerButton.frame = $0 }
            icon("arrowshape.turn.up.left", help: "Reply") { model.reply(to: row.id) }
            if model.canEdit(row.item) {
                icon("pencil", help: "Edit") { model.startEditing(row.id) }
            }
            Menu {
                MessageMenu(row: row, model: model)
                    .onAppear(perform: onMenuOpen)
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .help("More")
        }
        .buttonStyle(.plain)
        .padding(2)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private func icon(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
        }
        .help(help)
    }
}
