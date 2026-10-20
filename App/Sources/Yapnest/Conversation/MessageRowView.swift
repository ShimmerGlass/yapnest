import SwiftUI
import YapnestKit

/// One row of the list: the bubble with its day header, unread divider and
/// reactions. Compared by the row's revision, so scrolling and unrelated
/// changes don't evaluate it again.
struct MessageRowView: View, Equatable {
    let row: MessageRow
    let model: ConversationModel

    nonisolated static func == (a: MessageRowView, b: MessageRowView) -> Bool { a.row == b.row }

    @State private var swipe: CGFloat = 0
    /// The pointer is on the row or on its toolbar, which is partly outside it.
    @State private var rowHovered = false
    @State private var barHovered = false
    /// The bar's More menu is open, with the pointer in it. Catalyst tells
    /// the menu's contents when they appear but not when they go, so this is
    /// cleared when the pointer next enters this row, or moves anywhere in
    /// the conversation (`hoverMenuClosed`). Another row taking `hoveredRow`
    /// hides the bar without it.
    @State private var menuOpen = false
    /// Where across the row the pointer came in, which the hover bar is
    /// centred on. Set on entering only: a bar that followed the pointer
    /// would move away from the button it was heading for.
    @State private var pointerX: CGFloat = 0
    /// Room under the bubble for the reactions chip, which grows with Dynamic Type.
    @ScaledMetric private var chipClearance: CGFloat = 22

    private static let swipeThreshold: CGFloat = 60
    /// How far the hover bar comes down over the bubble's top edge, so it
    /// reads as belonging to that message rather than the one above.
    private static let barOverlap: CGFloat = 10

    private var showsHoverBar: Bool {
        Platform.isMac && (rowHovered || barHovered || menuOpen) && model.hoveredRow == row.id
    }

    private var reactionTooltip: String {
        model.reactionChoices(for: row.id).map { "\($0.emoji) \($0.names)" }.joined(separator: "\n")
    }

    var body: some View {
        let layout = row.content.layout
        VStack(spacing: 8) {
            if let dayHeader = layout.dayHeader {
                Text(dayHeader)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
            }
            if layout.showsUnreadDivider {
                UnreadDivider()
            }
            switch row.content.kind {
            case .call(let call): CallRowView(row: row, call: call, model: model)
            case .bubble:
                bubbleRow
                QuickResponseButtons(row: row, model: model)
            }
        }
        .padding(.top, layout.joinsPrevious ? 2 : 8)
        .background { AnchorProbe(id: row.id, model: model) }
        .accessibilityElement(children: .contain)
        // The hover bar overlaps the row above, which the stack draws first.
        .zIndex(showsHoverBar ? 1 : 0)
    }

    /// The Mac's hover bar, on the bubble's top edge under the pointer.
    private var hoverBar: some View {
        HoverBarLayout(centerX: pointerX, overlap: Self.barOverlap, margin: 12) {
            MessageHoverBar(row: row, model: model, onHover: { barHovered = $0 }, onMenuOpen: {
                menuOpen = true
                model.hoverMenuOpen = true
            })
        }
    }

