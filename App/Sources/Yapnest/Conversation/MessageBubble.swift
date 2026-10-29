import SwiftUI
import YapnestKit

/// A message's bubble: the parts that are present stacked, with the footer
/// at the trailing edge.
struct MessageBubble: View {
    let row: MessageRow
    let model: ConversationModel
    /// The width the row offers, when it can't be had from the layout: a bubble
    /// hosted on its own is offered what it came to last time.
    var offeredWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    private var content: MessageRow.Content { row.content }
    private var message: Message { row.message }
    private var isOutgoing: Bool { row.isOutgoing }
    private var isFailed: Bool { isOutgoing && message.status == .failed }
    /// The message, or an edit or deletion of it, never reached the others; a tap says why.
    private var needsExplaining: Bool { message.deliveryProblem != nil }

    var body: some View {
        if content.isBare {
            bare
        } else {
            bubble
        }
    }

    /// Emoji alone, as Signal draws them: no bubble, with the footer as a
    /// small caption under them on their sender's side. Everything is the
    /// same size whatever the row's state, so its height doesn't change.
    private var bare: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 0) {
            if let name = content.senderName {
                Text(name)
                    .font(.footnote.bold())
                    .foregroundStyle(content.senderColor ?? .primary)
            }
            if let segment = content.text?.segments.first {
                Text(segment.text)
                    .foregroundStyle(.primary)
            }
            BubbleFooter(message: message, time: content.time, security: content.security, isOutgoing: isOutgoing, isBare: true)
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if needsExplaining { model.explainFailure(of: row.id) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        let foreground: Color = isOutgoing ? .white : .primary
        let showsMedia = content.location != nil || (content.attachment.map { $0.attachment.isImage || $0.attachment.isVideo } ?? false)
        BubbleLayout(fillsWidth: content.preview.hasCard || showsMedia, offeredWidth: offeredWidth) {
            if let name = content.senderName {
                Text(name)
                    .font(.footnote.bold())
                    .foregroundStyle(content.senderColor ?? .primary)
            }
            if content.item.quote != nil {
                QuotePreview(author: content.quoteAuthor, text: content.quoteText, isOutgoing: isOutgoing) {
                    model.scrollToQuoted(of: row.id)
                }
            }
            if let attachment = content.attachment {
                AttachmentContent(
                    display: attachment, id: row.id, isOutgoing: isOutgoing, transfers: model.transfers,
                    // A failed photo has nothing to open, so a tap on it explains the failure like the footer does.
                    onTap: { if isFailed { model.explainFailure(of: row.id) } else { model.attachmentTapped(row.id) } },
                    isFailed: isFailed,
                    play: { url, fraction in model.playVoice(id: row.id, file: url, from: fraction) },
                )
            }
            if let location = content.location {
                LocationCard(location: location)
                    .onTapGesture { location.openInMaps() }
                    .linkPointer()
                    .bubbleSpacingAfter(6)
            }
            if content.preview.hasCard {
                LinkPreviewCard(display: content.preview, isOutgoing: isOutgoing)
                    .onTapGesture {
                        if let link = message.link.flatMap(URL.init(string:)) { model.open(link: link) }
                    }
                    .linkPointer()
                    .bubbleSpacingAfter(6)
            }
            if let text = content.text {
                // The bold action reads as part of the text when it sits tight under it.
                MessageBody(text: text, isOutgoing: isOutgoing, isRetracted: message.isRetracted, openLink: { model.open(link: $0) })
                    .bubbleSpacingAfter(hasActions ? 10 : BubbleSpacingKey.defaultValue)
            }
            footer(foreground: foreground)
                .bubbleFooter()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
        .foregroundStyle(foreground)
        .tint(isOutgoing ? .white : .accentColor)
        .background {
            let shape = UnevenRoundedRectangle(cornerRadii: Self.corners(isOutgoing: isOutgoing, layout: content.layout))
            // A faint light from above: the fill darkens a little towards the
            // bottom, and the edge catches the light at the top and falls
            // into shade at the bottom. Strong enough only to give the bubble
            // some depth; no shadow, which would cost every row a blur.
            let fill = isOutgoing ? Color.accentColor : Color(.secondarySystemBackground)
            // The edge is the gradient left showing around an inset fill,
            // not a gradient stroke: SwiftUI draws a gradient stroke in
            // software on the main thread, for every bubble as it appears,
            // but fills a plain shape with one on the GPU.
            shape
                .fill(fill)
                .overlay { shape.fill(bubbleEdge) }
                .overlay { shape.inset(by: 1).fill(fill) }
                .overlay { shape.fill(bubbleShading) }
        }
        .contentShape(.contextMenuPreview, UnevenRoundedRectangle(cornerRadii: Self.corners(isOutgoing: isOutgoing, layout: content.layout)))
        .onTapGesture {
            if needsExplaining { model.explainFailure(of: row.id) }
        }
    }

    /// Lighter at the top and darker at the bottom, by less on the dark
    /// background, where the same change stands out more.
    private var bubbleShading: LinearGradient {
        let isDark = colorScheme == .dark
        return LinearGradient(colors: [.white.opacity(isDark ? 0.02 : 0.05), .black.opacity(isDark ? 0.035 : 0.04)], startPoint: .top, endPoint: .bottom)
    }

    private var bubbleEdge: LinearGradient {
        let isDark = colorScheme == .dark
        let light = Color.white.opacity(isOutgoing ? (isDark ? 0.14 : 0.2) : isDark ? 0.06 : 0.6)
        let shade = Color.black.opacity(isOutgoing ? (isDark ? 0.05 : 0.08) : isDark ? 0.12 : 0.05)
        return LinearGradient(stops: [.init(color: light, location: 0), .init(color: .clear, location: 0.45), .init(color: shade, location: 1)], startPoint: .top, endPoint: .bottom)
    }

    private var showsMore: Bool { content.text?.isCollapsed == true }

    private var hasActions: Bool { showsMore || asksForPreview }

    private var asksForPreview: Bool {
        if case .ask = content.preview { return true }
        return false
    }

    /// The footer, with the bubble's actions on the same line when it has any:
    /// they sit at the leading edge and the footer at the trailing one. If
    /// they don't fit side by side, the footer drops to its own line below.
    @ViewBuilder
    private func footer(foreground: Color) -> some View {
        let footer = BubbleFooter(message: message, time: content.time, security: content.security, isOutgoing: isOutgoing)
        if hasActions {
            let actions = HStack(spacing: 12) {
                if showsMore {
                    Button("Show more") { model.showWholeBody(of: row.id) }
                        .modifier(FooterAction())
                }
                if asksForPreview {
                    Button { model.askForLinkPreviews() } label: {
                        Label("Show link preview", systemImage: "link")
                            .foregroundStyle(foreground.opacity(0.85))
                    }
                    .modifier(FooterAction())
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    actions
                    Spacer(minLength: 12)
                    footer
                }
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: 0) {
                        actions
                        Spacer(minLength: 0)
                    }
                    footer
                }
            }
        } else {
            footer
        }
    }

    /// The tighter corners on their sender's side for grouped messages, as in Signal.
    static func corners(isOutgoing: Bool, layout: MessageRow.Layout) -> RectangleCornerRadii {
        let round: CGFloat = 14, tight: CGFloat = 4
        if isOutgoing {
            return .init(topLeading: round, bottomLeading: round, bottomTrailing: layout.joinsNext ? tight : round, topTrailing: layout.joinsPrevious ? tight : round)
        }
        return .init(topLeading: layout.joinsPrevious ? tight : round, bottomLeading: layout.joinsNext ? tight : round, bottomTrailing: round, topTrailing: round)
    }
}

