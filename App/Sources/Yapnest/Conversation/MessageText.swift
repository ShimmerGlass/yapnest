import SwiftUI
import YapnestKit

/// A message's body, ready to draw. Building it detects links and styled
/// spans, which is too much work to repeat on every body evaluation, so the
/// model builds it once per revision of a message.
struct RenderedText: Equatable {
    /// A run of lines quoted to the same depth. Text can't draw a bar down
    /// the side of some of its paragraphs, so each stretch is its own `Text`.
    struct Segment: Equatable, Identifiable {
        var id: Int
        var depth: Int
        /// Code to show verbatim, in a box of its own.
        var isPreformatted = false
        var text: AttributedString
        /// The same words for a `UITextView`, which the Mac selects text in.
        /// Only built there, as `Text` can't be selected and UIKit can't take
        /// a SwiftUI `Font`.
        nonisolated(unsafe) var native: NSAttributedString?
    }

    var segments: [Segment]
    /// The links found in the body, in order, for the message menu to offer
    /// without detecting them again on the main thread. A cut-short body
    /// still has all of its links.
    var links: [URL] = []
    /// Only the start of a long body is here; `MessageText.collapsedLineLimit` says why.
    var isCollapsed = false
    /// The body is nothing but a few emoji, drawn large (see `emojiOnlyCount`).
    var isEmojiOnly = false

    fileprivate static func plain(_ string: String, font: MessageText.BodyFont) -> RenderedText {
        var text = AttributedString(string)
        text.font = font.swiftUI
        var native: NSAttributedString?
        #if targetEnvironment(macCatalyst)
        native = NSAttributedString(string: string, attributes: [.font: font.uiFont])
        #endif
        return RenderedText(segments: [.init(id: 0, depth: 0, text: text, native: native)])
    }
}

/// Finding links, quotes and styled spans in message text, and turning them
/// into something `Text` can draw.
enum MessageText {
    /// A body font in both frameworks, as a SwiftUI `Font` can't become a
    /// `UIFont`.
    struct BodyFont {
        var swiftUI: Font
        var style: UIFont.TextStyle
        var isItalic = false
        /// A size of its own instead of the style's, still scaled by the
        /// style's Dynamic Type metrics.
        var size: CGFloat?

        static let body = BodyFont(swiftUI: .body, style: .body)
        static let italicBody = BodyFont(swiftUI: .body.italic(), style: .body, isItalic: true)

        /// A font bigger than any text style, which scales as `style` does.
        static func scaled(_ size: CGFloat, like style: UIFont.TextStyle) -> BodyFont {
            var font = BodyFont(swiftUI: .body, style: style, size: size)
            font.swiftUI = Font(font.uiFont)
            return font
        }

