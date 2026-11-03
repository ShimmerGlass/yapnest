import Foundation

/// Styled spans and blocks in message text (XEP-0393).
public enum MessageStyling {
    public enum SpanStyle: Sendable {
        case bold, italic, code, strike
    }

    private static let markers: [Character: SpanStyle] = ["*": .bold, "_": .italic, "`": .code, "~": .strike]

    /// `*bold*`, `_italic_`, `` `code` `` and `~strike~`. The ranges include
    /// the markers, one ASCII character at each end. A span opens after
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

    /// The spans of text as it is typed, for styling the composer live. Ranges
    /// are UTF-16 offsets into the raw text, quote markers and fences
    /// included, so they can be applied to the text field as it is. It agrees
    /// with the bubble: a line the bubble would show verbatim (a fence or
    /// what a fence holds) has no spans, and a quoted line is styled as it is
    /// after its markers. A block that is still open is verbatim to the end,
    /// as it will be once sent.
    public static func composerSpans(in text: String) -> [(range: NSRange, style: SpanStyle)] {
        guard text.contains(where: { markers[$0] != nil }) else { return [] }
        var result: [(NSRange, SpanStyle)] = []
        // Mirrors the line rules of `blocks(in:)`; a test holds the two together.
        var openDepth: Int?
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { offset += line.utf16.count + 1 }
            let markerCount = line.prefix { $0 == ">" }.count
            let depth = min(markerCount, maxQuoteDepth)
            let isQuote = markerCount > 0 && (line.count == markerCount || line[line.index(line.startIndex, offsetBy: markerCount)] == " ")
            let level = isQuote ? depth : 0
            if let inBlock = openDepth {
                if inBlock == 0 {
                    if line == "```" { openDepth = nil }
                    continue
                }
                if level >= inBlock {
                    var inner = line.dropFirst(inBlock)
                    if inner.first == " " { inner = inner.dropFirst() }
                    if inner == "```" { openDepth = nil }
                    continue
                }
                openDepth = nil
            }
            let dropped = isQuote ? min(line.count, markerCount > depth ? depth : depth + 1) : 0
            let shown = line.dropFirst(dropped)
            let closesItself = shown.count > 6 && shown.hasSuffix("```")
            if shown.hasPrefix("```"), !closesItself {
                openDepth = level
                continue
            }
            // The dropped characters are ">" and a space, one UTF-16 unit each.
            let shift = offset + dropped
            for span in spans(in: String(shown)) {
                result.append((NSRange(location: span.range.location + shift, length: span.range.length), span.style))
            }
        }
        return result
    }

    /// A stretch of a message that is laid out on its own.
    public struct Block: Equatable, Sendable {
        public var text: String
        /// How many quotes deep it is.
        public var depth: Int
        /// Shown verbatim, in monospace, with no spans in it.
        public var isPreformatted: Bool
    }

    /// How deep quotes nest, and how many blocks a message is split into.
    /// The bubble draws a bar per level and a view per block, so a body of
    /// sixty thousand `>`, or of lines alternating between two depths, would
    /// build that many views. Markers past the depth stay as text in the
    /// deepest level, and blocks past the count are merged into plain text.
    public static let maxQuoteDepth = 8
    public static let maxBlocks = 200

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
            let markerCount = line.prefix { $0 == ">" }.count
            let depth = min(markerCount, maxQuoteDepth)
            // The markers must be followed by a space, or end the line.
            let isQuote = markerCount > 0 && (line.count == markerCount || line[line.index(line.startIndex, offsetBy: markerCount)] == " ")
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
            // Markers past the cap are text, and the space after them is too.
            let shown = isQuote ? String(line.dropFirst(min(line.count, markerCount > depth ? depth : depth + 1))) : String(line)
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
        if blocks.count > maxBlocks {
            let rest = blocks[maxBlocks...].map(\.text).joined(separator: "\n")
            blocks.removeSubrange(maxBlocks...)
            blocks.append(Block(text: rest, depth: 0, isPreformatted: false))
        }
        return blocks.isEmpty ? [Block(text: body, depth: 0, isPreformatted: false)] : blocks
    }
}
