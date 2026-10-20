import SwiftUI
import YapnestKit

/// What a message offers to answer with (XEP-0439), under its bubble: its
/// actions, and for the newest message of the chat, its suggested replies. The
/// sender wrote every word of it, so it is drawn as plain text.
struct QuickResponseButtons: View {
    let row: MessageRow
    let model: ConversationModel

    var body: some View {
        if let offer = row.message.quickResponses, !row.message.isRetracted {
            let replies = row.content.showsResponses ? offer.responses : []
            if !offer.actions.isEmpty || !replies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !offer.actions.isEmpty {
                        WrappingLayout(spacing: 6) {
                            ForEach(offer.actions, id: \.id) { action in
                                ActionButton(
                                    label: action.label,
                                    isChosen: offer.chosen.contains(action.id),
                                    isSending: model.isChoosingAction(action.id, on: row.id),
                                ) { model.chooseAction(action.id, on: row.id) }
                            }
                        }
                    }
                    if !replies.isEmpty {
                        WrappingLayout(spacing: 6) {
                            ForEach(replies, id: \.value) { reply in
                                Button { model.sendQuickResponse(reply.value) } label: {
                                    Text(verbatim: reply.title).lineLimit(2)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ActionButton: View {
    let label: String
    let isChosen: Bool
    let isSending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView().controlSize(.small)
                } else if isChosen {
                    Image(systemName: "checkmark")
                }
                Text(verbatim: label).lineLimit(2)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isChosen || isSending)
    }
}

/// Lays its views out in lines, starting a new one when the next doesn't fit.
private struct WrappingLayout: Layout {
    var spacing: CGFloat

    /// The last arrangement, since the layout is asked for its size and then
    /// to place, at the same width, and measuring every button twice is the
    /// cost. The subviews or the spacing changing makes a new cache, so it
    /// never outlives what it measured.
    struct Cache {
        var width: CGFloat?
        var arrangement: (size: CGSize, origins: [CGPoint]) = (.zero, [])
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arranged(width: proposal.width ?? .infinity, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let placed = arranged(width: bounds.width, subviews: subviews, cache: &cache)
        for (view, origin) in zip(subviews, placed.origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
        }
    }

    private func arranged(width: CGFloat, subviews: Subviews, cache: inout Cache) -> (size: CGSize, origins: [CGPoint]) {
        if cache.width != width {
            cache.arrangement = arrange(width: width, subviews: subviews)
            cache.width = width
        }
        return cache.arrangement
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            // A button wider than the row is squeezed to it rather than spilling out.
            let size = view.sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}
