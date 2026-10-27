import SwiftUI

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
struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    let isOutgoing: Bool
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:)))
        view.addGestureRecognizer(hover)
        // The view isn't sized by its content, so a lower priority lets the
        // layout squeeze it rather than SwiftUI asking for its intrinsic width.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.openLink = openLink
        guard coordinator.text != text else { return }
        coordinator.text = text
        view.attributedText = text
        // After the text, as setting it leaves the default color on runs
        // without one. Links take theirs from `linkTextAttributes`.
        view.textColor = isOutgoing ? .white : .label
        view.linkTextAttributes = [
            .foregroundColor: isOutgoing ? UIColor.white : UIColor(Color.accentColor),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
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
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
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

    static func dismantleUIView(_ view: SelectableTextView, coordinator: Coordinator) {
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