    private var bubbleRow: some View {
        let reactions = row.item.reactions
        return RowBubble(row: row, model: model)
            .padding(.bottom, reactions.isEmpty ? 0 : chipClearance)
            .overlay(alignment: row.isOutgoing ? .bottomLeading : .bottomTrailing) {
                if !reactions.isEmpty {
                    // Tapping the chip opens the list of who reacted; the Mac
                    // gets the same list on hover.
                    ReactionsChip(reactions: reactions, who: Platform.isMac ? reactionTooltip : nil) { model.showReactions(for: row.id) }
                        .padding(.horizontal, 8)
                }
            }
            .modifier(FlashEffect(id: row.id, model: model))
            .offset(x: swipe)
            .background(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(.secondary)
                    .opacity(min(1, swipe / Self.swipeThreshold))
                    .offset(x: swipe - 12 - 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: row.isOutgoing ? .trailing : .leading)
            .overlay(alignment: .top) {
                if showsHoverBar, !row.message.isRetracted {
                    hoverBar
                }
            }
            .background { if Platform.isMac, rowHovered { Color.primary.opacity(0.04) } }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // A row that missed its end (around the More menu) is still
                    // hovered, so also enter when another row has the bar.
                    guard !rowHovered || (Platform.isMac && model.hoveredRow != row.id) else { return }
                    rowHovered = true
                    // An iPad's pointer hovers too, but has no bar to show.
                    if Platform.isMac {
                        pointerX = location.x
                        menuOpen = false
                        model.hoveredRow = row.id
                    }
                case .ended:
                    rowHovered = false
                }
            }
            .modifier(ClearsHoverWhenMenuCloses(conversation: model, menuOpen: $menuOpen, rowHovered: $rowHovered))
            .gesture(SwipeToReply(offset: $swipe, threshold: Self.swipeThreshold) { model.reply(to: row.id) })
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.content.accessibilityLabel)
            .accessibilityActions {
                if row.isOutgoing && row.message.status == .failed {
                    Button("Show error") { model.explainFailure(of: row.id) }
                } else if row.content.attachment != nil {
                    Button("Open") { model.attachmentTapped(row.id) }
                } else if let location = row.content.location {
                    Button("Open in Maps") { location.openInMaps() }
                }
                if row.content.text?.isCollapsed == true {
                    Button("Show more") { model.showWholeBody(of: row.id) }
                }
                if row.item.quote != nil {
                    Button("Go to quoted message") { model.scrollToQuoted(of: row.id) }
                }
                if !row.item.reactions.isEmpty {
                    Button("Show reactions") { model.showReactions(for: row.id) }
                }
                if let link = row.message.link.flatMap(URL.init(string:)) {
                    Button("Open link") { model.open(link: link) }
                }
                // On every platform. On the Mac they are the only way VoiceOver reaches
                // these, as the menu leaves them to the hover bar.
                if !row.message.isRetracted {
                    Button("Add Reaction") { model.emojiPicker = EmojiPickerRequest(id: row.id, anchor: nil) }
                    Button("Reply") { model.reply(to: row.id) }
                    if model.canEdit(row.item) {
                        Button("Edit") { model.startEditing(row.id) }
                    }
                }
            }
    }
}

private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            line
            Text("Unread messages")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unread messages")
    }

    private var line: some View {
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
    }
}

/// Emphasises the message that was just jumped to. A view of its own, so the
/// rows don't all depend on which one it is.
/// Listens for the hover menu closing, on the Mac only: on iOS it never
/// posts, and every row would still hold a subscription to it.
private struct ClearsHoverWhenMenuCloses: ViewModifier {
    let conversation: ConversationModel
    @Binding var menuOpen: Bool
    @Binding var rowHovered: Bool

    func body(content: Content) -> some View {
        if Platform.isMac {
            content.onReceive(NotificationCenter.default.publisher(for: .hoverMenuClosed, object: conversation)) { _ in
                menuOpen = false
                // Clears a hover tint whose end was missed; the next move over
                // the row enters it again.
                rowHovered = false
            }
        } else {
            content
        }
    }
}

private struct FlashEffect: ViewModifier {
    let id: Int64
    let model: ConversationModel

    func body(content: Content) -> some View {
        content
            .scaleEffect(model.flashID == id ? 1.04 : 1)
            .animation(.easeOut(duration: 0.18), value: model.flashID == id)
    }
}

/// Reports where the topmost message on screen is, while it is that, so
/// older messages can be inserted above it without it moving.
private struct AnchorProbe: View {
    let id: Int64
    let model: ConversationModel

    var body: some View {
        if model.anchorID == id {
            Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("messageList")) } action: { frame in
                model.anchorMeasured(id: id, frame: frame)
                #if DEBUG
                model.recorder?.update { $0.anchorMeasured(id: id, minY: frame.minY, at: ProcessInfo.processInfo.systemUptime) }
                #endif
            }
        }
    }
}

