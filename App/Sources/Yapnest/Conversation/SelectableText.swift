import SwiftUI

/// How a stretch of message text looks, shared by the text view that selects
/// it and the plain drawing that stands in until one is needed.
enum SelectableTextStyle {
    static func textColor(isOutgoing: Bool) -> UIColor { isOutgoing ? .white : .label }

    /// The accent's text in a received bubble, as links. The accent itself is
    /// 3.2:1 on the grey bubble in dark mode, under WCAG AA's 4.5:1, so this
    /// keeps it in light mode, lightens it in dark, and goes further for
    /// Increase Contrast. Our own bubbles are filled with the accent, which
    /// stays as it is.
    static let receivedAccent = UIColor(named: "ReceivedBubbleAccent") ?? UIColor(Color.accentColor)

    /// The footer's time, ticks and "Not sent" on our own bubbles. Full white:
    /// at 70% it was 3.5:1 on the accent.
    static let footerOnAccent = UIColor.white

    static func linkAttributes(isOutgoing: Bool) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: isOutgoing ? UIColor.white : receivedAccent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    /// The text with the colours a text view gives it: the default on every
    /// run, and the link style on links. The links themselves go: drawn, a
    /// run that is a link takes the system's blue over its own colour.
    static func displayText(_ text: NSAttributedString, isOutgoing: Bool) -> NSAttributedString {
        let display = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: display.length)
        display.addAttribute(.foregroundColor, value: textColor(isOutgoing: isOutgoing), range: whole)
        let link = linkAttributes(isOutgoing: isOutgoing)
        display.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            display.removeAttribute(.link, range: range)
            display.addAttributes(link, range: range)
        }
        return display
    }
}

#if targetEnvironment(macCatalyst)

/// AppKit's pointing-hand cursor, which UIKit has no way to ask for. Each
/// instance pushes it once while it's wanted and pops it when it isn't, or
/// when it goes away, so the cursor can't be left stuck as a hand.
final class HandCursor {
    private var isShown = false

    func update(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { MacCursor.push(MacCursor.pointingHand) } else { MacCursor.pop() }
    }

    deinit { update(false) }
}

/// One stretch of a message's text that the Mac can select and copy from,
/// which SwiftUI's `Text` can't be. It sizes like `Text` does: as wide as its
/// words, up to the width it's offered.
///
/// A text view costs a lot to make and lay out, and a long chat builds many
/// rows as it scrolls, so the words are drawn plainly until the pointer is on
/// the bubble (`isActive`). The text view then takes over and stays, so a
/// selection outlives the pointer.
struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    let isOutgoing: Bool
    let isActive: Bool
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SelectableTextContainer {
        let view = SelectableTextContainer()
        view.coordinator = context.coordinator
        // The view isn't sized by its content, so a lower priority lets the
        // layout squeeze it rather than SwiftUI asking for its intrinsic width.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: SelectableTextContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.openLink = openLink
        if coordinator.text != text {
            coordinator.text = text
            view.set(text: text, isOutgoing: isOutgoing)
        }
        if isActive { view.activate() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextContainer, context: Context) -> CGSize? {
        // Measured here from the words, as the view may not hold them yet.
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100_000
        // The lazy stack asks again for every row it lays out, and measuring
        // is a full text layout.
        let coordinator = context.coordinator
        if coordinator.measuredText != text {
            coordinator.measuredText = text
            coordinator.sizes = [:]
        }
        if let known = coordinator.sizes[offered] { return known }
        let options = SelectableTextContainer.drawingOptions
        let wanted = text.boundingRect(with: CGSize(width: offered, height: .greatestFiniteMagnitude), options: options, context: nil)
        // A point of slack, so rounding can't wrap the last word of a line
        // that just fits.
        let width = min(offered, ceil(wanted.width) + 1)
        let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options, context: nil).height)
        let size = CGSize(width: width, height: height)
        if coordinator.sizes.count >= 8 { coordinator.sizes = [:] }
        coordinator.sizes[offered] = size
        return size
    }

    static func dismantleUIView(_ view: SelectableTextContainer, coordinator: Coordinator) {
        coordinator.cursor.update(false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: NSAttributedString?
        /// What `sizes` was measured for, which is dropped when it changes.
        var measuredText: NSAttributedString?
        var sizes: [CGFloat: CGSize] = [:]
        var openLink: ((URL) -> Void)?
        let cursor = HandCursor()

        @objc func hovered(_ hover: UIHoverGestureRecognizer) {
            guard let view = hover.view as? UITextView else { return }
            switch hover.state {
            case .began, .changed:
                cursor.update(isLink(at: hover.location(in: view), in: view))
            default:
                cursor.update(false)
            }
        }

        private func isLink(at point: CGPoint, in view: UITextView) -> Bool {
            guard let range = view.characterRange(at: point) else { return false }
            let location = view.offset(from: view.beginningOfDocument, to: range.start)
            guard location >= 0, location < view.textStorage.length else { return false }
            return view.textStorage.attribute(.link, at: location, effectiveRange: nil) != nil
        }

        // `xmpp:` links are the app's to confirm; the system would hand them
        // to another client.
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard URL.scheme?.lowercased() == "xmpp", let openLink else { return true }
            if interaction == .invokeDefaultAction { openLink(URL) }
            return false
        }

        // The row's own menu is the one to show on a right click.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            nil
        }
    }
}