        var uiFont: UIFont {
            let base = size.map { UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: $0)) }
                ?? UIFont.preferredFont(forTextStyle: style)
            return isItalic ? base.with(traits: .traitItalic) : base
        }
    }

    /// What the bubble shows for a message, by how it's to be read.
    enum Kind: Hashable {
        case normal
        /// "/me waves", shown as "Alice waves", all in italics.
        case action(name: String)
        case retracted(outgoing: Bool)
        /// Taken back by a group's moderator rather than by its author.
        case moderated
        case undecryptable
    }

    /// A body longer than this many lines, or characters, is shown cut short
    /// until the reader asks for the rest. The list sits in a lazy stack that
    /// guesses the height of the rows it hasn't drawn from those it has, and
    /// one email of seven thousand points among messages of a hundred made
    /// that guess so large that flicking up through a long history hardly got
    /// anywhere: the end of it kept moving away as fast as the list moved.
    static let collapsedLineLimit = 14
    static let collapsedCharacterLimit = 700

    /// The start of `body` that is shown until the reader opens the rest, or
    /// nil when all of it fits. It stops at a word where it can.
    static func collapse(_ body: String) -> String? {
        var end = body.startIndex
        var characters = 0
        var lines = 1
        var cutAtWord: String.Index?
        while end < body.endIndex {
            let character = body[end]
            if character.isNewline {
                lines += 1
                if lines > collapsedLineLimit { break }
            }
            if characters == collapsedCharacterLimit { break }
            if character.isWhitespace, characters > collapsedCharacterLimit - 60 { cutAtWord = end }
            characters += 1
            end = body.index(after: end)
        }
        guard end < body.endIndex else { return nil }
        let kept = body[..<(characters == collapsedCharacterLimit ? cutAtWord ?? end : end)]
        let start = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        // Beside a closing ``` the dots would be taken for a line of the block
        // that was never closed.
        return start + (endsOnFence(start) ? "\n…" : "…")
    }

    /// Whether the last line is a bare ```, at any quote depth, as
    /// `MessageStyling.blocks(in:)` reads a fence: quote markers, then a space.
    private static func endsOnFence(_ text: String) -> Bool {
        guard let newline = text.lastIndex(of: "\n") else { return false }
        let line = text[text.index(after: newline)...]
        let depth = line.prefix { $0 == ">" }.count
        let rest = line.dropFirst(depth)
        return depth == 0 ? rest == "```" : rest == " ```"
    }

    /// With `collapsed`, a long body is cut short (see `collapsedLineLimit`).
    static func render(_ body: String, kind: Kind, collapsed: Bool = false) -> RenderedText {
        let body = body.trimmingBlankEdgeLines
        return switch kind {
        case .retracted(let outgoing):
            .plain(outgoing ? String(localized: "You deleted this message.") : String(localized: "This message was deleted."), font: .italicBody)
        case .moderated:
            .plain(String(localized: "Removed by a moderator"), font: .italicBody)
        case .undecryptable:
            .plain(String(localized: "This message is encrypted and couldn't be decrypted."), font: .italicBody)
        case .action(let name):
            render("\(name) \(Message.meAction(in: body) ?? "")", font: .italicBody)
        case .normal:
            if collapsed, let start = collapse(body) {
                with(render(start, font: .body)) { $0.isCollapsed = true }
            } else {
                renderWhole(body)
            }
        }
    }

    private static func with(_ text: RenderedText, _ change: (inout RenderedText) -> Void) -> RenderedText {
        var text = text
        change(&text)
        return text
    }

    private static func renderWhole(_ body: String) -> RenderedText {
        let emoji = emojiOnlyCount(body)
        return with(render(body, font: bodyFont(forEmojiCount: emoji))) { $0.isEmojiOnly = emoji != nil }
    }

    private static func bodyFont(forEmojiCount emoji: Int?) -> BodyFont {
        switch emoji {
        case let count? where count <= 3: .scaled(56, like: .largeTitle)
        case _?: .scaled(40, like: .title1)
        case nil: .body
        }
    }

    private static func render(_ body: String, font: BodyFont) -> RenderedText {
        var found: [URL] = []
        let segments = MessageStyling.blocks(in: body).enumerated().map { index, block in
            var text = AttributedString(block.text)
            #if targetEnvironment(macCatalyst)
            let native = NSMutableAttributedString(string: block.text, attributes: [.font: font.uiFont])
            #endif
            if block.isPreformatted {
                // Verbatim means no links to tap and no spans either.
                text.font = font.swiftUI.monospaced()
                var segment = RenderedText.Segment(id: index, depth: block.depth, isPreformatted: true, text: text)
                #if targetEnvironment(macCatalyst)
                native.addAttribute(.font, value: MessageStyling.SpanStyle.code.uiFont(from: font.uiFont), range: NSRange(location: 0, length: native.length))
                segment.native = NSAttributedString(attributedString: native)
                #endif
                return segment
            }
            text.font = font.swiftUI
            let links = LinkDetector.links(in: block.text)
            found += links.map(\.url)
            for (range, url) in links {
                guard let attributed = attributedRange(range, in: block.text, of: text) else { continue }
                // The link's color comes from the view's tint.
                text[attributed].link = url
                text[attributed].underlineStyle = .single
                #if targetEnvironment(macCatalyst)
                native.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                #endif
            }
            let linkRanges = links.map(\.range)
            for span in MessageStyling.spans(in: block.text) where !linkRanges.contains(where: { NSIntersectionRange($0, span.range).length > 0 }) {
                guard let attributed = attributedRange(span.range, in: block.text, of: text) else { continue }
                // Nested spans add to the font their outer span gave the run.
                for run in text[attributed].runs {
                    text[run.range].font = span.style.font(from: run.font ?? font.swiftUI)
                }
                if span.style == .strike { text[attributed].strikethroughStyle = .single }
                #if targetEnvironment(macCatalyst)
                native.enumerateAttribute(.font, in: span.range) { value, range, _ in
                    native.addAttribute(.font, value: span.style.uiFont(from: value as? UIFont ?? font.uiFont), range: range)
                }
                if span.style == .strike { native.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range) }
                #endif
            }
            var segment = RenderedText.Segment(id: index, depth: block.depth, text: text)
            #if targetEnvironment(macCatalyst)
            segment.native = NSAttributedString(attributedString: native)
            #endif
            return segment
        }
        return RenderedText(segments: segments, links: found)
    }

    private static func attributedRange(_ range: NSRange, in string: String, of text: AttributedString) -> Range<AttributedString.Index>? {
        guard let bounds = Range(range, in: string) else { return nil }
        return Range(bounds, in: text)
    }

    static let quoteIndent: CGFloat = 10

    /// The number of emoji in a message made of nothing else, for showing
    /// those larger.
    static func emojiOnlyCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.dropFirst(6).isEmpty else { return nil }
        for character in trimmed {
            guard let first = character.unicodeScalars.first else { return nil }
            let isEmoji = first.properties.isEmojiPresentation
                || (first.properties.isEmoji && (character.unicodeScalars.count > 1 || first.value > 0x2000))
            if !isEmoji { return nil }
        }
        return trimmed.count
    }
}

extension MessageStyling.SpanStyle {
    func font(from font: Font) -> Font {
        switch self {
        case .bold: font.bold()
        case .italic: font.italic()
        case .code: font.monospaced()
        case .strike: font
        }
    }
}

extension MessageStyling.SpanStyle {
    func uiFont(from font: UIFont) -> UIFont {
        switch self {
        case .bold: font.with(traits: .traitBold)
        case .italic: font.with(traits: .traitItalic)
        case .code: UIFont(descriptor: font.fontDescriptor.withDesign(.monospaced) ?? font.fontDescriptor, size: 0)
        case .strike: font
        }
    }
}

extension UIFont {
    func with(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let descriptor = fontDescriptor
        return UIFont(descriptor: descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(traits)) ?? descriptor, size: 0)
    }
}

/// Size limits for media and link preview bubbles. 0.78 of the width alone
/// grows without bound in a wide Mac window or on an iPad. On an iPhone
/// (0.78 x 440 = 343, a 319pt image under 12pt padding, 1.33 tall = 424)
/// neither limit applies.
enum MediaLimits {
    static let maxBubbleWidth: CGFloat = 360
    /// Taller than this is cropped by the image view's aspect fill.
    static let maxMediaHeight: CGFloat = 432
}
