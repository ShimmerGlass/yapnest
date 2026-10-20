import UIKit
import UniformTypeIdentifiers
import YapnestKit

/// The composer, after Signal's iOS 26 input toolbar: an attachment button,
/// a glass capsule holding the reply preview, the tray of things to send,
/// text and in-field camera button, and a send button that appears once
/// there's something to send.
/// Earlier iOS versions get a blurred bar with a filled capsule instead.
final class ConversationInputBar: UIView, UITextViewDelegate, UIDropInteractionDelegate {
    enum AttachmentSource {
        case photoLibrary, camera, file, location, contact
    }

    var onSend: ((String) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onCancelReply: (() -> Void)?
    var onRemovePending: ((PendingAttachment.ID) -> Void)? {
        didSet { tray.onRemove = onRemovePending }
    }
    var onAttach: ((AttachmentSource) -> Void)?
    var onGif: (() -> Void)?
    /// Pictures or files pasted or dropped on the bar, which are added to the
    /// tray rather than inserted into the text.
    var onAttachments: (([NSItemProvider]) -> Void)?
    /// A drag carrying something to send is over the bar.
    var onDropTargeted: ((Bool) -> Void)?
    /// The nickname being typed after an "@", or nil when there's none.
    var onMentionQuery: ((String?) -> Void)?

    private enum Metrics {
        static let controlSize: CGFloat = 40
        static let verticalMargin: CGFloat = 8
        static let outerMargin: CGFloat = 12
        static let spacing: CGFloat = 8
        static let maxLines: CGFloat = 6
    }

    private let textView = ComposerTextView()
    /// Called after each layout, so the host can notice the bar's height changing.
    var onLayout: (() -> Void)?
    private let placeholder = UILabel()
    private lazy var attachControl = makeAttachControl()
    private lazy var gifButton = makeGifButton()
    /// The Mac's way to emoji, which has no emoji keyboard to switch to.
    private lazy var emojiButton = makeEmojiButton()
    /// The attach control, then the GIF and emoji buttons. A hidden one takes
    /// no room, nor does its spacing, so the field starts after what is shown.
    private lazy var leadingControls: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [attachControl, gifButton, emojiButton])
        stack.spacing = Metrics.spacing
        stack.alignment = .bottom
        return stack
    }()
    private lazy var cameraButton = makeFieldButton(symbol: "camera", label: String(localized: "Camera")) { [weak self] in
        self?.onAttach?(.camera)
    }
    private lazy var sendButton = makeSendButton()
    private let suggestions = UIStackView()
    private let suggestionsRow = UIScrollView()
    private let replyPreview = UIView()
    private let tray = AttachmentTray()
    private var hasPending = false
    private let replyAuthor = UILabel()
    let replyText = UILabel()
    private var textHeight: NSLayoutConstraint!
    /// The placeholder sits where the text starts: the text view's insets are
    /// physical, so one of these is active, by the layout direction. They hold
    /// to the frame, since a mirrored scroll view's content origin isn't its left.
    private lazy var placeholderLeft = placeholder.leftAnchor.constraint(equalTo: textView.frameLayoutGuide.leftAnchor, constant: 15)
    private lazy var placeholderRight = placeholder.rightAnchor.constraint(equalTo: textView.frameLayoutGuide.rightAnchor, constant: -15)
    /// Nicknames the controller offers for the "@" word, if that's what's active.
    private var mentionNicks: [String] = []
    /// The nicknames offered after an "@".
    var mentionSuggestions: [String] { mentionNicks }
    /// Emoji for the ":code" word, which the bar looks up itself since it
    /// needs nothing from the session.
    private var emojiMatches: [EmojiShortcodes.Match] = []
    private var emojiTrigger: EmojiShortcodes.Trigger?
    /// The highlighted emoji, for the keyboard.
    private var selectedEmoji = 0
    /// What the buttons in the suggestions row stand for.
    private var shownSuggestions: [String] = []
    /// The text and selection the queries were last worked out for. One
    /// keystroke changes both, and each reports it.
    private var lastQueried: (text: String, selection: NSRange)?
    /// Escape hides the suggestions until the word being typed changes.
    private var dismissedEmoji: EmojiShortcodes.Trigger?
    private var lastTextLength = 0
    /// The field ends at the send button while it's shown, at the edge otherwise.
    private var fieldToSend: NSLayoutConstraint!
    private var fieldToEdge: NSLayoutConstraint!

    var text: String { textView.text }

    private var hasText: Bool {
        !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Text or staged items: either is something to send.
    private var hasContent: Bool { hasText || hasPending }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        // The field's width changes with rotation, window size, the sidebar
        // and the send button.
        textView.onWidthChange = { [weak self] in self?.updateTextHeight() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateTextHeight()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func build() {
        textView.onReturn = { [weak self] in
            guard let self, !acceptSelectedEmoji() else { return }
            send()
        }
        textView.onPasteAttachments = { [weak self] providers in self?.onAttachments?(providers) }
        // The text view takes text drops itself; these take what it can't.
        textView.addInteraction(UIDropInteraction(delegate: self))
        addInteraction(UIDropInteraction(delegate: self))
        textView.capturesSuggestionKeys = { [weak self] in self?.emojiMatches.isEmpty == false }
        textView.onSuggestionKey = { [weak self] key in self?.handleSuggestionKey(key) }

        let content: UIView
        if #available(iOS 26, *) {
            // Merges the glass shapes of the buttons and field as they move.
            let container = UIVisualEffectView(effect: UIGlassContainerEffect())
            container.translatesAutoresizingMaskIntoConstraints = false
            addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            content = container.contentView
        } else {
            let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            background.translatesAutoresizingMaskIntoConstraints = false
            addSubview(background)
            NSLayoutConstraint.activate([
                background.topAnchor.constraint(equalTo: topAnchor),
                background.leadingAnchor.constraint(equalTo: leadingAnchor),
                background.trailingAnchor.constraint(equalTo: trailingAnchor),
                // Extend under the home indicator.
                background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 100),
            ])
            content = self
        }

        let field = makeField()
        for view in [leadingControls, field, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let guide = safeAreaLayoutGuide
        fieldToSend = field.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -Metrics.spacing)
        fieldToEdge = field.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Metrics.outerMargin)
        gifButton.isHidden = true
        emojiButton.isHidden = !Platform.isMac
        NSLayoutConstraint.activate([
            leadingControls.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Metrics.outerMargin),
            leadingControls.bottomAnchor.constraint(equalTo: field.bottomAnchor),

            field.leadingAnchor.constraint(equalTo: leadingControls.trailingAnchor, constant: Metrics.spacing),
            field.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalMargin),
            field.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Metrics.verticalMargin),
            fieldToEdge,

            sendButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Metrics.outerMargin),
            sendButton.bottomAnchor.constraint(equalTo: field.bottomAnchor),
        ])
        updateControls(animated: false)
    }

    /// The capsule: reply preview above a row of text and in-field buttons.
    private func makeField() -> UIView {
        let background: UIView
        let contentView: UIView
        if #available(iOS 26, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.cornerConfiguration = .uniformCorners(radius: .fixed(Metrics.controlSize / 2))
            background = effectView
            contentView = effectView.contentView
        } else {
            background = UIView()
            background.backgroundColor = .tertiarySystemFill
            background.layer.cornerRadius = Metrics.controlSize / 2
            background.layer.cornerCurve = .continuous
            contentView = background
        }

        buildReplyPreview()
        buildSuggestions()
        tray.isHidden = true

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = String(localized: "Message")

        // For UI tests, which can't go by the placeholder once there's text.
        textView.accessibilityIdentifier = "composer"
        placeholder.text = String(localized: "Message")
        placeholder.font = textView.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)

        let textRow = UIStackView(arrangedSubviews: [textView, cameraButton])
        textRow.alignment = .bottom

        let column = UIStackView(arrangedSubviews: [suggestionsRow, replyPreview, tray, textRow])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        textHeight = textView.heightAnchor.constraint(equalToConstant: Metrics.controlSize)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            textHeight,
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
        ])
        applyTextInsets()
        return background
    }

    /// More room on the side the text starts from than on the camera button's
    /// side. The text view's insets are physical, so they follow the direction.
    private func applyTextInsets() {
        let start: CGFloat = 10, end: CGFloat = 4
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        textView.textContainerInset = .init(top: 10, left: rightToLeft ? end : start, bottom: 10, right: rightToLeft ? start : end)
        placeholderRight.isActive = false
        placeholderLeft.isActive = false
        (rightToLeft ? placeholderRight : placeholderLeft).isActive = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTextInsets()
    }

    private func buildReplyPreview() {
        // A preview the stack collapses must not draw its row outside itself.
        replyPreview.clipsToBounds = true
        let bar = UIView()
        bar.backgroundColor = .tintColor
        bar.layer.cornerRadius = 2
        replyAuthor.font = .preferredFont(forTextStyle: .footnote).bold
        replyAuthor.textColor = .tintColor
        replyText.font = .preferredFont(forTextStyle: .footnote)
        replyText.textColor = .secondaryLabel
        replyText.numberOfLines = 2
        let labels = UIStackView(arrangedSubviews: [replyAuthor, replyText])
        labels.axis = .vertical
        let close = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.onCancelReply?() })
        close.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        close.configuration?.baseForegroundColor = .secondaryLabel
        close.accessibilityLabel = String(localized: "Cancel")
        close.preferredBehavioralStyle = .pad
        let row = UIStackView(arrangedSubviews: [bar, labels, close])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        replyPreview.addSubview(row)
        replyPreview.isHidden = true
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 4),
            bar.heightAnchor.constraint(equalTo: labels.heightAnchor),
            row.topAnchor.constraint(equalTo: replyPreview.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: replyPreview.bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: replyPreview.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: replyPreview.trailingAnchor),
        ])
    }

    /// Nicknames to mention, in a row above the text.
    private func buildSuggestions() {
        suggestions.spacing = 6
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestionsRow.showsHorizontalScrollIndicator = false
        suggestionsRow.addSubview(suggestions)
        suggestionsRow.isHidden = true
        NSLayoutConstraint.activate([
            suggestions.topAnchor.constraint(equalTo: suggestionsRow.contentLayoutGuide.topAnchor, constant: 8),
            suggestions.bottomAnchor.constraint(equalTo: suggestionsRow.contentLayoutGuide.bottomAnchor),
            suggestions.leadingAnchor.constraint(equalTo: suggestionsRow.contentLayoutGuide.leadingAnchor, constant: 6),
            // A few names sit at the leading edge in both directions, which
            // the scroll view doesn't do for itself when mirrored.
            suggestions.trailingAnchor.constraint(lessThanOrEqualTo: suggestionsRow.contentLayoutGuide.trailingAnchor, constant: -6),
            suggestionsRow.contentLayoutGuide.widthAnchor.constraint(greaterThanOrEqualTo: suggestionsRow.frameLayoutGuide.widthAnchor),
            suggestionsRow.frameLayoutGuide.heightAnchor.constraint(equalTo: suggestions.heightAnchor, constant: 8),
        ])
    }

    func setSuggestions(_ nicks: [String]) {
        mentionNicks = nicks
        refreshSuggestions()
    }

    /// Shows the emoji for a ":code" if there is one, else the nicknames
    /// for an "@". Only one word is active at a time, so they never mix.
    private func refreshSuggestions() {
        let shown = emojiMatches.isEmpty ? mentionNicks.map { "@" + $0 } : emojiMatches.map { ":\($0.shortcode):\($0.emoji)" }
        // The same buttons stay, with whatever the user has highlighted.
        if shown != shownSuggestions {
            shownSuggestions = shown
            rebuildSuggestionButtons()
        }
        let isEmpty = shown.isEmpty
        guard suggestionsRow.isHidden != isEmpty else { return }
        UIView.animate(withDuration: 0.2) {
            self.suggestionsRow.isHidden = isEmpty
            self.layoutIfNeeded()
        }
    }

    /// The row is laid out later (it may be hidden now), and in right-to-left
    /// its first, best suggestion is at the far end of the content.
    private var suggestionsNeedStart = false

    private func showFirstSuggestion() {
        guard suggestionsNeedStart, suggestionsRow.bounds.width > 0 else { return }
        suggestionsNeedStart = false
        suggestionsRow.layoutIfNeeded()
        let x = ComposerRowOffset.x(
            contentWidth: suggestionsRow.contentSize.width, frameWidth: suggestionsRow.bounds.width,
            rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft, showing: .leading,
        )
        suggestionsRow.setContentOffset(CGPoint(x: x, y: 0), animated: false)
    }

    private func rebuildSuggestionButtons() {
        suggestionsNeedStart = true
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !emojiMatches.isEmpty {
            for match in emojiMatches {
                let button = makeSuggestionButton { [weak self] in self?.insertEmoji(match) }
                let title = NSMutableAttributedString(string: match.emoji, attributes: [.font: UIFont.preferredFont(forTextStyle: .title3)])
                title.append(NSAttributedString(string: "  :\(match.shortcode):", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .footnote),
                    .foregroundColor: UIColor.secondaryLabel,
                ]))
                button.configuration?.attributedTitle = AttributedString(title)
                button.accessibilityLabel = ":\(match.shortcode):"
                suggestions.addArrangedSubview(button)
            }
            highlightEmoji()
        } else {
            for nick in mentionNicks {
                let button = makeSuggestionButton { [weak self] in self?.insertMention(nick) }
                button.configuration?.title = nick
                button.configuration?.image = UIImage(systemName: "at")
                button.configuration?.imagePadding = 2
                button.configuration?.preferredSymbolConfigurationForImage = .init(scale: .small)
                suggestions.addArrangedSubview(button)
            }
        }
    }

    private func makeSuggestionButton(_ action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.preferredBehavioralStyle = .pad
        return button
    }

    private func highlightEmoji() {
        for (index, view) in suggestions.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            button.configuration?.background.backgroundColor = index == selectedEmoji
                ? UIColor.tintColor.withAlphaComponent(0.3)
                : UIColor.tertiarySystemFill
        }
        if suggestions.arrangedSubviews.indices.contains(selectedEmoji) {
            suggestionsRow.layoutIfNeeded()
            suggestionsRow.scrollRectToVisible(suggestions.arrangedSubviews[selectedEmoji].frame.insetBy(dx: -6, dy: 0), animated: true)
        }
    }

    // MARK: Emoji

    /// Emoji by how much they're used, across devices, most used first. Kept
    /// in memory so typing doesn't read the database on every change; the
    /// model loads it when the composer appears.
    private(set) var emojiOrder: [String] = []
    /// Emoji picked before the order arrived, most recent first, which the
    /// loaded order would otherwise replace. Nil once it has.
    private var picksBeforeOrder: [String]? = []
    var onEmojiPicked: ((String) -> Void)?

    func setEmojiOrder(_ order: [String]) {
        let picked = picksBeforeOrder ?? []
        picksBeforeOrder = nil
        emojiOrder = picked + order.filter { !picked.contains($0) }
    }

    func recordRecent(_ emoji: String) {
        emojiOrder = [emoji] + emojiOrder.filter { $0 != emoji }
        picksBeforeOrder = picksBeforeOrder.map { [emoji] + $0.filter { $0 != emoji } }
        onEmojiPicked?(emoji)
    }

    private var cursor: Int? {
        textView.selectedRange.length == 0 ? textView.selectedRange.location : nil
    }

    private func updateEmojiSuggestions() {
        var trigger = cursor.flatMap { EmojiShortcodes.trigger(in: textView.text, cursor: $0) }
        if trigger != dismissedEmoji { dismissedEmoji = nil }
        if trigger != nil, trigger == dismissedEmoji { trigger = nil }
        // Whichever word is nearest the cursor wins.
        if let found = trigger, let mention = mentionRange, mention.range.location > found.range.location { trigger = nil }
        let matches = trigger.map { EmojiShortcodes.shared.matches(for: $0.query, recents: emojiOrder) } ?? []
        // Not a new query while the same one is still being typed.
        if matches != emojiMatches { selectedEmoji = 0 }
        emojiTrigger = matches.isEmpty ? nil : trigger
        emojiMatches = matches
    }

    private func insertEmoji(_ match: EmojiShortcodes.Match) {
        guard let range = emojiTrigger?.range else { return }
        recordRecent(match.emoji)
        replace(range, with: match.emoji)
    }

    private func acceptSelectedEmoji() -> Bool {
        guard emojiMatches.indices.contains(selectedEmoji) else { return false }
        insertEmoji(emojiMatches[selectedEmoji])
        return true
    }

    /// Typing the closing colon of a known code swaps it for the emoji.
    private func replaceCompletedShortcode() -> Bool {
        guard let cursor, let found = EmojiShortcodes.shared.completedShortcode(in: textView.text, cursor: cursor) else { return false }
        recordRecent(found.emoji)
        replace(found.range, with: found.emoji)
        return true
    }

    private func handleSuggestionKey(_ key: ComposerTextView.SuggestionKey) {
        switch key {
        case .previous, .next:
            let count = emojiMatches.count
            guard count > 0 else { return }
            selectedEmoji = (selectedEmoji + (key == .next ? 1 : count - 1)) % count
            highlightEmoji()
        case .accept:
            _ = acceptSelectedEmoji()
        case .dismiss:
            dismissedEmoji = emojiTrigger
            notifyQueries(force: true)
        }
    }

    private func replace(_ range: NSRange, with replacement: String) {
        // Through the text input API, which registers the change for undo;
        // editing the storage directly leaves ⌘Z with ranges that no longer fit.
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: replacement)
        textView.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textViewDidChange(textView)
    }

    /// The "@" word the cursor is in, if any.
    private var mentionRange: (range: NSRange, query: String)? {
        let text = textView.text as NSString
        let cursor = textView.selectedRange
        guard cursor.length == 0, cursor.location <= text.length else { return nil }
        // Walk back from the cursor over the one word it's in, rather than
        // copying everything before it on every keystroke.
        var at = cursor.location - 1
        while at >= 0, text.character(at: at) != 0x40 {
            // Only while it's one word.
            if isWhitespace(text.character(at: at)) { return nil }
            at -= 1
        }
        guard at >= 0 else { return nil }
        // Only at the start of a word.
        if at > 0, !isWhitespace(text.character(at: at - 1)) { return nil }
        let query = text.substring(with: NSRange(location: at + 1, length: cursor.location - at - 1))
        return (NSRange(location: at, length: cursor.location - at), query)
    }

    private func isWhitespace(_ unit: unichar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(unit) ?? "x")
    }

    private func insertMention(_ nick: String) {
        guard let (range, _) = mentionRange else { return }
        replace(range, with: "@\(nick) ")
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        notifyQueries()
    }

    /// The emoji word takes over from the mention one when it's nearer the
    /// cursor, so the controller is told there's no "@" query then.
    private func notifyQueries(force: Bool = false) {
        let selection = textView.selectedRange
        if !force, let last = lastQueried, last.selection == selection, last.text == textView.text { return }
        lastQueried = (textView.text, selection)
        updateEmojiSuggestions()
        if emojiMatches.isEmpty {
            onMentionQuery?(mentionRange?.query)
        } else {
            onMentionQuery?(nil)
            mentionNicks = []
        }
        refreshSuggestions()
    }

    private func makeAttachControl() -> AttachControl {
        let menu = UIMenu(children: [
            UIAction(title: String(localized: "Photos"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.onAttach?(.photoLibrary)
            },
            UIAction(title: String(localized: "Camera"), image: UIImage(systemName: "camera")) { [weak self] _ in
                self?.onAttach?(.camera)
            },
            UIAction(title: String(localized: "File"), image: UIImage(systemName: "doc")) { [weak self] _ in
                self?.onAttach?(.file)
            },
            UIAction(title: String(localized: "Location"), image: UIImage(systemName: "location")) { [weak self] _ in
                self?.onAttach?(.location)
            },
            UIAction(title: String(localized: "Contact"), image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                self?.onAttach?(.contact)
            },
        ])
        return AttachControl(menu: menu, size: Metrics.controlSize)
    }

    /// A glass capsule the size of the other controls, for the GIF and emoji
    /// buttons; the caller gives it a title or an image.
    private func makeCapsuleButton(accessibilityLabel: String, action: @escaping () -> Void) -> UIButton {
        let button: UIButton
        if #available(iOS 26, *) {
            button = UIButton(configuration: .glass())
        } else {
            button = UIButton(configuration: .plain())
        }
        button.configuration?.contentInsets = .zero
        button.configuration?.baseForegroundColor = .label
        button.configuration?.cornerStyle = .capsule
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.accessibilityLabel = accessibilityLabel
        button.isPointerInteractionEnabled = true
        constrainToControlSize(button)
        return button
    }

    private func makeGifButton() -> UIButton {
        let button = makeCapsuleButton(accessibilityLabel: "GIF") { [weak self] in self?.onGif?() }
        button.configuration?.title = "GIF"
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
            return attributes
        }
        return button
    }

    private func makeEmojiButton() -> UIButton {
        let button = makeCapsuleButton(accessibilityLabel: String(localized: "Emoji")) { [weak self] in
            // The viewer types into what has focus, at the caret.
            guard let self, textView.becomeFirstResponder() else { return }
            CharacterPalette.show()
        }
        button.configuration?.image = UIImage(systemName: "face.smiling")
        return button
    }

    private func makeFieldButton(symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { _ in action() })
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.baseForegroundColor = .label
        button.accessibilityLabel = label
        button.isPointerInteractionEnabled = true
        constrainToControlSize(button)
        return button
    }

    private func makeSendButton() -> UIButton {
        let button: UIButton
        if #available(iOS 26, *) {
            button = UIButton(configuration: .prominentGlass())
            button.configuration?.image = UIImage(systemName: "arrow.up")
            button.configuration?.preferredSymbolConfigurationForImage = .init(weight: .semibold)
        } else {
            button = UIButton(configuration: .plain())
            button.configuration?.image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32))
        }
        button.configuration?.cornerStyle = .capsule
        button.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)
        button.accessibilityLabel = String(localized: "Send")
        button.isPointerInteractionEnabled = true
        constrainToControlSize(button)
        return button
    }

    private func send() {
        // Commits any IME composition (pinyin, kana) first, as Messages does,
        // so the send doesn't carry the uncommitted marked text.
        textView.unmarkText()
        guard hasContent else { return }
        onSend?(textView.text)
    }

    private func constrainToControlSize(_ button: UIButton) {
        // The Mac would draw its own push and pull-down buttons, which
        // don't match the field.
        button.preferredBehavioralStyle = .pad
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.controlSize),
            button.heightAnchor.constraint(equalToConstant: Metrics.controlSize),
        ])
    }

    // MARK: State

    /// Something to send replaces the camera button in the field with the send button beside it.
    private func updateControls(animated: Bool) {
        let showSend = hasContent
        let changed = sendButton.isHidden == showSend
        guard changed || !animated else { return }
        let apply = {
            self.sendButton.isHidden = !showSend
            self.sendButton.alpha = showSend ? 1 : 0
            self.cameraButton.isHidden = showSend
            self.cameraButton.alpha = showSend ? 0 : 1
            self.fieldToEdge.isActive = !showSend
            self.fieldToSend.isActive = showSend
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: apply)
        } else {
            apply()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        showFirstSuggestion()
        onLayout?()
    }

    /// Fits the field to its text at its current width and text size. Never
    /// shorter than the control size, which the empty field outgrows with
    /// larger text so the placeholder isn't clipped.
    private func updateTextHeight() {
        // Before the first layout there is no width to wrap at.
        guard textView.bounds.width > 0 else { return }
        let lineHeight = textView.font?.lineHeight ?? 20
        let insets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let maxHeight = lineHeight * Metrics.maxLines + insets
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(max(Metrics.controlSize, fitting), maxHeight)
        if textHeight.constant != height { textHeight.constant = height }
        let scrolls = fitting > maxHeight
        if textView.isScrollEnabled != scrolls { textView.isScrollEnabled = scrolls }
    }

    /// Shows what the next message answers or edits above the text.
    func setReply(_ reply: (author: String, text: String)?) {
        // Keep the text while the preview folds away.
        if let reply {
            replyAuthor.text = reply.author
            replyText.text = reply.text
        }
        let hidden = reply == nil
        wantsReplyHidden = hidden
        // Setting the flag again, or reversing it mid-animation, makes the
        // stack view lose track of the view, so only touch it on a change.
        guard replyPreview.isHidden != hidden else { return }
        UIView.animate(withDuration: 0.2, animations: {
            self.replyPreview.isHidden = hidden
            self.replyPreview.alpha = hidden ? 0 : 1
            self.layoutIfNeeded()
        }, completion: { _ in
            // Overlapping animations can leave the stack holding the view at zero
            // height while the flag says it's shown. Flipping the flag outside an
            // animation makes it rebuild its hiding constraint. A later request
            // resyncs on its own.
            guard self.wantsReplyHidden == hidden else { return }
            self.replyPreview.isHidden = !hidden
            self.replyPreview.isHidden = hidden
            self.replyPreview.alpha = hidden ? 0 : 1
        })
    }

    private var wantsReplyHidden = true

    /// Shows what's waiting to be sent above the text. The send button
    /// follows, since the tray alone is enough to send.
    func setPendingAttachments(_ items: [PendingAttachment]) {
        hasPending = !items.isEmpty
        tray.set(items)
        let hidden = items.isEmpty
        if tray.isHidden != hidden {
            UIView.animate(withDuration: 0.2) {
                self.tray.isHidden = hidden
                self.layoutIfNeeded()
            }
        }
        updateControls(animated: true)
    }

    func setGifsAvailable(_ available: Bool) {
        guard gifButton.isHidden == available else { return }
        gifButton.isHidden = !available
    }

    /// A spinner in the attach button while picked files are prepared.
    func setPreparingAttachment(_ preparing: Bool) {
        attachControl.setPreparing(preparing)
    }

    func focus() { textView.becomeFirstResponder() }

    // MARK: Dropping

    private static func attachments(in session: any UIDropSession) -> [NSItemProvider] {
        session.items.map(\.itemProvider).filter {
            AttachmentIntake.kind(of: $0.registeredTypeIdentifiers).isAttachment
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        !Self.attachments(in: session).isEmpty
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) { onDropTargeted?(true) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) { onDropTargeted?(false) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) { onDropTargeted?(false) }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        onAttachments?(Self.attachments(in: session))
    }

    /// `notify` is off for text the model puts in itself, which isn't typing
    /// and mustn't be reported as such.
    func setText(_ text: String, notify: Bool = true) {
        textView.text = text
        // Whatever could be undone refers to the text that was just replaced.
        textView.undoManager?.removeAllActions()
        didChange(notify: notify)
    }

    func textViewDidChange(_ textView: UITextView) {
        didChange(notify: true)
    }

    private func didChange(notify: Bool) {
        placeholder.isHidden = !textView.text.isEmpty
        updateControls(animated: true)
        // After the controls, as the send button appearing narrows the field.
        updateTextHeight()
        if notify { onTextChanged?(textView.text) }
        let length = (textView.text as NSString).length
        let grew = length > lastTextLength
        lastTextLength = length
        // Only when typing, so deleting back to a closing colon doesn't undo itself.
        if grew, replaceCompletedShortcode() { return }
        notifyQueries()
    }
}

