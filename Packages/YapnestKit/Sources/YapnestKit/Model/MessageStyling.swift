import Foundation

/// Styled spans and blocks in message text (XEP-0393).
public enum MessageStyling {
    public enum SpanStyle: Sendable {
        case bold, italic, code, strike
    }

    private static let markers: [Character: SpanStyle] = ["*": .bold, "_": .italic, "`": .code, "~": .strike]

    /// `*bold*`, `_italic_`, `` `code` `` and `~strike~`. The markers stay
    /// visible, so ranges still line up with the text. A span opens after
    /// whitespace (so `snake_case` is left alone), holds no line break and
    /// closes after a non-space. Bold, italic and strike may nest, so the
    /// ranges can overlap, the outer one first; code is verbatim inside.
    public static func spans(in text: String) -> [(range: NSRange, style: SpanStyle)] {
        var spans: [(NSRange, SpanStyle)] = []
        scan(text, from: text.startIndex, to: text.endIndex, into: &spans)
        return spans
    }

    private static func scan(_ text: String, from start: String.Index, to limit: String.Index, into spans: inout [(NSRange, SpanStyle)]) {
        // Whether a marker has a closer depends only on where the search
        // starts, so a search that reached the end of its line without one
        // settles every later opener on that line too. Without this, a line of
        // unclosed openers (which a sender controls) takes quadratic time.
        var noCloserBefore: [Character: String.Index] = [:]
        var index = start
        while index < limit {
            defer { index = text.index(after: index) }
            guard let style = markers[text[index]] else { continue }
            let marker = text[index]
            if index > start, !text[text.index(before: index)].isWhitespace { continue }
            let afterOpen = text.index(after: index)
            guard afterOpen < limit, !text[afterOpen].isWhitespace, text[afterOpen] != marker else { continue }
            if let lineEnd = noCloserBefore[marker], afterOpen < lineEnd { continue }
            var end = afterOpen
            var closing: String.Index?
            while end < limit, !text[end].isNewline {
                if text[end] == marker, !text[text.index(before: end)].isWhitespace {
                    let next = text.index(after: end)
                    if next == limit || !text[next].isLetter && !text[next].isNumber {
                        closing = end
                        break
                    }
                }
                end = text.index(after: end)
            }
            guard let closing else {
                noCloserBefore[marker] = end
                continue
            }
            spans.append((NSRange(index...closing, in: text), style))
            // What a span holds can open spans of its own, except in code. An
            // inner span can't use the outer's marker: the outer would have
            // closed at it, so the nesting is at most as deep as the styles.
            if style != .code { scan(text, from: afterOpen, to: closing, into: &spans) }
            index = closing
        }
    }

    /// A stretch of a message that is laid out on its own.
    public struct Block: Equatable, Sendable {
        public var text: String
        /// How many quotes deep it is.
        public var depth: Int
        /// Shown verbatim, in monospace, with no spans in it.
        public var isPreformatted: Bool
    }

    /// Splits a message into quotes and preformatted blocks. Quote markers
    /// and the lines holding a block's ``` directives are dropped, so the text
    /// is just what's shown. A block opens at a line starting with ```, whose
    /// remainder (a hint at the language) isn't shown, and ends at a line
    /// that's just ```, at the end of the quote it's in, or at the end of the
    /// message. A line holding ``` at both ends is no fence. Neighbouring lines at the same depth stay together.
    public static func blocks(in body: String) -> [Block] {
        guard body.contains(">") || body.contains("```") else { return [Block(text: body, depth: 0, isPreformatted: false)] }
        var blocks: [Block] = []
        var open: (depth: Int, lines: [String])?
        func close() {
            // An empty block has nothing to show.
            if let open, !open.lines.isEmpty {
                blocks.append(Block(text: open.lines.joined(separator: "\n"), depth: open.depth, isPreformatted: true))
            }
            open = nil
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let depth = line.prefix { $0 == ">" }.count
            // The markers must be followed by a space, or end the line.
            let isQuote = depth > 0 && (line.count == depth || line[line.index(line.startIndex, offsetBy: depth)] == " ")
            let level = isQuote ? depth : 0
            if let inBlock = open {
                if inBlock.depth == 0 {
                    // Quote markers are just text in a block outside any quote.
                    if line == "```" { close() } else { open?.lines.append(String(line)) }
                    continue
                }
                if level >= inBlock.depth {
                    // Deeper markers belong to the block's text.
                    var inner = line.dropFirst(inBlock.depth)
                    if inner.first == " " { inner = inner.dropFirst() }
                    if inner == "```" { close() } else { open?.lines.append(String(inner)) }
                    continue
                }
                // The quote the block was in has ended, and so has the block.
                close()
            }
            let shown = isQuote ? String(line.dropFirst(min(line.count, depth + 1))) : String(line)
            // A line that opens and closes on itself is inline code somebody typed,
            // not a fence with a language hint: opening a block there would hide
            // its text and turn the lines after it into code.
            let closesItself = shown.count > 6 && shown.hasSuffix("```")
            if shown.hasPrefix("```"), !closesItself {
                open = (level, [])
            } else if let last = blocks.last, !last.isPreformatted, last.depth == level {
                blocks[blocks.count - 1].text += "\n" + shown
            } else {
                blocks.append(Block(text: shown, depth: level, isPreformatted: false))
            }
        }
        close()
        return blocks.isEmpty ? [Block(text: body, depth: 0, isPreformatted: false)] : blocks
    }
}