/// A steady color per sender, so a group's voices are easy to tell apart.
enum SenderColor {
    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .green, .brown, .cyan]

    static func color(for author: Author) -> Color {
        let key = author.nick ?? author.jid.description
        return palette[Int(UInt(bitPattern: key.stableHash) % UInt(palette.count))]
    }
}

/// The message's words, a stretch at a time, with a bar down the side of
/// quoted lines.
struct MessageBody: View {
    let text: RenderedText
    let isOutgoing: Bool
    let isRetracted: Bool
    let openLink: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(text.segments) { segment in
                boxed(segment)
                    .opacity(isRetracted ? 0.8 : 1)
                    .padding(.leading, MessageText.quoteIndent * CGFloat(segment.depth))
                    .overlay(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            ForEach(0..<segment.depth, id: \.self) { level in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .frame(width: 3)
                                    .padding(.leading, MessageText.quoteIndent * CGFloat(level))
                            }
                        }
                        .opacity(0.5)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Code sits in a box. Other text gets no extra modifiers: they'd change
    /// the layout the lazy list measures, for rows that have no code.
    @ViewBuilder
    private func boxed(_ segment: RenderedText.Segment) -> some View {
        if segment.isPreformatted {
            segmentText(segment)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.foreground.opacity(0.1)))
                .padding(.vertical, 2)
        } else {
            segmentText(segment)
        }
    }

    /// Selectable on the Mac, where there's a pointer to select with. On the
    /// iPhone a long press opens the message's menu instead.
    @ViewBuilder
    private func segmentText(_ segment: RenderedText.Segment) -> some View {
        #if targetEnvironment(macCatalyst)
        if let native = segment.native {
            SelectableText(text: native, isOutgoing: isOutgoing, openLink: openLink)
        } else {
            Text(segment.text)
        }
        #else
        Text(segment.text)
        #endif
    }
}