/// Draws the words itself, with no text view, accessibility element or
/// recognizer: the row describes its message as a whole. `activate()` puts the
/// text view over it, set up as a selectable one.
final class SelectableTextContainer: UIView {
    /// What `sizeThatFits` measures with, so the drawing wraps where it said.
    static let drawingOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    weak var coordinator: SelectableText.Coordinator?
    private var textView: SelectableTextView?
    private var text: NSAttributedString?
    private var display: NSAttributedString?
    private var isOutgoing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(text: NSAttributedString, isOutgoing: Bool) {
        self.text = text
        self.isOutgoing = isOutgoing
        if let textView {
            fill(textView)
        } else {
            display = SelectableTextStyle.displayText(text, isOutgoing: isOutgoing)
            setNeedsDisplay()
        }
    }

    func activate() {
        guard textView == nil, let coordinator else { return }
        let view = SelectableTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = coordinator
        let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(SelectableText.Coordinator.hovered(_:)))
        view.addGestureRecognizer(hover)
        fill(view)
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        textView = view
        display = nil
        setNeedsDisplay()
    }

    private func fill(_ view: SelectableTextView) {
        view.attributedText = text
        // After the text, as setting it leaves the default color on runs
        // without one. Links take theirs from `linkTextAttributes`.
        view.textColor = SelectableTextStyle.textColor(isOutgoing: isOutgoing)
        view.linkTextAttributes = SelectableTextStyle.linkAttributes(isOutgoing: isOutgoing)
    }

    override func draw(_ rect: CGRect) {
        guard textView == nil else { return }
        display?.draw(with: bounds, options: Self.drawingOptions, context: nil)
    }
}

/// A text view that leaves right clicks to the message's context menu: with
/// its own menu interactions in the way, a click on the words would open
/// UIKit's edit menu instead. Copying still works through the responder chain.
final class SelectableTextView: UITextView {
    override func addInteraction(_ interaction: any UIInteraction) {
        if interaction is UIContextMenuInteraction || interaction is UIEditMenuInteraction { return }
        super.addInteraction(interaction)
    }
}

/// The pointing hand while the mouse is over the view.
struct LinkPointer: ViewModifier {
    @State private var cursor = HandCursor()

    func body(content: Content) -> some View {
        content
            .onHover { cursor.update($0) }
            .onDisappear { cursor.update(false) }
    }
}

#endif