/// On the Mac, Return sends, as in other chat apps there; Command-Return
/// starts a new line, as do Shift- and Option-Return. The iPhone's Return
/// key always starts one.
fileprivate final class ComposerTextView: UITextView {
    enum SuggestionKey { case previous, next, accept, dismiss }

    var onReturn: (() -> Void)?
    /// Pictures or files being pasted, which aren't text for the field.
    var onPasteAttachments: (([NSItemProvider]) -> Void)?
    var onSuggestionKey: ((SuggestionKey) -> Void)?
    /// True while there are emoji to pick, when the arrow, Tab and Escape
    /// keys belong to them rather than to the text.
    var capturesSuggestionKeys: () -> Bool = { false }
    /// Called when the width or the font size actually changes, so the bar can
    /// re-measure. The bar's own layout runs before this view is given its
    /// frame, and a text size change can arrive before the new font is applied.
    var onWidthChange: (() -> Void)?
    private var fit = FitTrigger()

    override func layoutSubviews() {
        super.layoutSubviews()
        guard fit.changed(width: bounds.width, pointSize: font?.pointSize ?? 0) else { return }
        onWidthChange?()
    }

    /// Key commands, unlike watching presses, come before the text system
    /// turns Return into a new line.
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        let capturing = capturesSuggestionKeys()
        if capturing {
            // Left and Right pick too, as the row runs sideways. Escape hides
            // the row, which gives the cursor keys back.
            commands += [
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(suggestionPrevious)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(suggestionNext)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(suggestionPrevious)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(suggestionNext)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(suggestionAccept)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(suggestionDismiss)),
            ]
        }
        if ProcessInfo.processInfo.isMacCatalystApp {
            commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromKeyboard)))
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(insertNewLine)))
        } else if capturing {
            // A hardware Return picks the emoji instead of starting a line.
            commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromKeyboard)))
        }
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Not while composing with an input method: Return confirms that.
        let ours = [#selector(sendFromKeyboard), #selector(insertNewLine), #selector(suggestionPrevious),
                    #selector(suggestionNext), #selector(suggestionAccept), #selector(suggestionDismiss)]
        if ours.contains(action) {
            return markedTextRange == nil
        }
        // The text view only enables Paste for text, but a picture or a file
        // on the pasteboard is something to send. Asking what's there, as
        // opposed to reading it, doesn't raise the paste prompt.
        if action == #selector(paste(_:)), !UIPasteboard.general.hasStrings, Self.pasteboardHoldsAttachment {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private static var pasteboardHoldsAttachment: Bool {
        let board = UIPasteboard.general
        return board.hasImages
            || board.contains(pasteboardTypes: [UTType.fileURL, .pdf, .movie, .audio].map(\.identifier))
    }

    /// Pictures and files are offered for sending instead of going into the
    /// text, with the exception described at `AttachmentIntake.isLabel`.
    /// `paste(itemProviders:)` isn't used because UITextView implements Paste
    /// itself and never reaches it.
    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders
        let attachments = providers.filter { AttachmentIntake.kind(of: $0.registeredTypeIdentifiers).isAttachment }
        guard !attachments.isEmpty else { return super.paste(sender) }
        // Text next to a picture is usually its address or name, but a page
        // or note copied with both means the text. Files offer their name as
        // text, which says nothing.
        let onlyImages = attachments.allSatisfy { AttachmentIntake.kind(of: $0.registeredTypeIdentifiers) == .image }
        guard onlyImages, let source = providers.first(where: { AttachmentIntake.offersText($0.registeredTypeIdentifiers) }) else {
            return onPasteAttachments?(attachments) ?? ()
        }
        // Item providers aren't Sendable, but they're only handed back to the main actor.
        nonisolated(unsafe) let offered = attachments
        _ = source.loadObject(ofClass: NSString.self) { [weak self] text, _ in
            let text = text as? String
            Task { @MainActor in
                guard let self else { return }
                if let text, !AttachmentIntake.isLabel(text) {
                    self.insertText(text)
                } else {
                    self.onPasteAttachments?(offered)
                }
            }
        }
    }

    @objc private func sendFromKeyboard() { onReturn?() }

    @objc private func insertNewLine() { insertText("\n") }
    @objc private func suggestionPrevious() { onSuggestionKey?(.previous) }
    @objc private func suggestionNext() { onSuggestionKey?(.next) }
    @objc private func suggestionAccept() { onSuggestionKey?(.accept) }
    @objc private func suggestionDismiss() { onSuggestionKey?(.dismiss) }
}