/// A text button on the footer's line. Its hit area reaches past the line, as
/// the padding is taken back out of the layout, so the line stays footer-high.
private struct FooterAction: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote.bold())
            .lineLimit(1)
            .fixedSize()
            .buttonStyle(.plain)
            .linkPointer()
            .padding(.vertical, 8)
            // A plain button only takes touches where its label draws.
            .contentShape(Rectangle())
            .padding(.vertical, -8)
    }
}

/// The time, with the lock for how it was protected and, on our messages,
/// how far it got.
struct BubbleFooter: View {
    let message: Message
    let time: String
    let security: Message.Security
    let isOutgoing: Bool
    /// Drawn on the chat's background, not on a bubble: the colors made for
    /// the bubble's fill would vanish or clash there.
    var isBare = false

    private var problem: Message.DeliveryProblem? { message.deliveryProblem }

    private var caption: String {
        switch problem {
        case .notSent: String(localized: "Not sent · Tap for details")
        case let problem?: String(localized: "\(problem.title) · Retry")
        case nil: message.editedAt != nil ? String(localized: "Edited · \(time)") : time
        }
    }

    private var onAccent: Bool { isOutgoing && !isBare }
    private var secondary: Color { isBare ? .secondary : (onAccent ? Color.white : Color.primary).opacity(0.7) }

    var body: some View {
        HStack(spacing: 4) {
            if !message.isRetracted {
                lock
            }
            Text(caption)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(secondary)
            if isOutgoing {
                statusIcon
                    .frame(width: 18, height: 12, alignment: .leading)
            }
        }
    }

    /// Red and orange vanish on our purple bubbles, so there the symbol is
    /// white on a disc of the color. The disc's padding is cancelled out to
    /// leave the footer's size alone.
    @ViewBuilder
    private var lock: some View {
        let symbol = Image(systemName: security.symbol).font(.system(size: 10))
        Group {
            if onAccent, let color = security.color {
                symbol
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(color))
                    // Not taller than the footer's text, but as wide as it
                    // draws, so it doesn't run into the time beside it.
                    .padding(.vertical, -3)
            } else {
                symbol.foregroundStyle(security.color ?? secondary)
            }
        }
        .accessibilityLabel(security.fullTitle)
        .padding(.trailing, -1)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if problem != nil {
            // Drawn as a symbol rather than the shared image, to size it with the footer.
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        } else if let image = message.status.indicator {
            Image(uiImage: image)
                .renderingMode(.template)
                .foregroundStyle(isBare ? Color.secondary : Color.white.opacity(0.7))
        }
    }
}

/// The replied-to message shown at the top of a bubble.
struct QuotePreview: View {
    let author: String
    /// Already trimmed of the blank lines around it.
    let text: String
    let isOutgoing: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The leading slice of a wider rounded rectangle, so the bar's
            // corners follow the card's curve without clipping the card, which
            // would be an offscreen pass. This clip is on a single layer.
            RoundedRectangle(cornerRadius: 8)
                .fill(isOutgoing ? Color.white : Color.accentColor)
                .frame(width: 16)
                .frame(width: 4, alignment: .leading)
                .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(author)
                    .font(.footnote.bold())
                Text(text.isEmpty ? String(localized: "Original message not found") : text)
                    .font(.footnote)
                    .lineLimit(3)
                    .opacity(0.85)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(isOutgoing ? Color.white.opacity(0.2) : Color(.systemFill)))
        .onTapGesture(perform: onTap)
        .linkPointer()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The reactions button hanging off a bubble's bottom edge.
struct ReactionsChip: View {
    let reactions: [ConversationItem.ReactionGroup]
    /// Who reacted with each emoji, shown as a tooltip. Empty shows nothing.
    var who: String?
    let onTap: () -> Void

    /// The chip's height at the default text size, growing with Dynamic Type.
    @ScaledMetric private var height: CGFloat = Platform.isMac ? 34 : 28

    private var isPending: Bool { reactions.contains(where: \.isPending) }
    private var isFailed: Bool { reactions.contains(where: \.isFailed) }