/// Dragging a message to the right to reply to it, with a tick as it passes
/// the point where letting go will. Only a mostly-horizontal drag starts it,
/// so scrolling and the back swipe still work.
struct SwipeToReply: UIGestureRecognizerRepresentable {
    @Binding var offset: CGFloat
    let threshold: CGFloat
    let onReply: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .changed:
            let dx = max(0, pan.translation(in: pan.view).x)
            // Rubber-band past the threshold.
            offset = dx < threshold ? dx : threshold + (dx - threshold) * 0.3
            let passed = dx >= threshold
            if passed && !context.coordinator.passed {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            context.coordinator.passed = passed
        case .ended, .cancelled, .failed:
            if pan.state == .ended, context.coordinator.passed { onReply() }
            context.coordinator.passed = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var passed = false

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return true }
            #if targetEnvironment(macCatalyst)
            // A drag across the words selects them.
            // The hit view can be one of the text view's private subviews, so walk up.
            var hit = pan.view?.hitTest(pan.location(in: pan.view), with: nil)
            while let view = hit, view !== pan.view {
                if view is UITextView { return false }
                hit = view.superview
            }
            #endif
            let velocity = pan.velocity(in: pan.view)
            // Rightward and mostly horizontal, away from the screen's edge.
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 2 && pan.location(in: nil).x > 30
        }
    }
}

extension Date {
    func dayHeaderFormatted(now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(self, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
        return formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// A row's bubble with its context menu.
///
/// In the upside-down list, a menu on the bubble itself lifts it mirrored and
/// lets it down mirrored, and a preview given to it is shown mirrored on the
/// way up, and as a box wider than the bubble. The system places the lift from
/// the views the menu's view sits in, and sees the list's mirror there but
/// not the row's mirroring back, which SwiftUI draws itself. So on iOS the
/// bubble is hosted in a view of its own, where the row's flip is a UIKit
/// transform, and the lift is as it is in a list that isn't mirrored.
private struct RowBubble: View {
    let row: MessageRow
    let model: ConversationModel

    var body: some View {
        if model.isFlipped {
            HostedView(row: row) { width in
                MessageBubble(row: row, model: model, offeredWidth: width)
                    .contextMenu { menu }
                    // A hosting controller of its own doesn't get the app's
                    // handler, which keeps `xmpp:` links in the app.
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme?.lowercased() == "xmpp" else { return .systemAction }
                        model.open(link: url)
                        return .handled
                    })
            }
        } else {
            MessageBubble(row: row, model: model)
                .contextMenu { menu }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !row.message.isRetracted {
            MessageMenu(row: row, model: model)
        }
    }
}

/// SwiftUI content in a hosting controller of its own, which is sized by
/// the width it's offered. The content is told that width: a bubble's width
/// follows it, and isn't the same when offered its own size back, which is
/// what a hosting controller does.
private struct HostedView<Content: View>: UIViewControllerRepresentable {
    /// What the content shows, which changes with the row. A closure can't be
    /// compared, so SwiftUI takes every pass over the row for a change.
    let row: MessageRow
    let content: (CGFloat?) -> Content

    init(row: MessageRow, @ViewBuilder content: @escaping (CGFloat?) -> Content) {
        self.row = row
        self.content = content
    }

    final class Coordinator {
        var width: CGFloat?
        var row: MessageRow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        context.coordinator.row = row
        let host = UIHostingController(rootView: content(nil))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        // Setting the root view invalidates the hosted graph and the row's
        // size, so it is left alone when nothing it shows has changed.
        guard context.coordinator.row != row else { return }
        context.coordinator.row = row
        host.rootView = content(context.coordinator.width)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController host: UIHostingController<Content>, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        if width != context.coordinator.width {
            context.coordinator.width = width
            host.rootView = content(width)
        }
        return host.sizeThatFits(in: CGSize(width: width ?? 10_000, height: 10_000))
    }
}

/// Places the hover bar centred on the pointer, kept inside the row, and
/// above the row's top edge but for `overlap`. It takes no room itself, so
/// the row's height doesn't change with the pointer.
private struct HoverBarLayout: Layout {
    let centerX: CGFloat
    let overlap: CGFloat
    let margin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bar = subviews.first else { return }
        let size = bar.sizeThatFits(.unspecified)
        let x = min(max(bounds.minX + centerX - size.width / 2, bounds.minX + margin), bounds.maxX - margin - size.width)
        bar.place(at: CGPoint(x: x, y: bounds.minY - size.height + overlap), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