    var body: some View {
        let total = reactions.reduce(0) { $0 + $1.senders.count }
        let emojis = reactions.prefix(3).map(\.emoji).joined()
        Button(action: onTap) {
            Text(total > 1 ? "\(emojis) \(total)" : emojis)
                // The Mac's footnote is too small to tell one emoji from another.
                .font(Platform.isMac ? .title3 : .footnote)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(minHeight: height)
                // The shadow is part of the capsule's fill: a layer shadow on
                // the chip was an offscreen pass per chip. Our own reaction's
                // tint sits on the opaque fill, so the bubble under the chip
                // doesn't show through it.
                .background {
                    Capsule().fill(Color(.tertiarySystemBackground).shadow(.drop(color: .black.opacity(0.12), radius: 2, y: 1)))
                    if reactions.contains(where: \.includesMe) {
                        Capsule().fill(Color.accentColor.opacity(0.25))
                    }
                }
                // The dots of the sending icon: ours isn't acknowledged yet.
                .overlay {
                    if isFailed {
                        // Ours never reached the other side; a tap says why.
                        Capsule().strokeBorder(Color.red, lineWidth: 1.25)
                    } else if isPending {
                        Capsule().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [0, 3.5]))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(who ?? "")
        .accessibilityLabel(reactions.map { "\($0.emoji) \($0.senders.count)" }.joined(separator: ", ") + (isFailed ? ", " + String(localized: "Not delivered") : isPending ? ", " + String(localized: "Sending") : ""))
    }
}

// MARK: Layout

fileprivate struct BubbleFooterKey: LayoutValueKey {
    static let defaultValue = false
}

fileprivate struct BubbleSpacingKey: LayoutValueKey {
    static let defaultValue: CGFloat = 4
}

/// Stacks a bubble's parts. The bubble is as wide as its widest part, up to
/// 78% of the row; with a picture or a preview card it takes that whole
/// width, so its shape doesn't depend on how the text happens to wrap. The
/// footer sits at the trailing edge.
private struct BubbleLayout: Layout {
    var fillsWidth: Bool
    var offeredWidth: CGFloat?

    /// A bubble's content is never narrower than this, so "ok" and a lone
    /// emoji with their time make a comfortable rounded shape rather than a
    /// pill hugging the footer. Wider than the footer on its own, which is
    /// about 50 to 70 points.
    private static let minimumContentWidth: CGFloat = 76

    /// What the row leaves for the bubble's contents: its width less the
    /// margins, then the bubble's own padding.
    private func contentWidth(_ proposal: ProposedViewSize) -> CGFloat {
        // The row holds 12pt margins and the bubble 12pt of padding.
        let row = (offeredWidth ?? proposal.width ?? 400) + 48
        let bubble = min(row * 0.78, row - 60)
        return max(0, (fillsWidth ? min(bubble, MediaLimits.maxBubbleWidth) : bubble) - 24)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = contentWidth(proposal)
        // Bubbles that fill their width take the limit anyway, and measuring
        // their pictures and cards unconstrained is the costly part.
        let width: CGFloat
        if fillsWidth {
            width = limit
        } else {
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = min(limit, max(Self.minimumContentWidth, widest))
        }
        return CGSize(width: width, height: stack(width: width, subviews: subviews, place: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        stack(width: bounds.width, subviews: subviews, place: bounds)
    }

    @discardableResult
    private func stack(width: CGFloat, subviews: Subviews, place bounds: CGRect?) -> CGFloat {
        var y: CGFloat = 0
        var previousSpacing: CGFloat = 0
        var first = true
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            if !first { y += previousSpacing }
            first = false
            if let bounds {
                let isFooter = view[BubbleFooterKey.self]
                let x = isFooter ? bounds.maxX - min(size.width, width) : bounds.minX
                view.place(at: CGPoint(x: x, y: bounds.minY + y), anchor: .topLeading, proposal: .init(width: isFooter ? size.width : width, height: size.height))
            }
            y += size.height
            previousSpacing = view[BubbleSpacingKey.self]
        }
        return y
    }
}

extension View {
    /// The pointing hand over something that opens on a click. With a
    /// trackpad on the iPad it's the pointer's usual highlight, which the Mac
    /// idiom doesn't draw, so there the cursor is set through AppKit.
    /// SwiftUI's `pointerStyle(.link)` isn't available on iOS or Catalyst.
    @ViewBuilder
    func linkPointer() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(LinkPointer())
        #else
        hoverEffect(.highlight)
        #endif
    }
}

private extension View {
    func bubbleFooter() -> some View {
        layoutValue(key: BubbleFooterKey.self, value: true)
    }

    func bubbleSpacingAfter(_ spacing: CGFloat) -> some View {
        layoutValue(key: BubbleSpacingKey.self, value: spacing)
    }
}

extension Message.DeliveryProblem {
    /// What a prompt about it is called, and the footer says before "Retry".
    var title: String {
        switch self {
        case .notSent: String(localized: "Message not sent")
        case .editNotDelivered: String(localized: "Edit not delivered")
        case .deletionNotDelivered: String(localized: "Not deleted for everyone")
        }
    }
}
