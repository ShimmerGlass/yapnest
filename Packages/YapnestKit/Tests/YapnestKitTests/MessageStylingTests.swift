import Foundation
import Testing
@testable import YapnestKit

struct MessageStylingTests {
    private func styled(_ text: String) -> [String] {
        MessageStyling.spans(in: text).map { span in
            let style = switch span.style { case .bold: "b"; case .italic: "i"; case .code: "c"; case .strike: "s" }
            return style + ":" + (text as NSString).substring(with: span.range)
        }
    }

    @Test func marksBoldItalicAndCode() {
        #expect(styled("a *bold* _it_ `code`") == ["b:*bold*", "i:_it_", "c:`code`"])
    }

    @Test func leavesInWordMarkersAlone() {
        #expect(styled("snake_case_name and 2*3*4").isEmpty)
    }

    @Test func markerFollowedBySpaceDoesNotOpen() {
        #expect(styled("a * b * c").isEmpty)
    }

    @Test func closerFollowedByALetterDoesNotClose() {
        #expect(styled("*bold*x") .isEmpty)
        #expect(styled("*bold*.") == ["b:*bold*"])
    }

    @Test func spansDoNotCrossLines() {
        #expect(styled("*one\ntwo*").isEmpty)
        #expect(styled("*one*\n*two*") == ["b:*one*", "b:*two*"])
    }

    @Test func adjacentMarkersDoNotOpen() {
        #expect(styled("** a **").isEmpty)
    }

    @Test func aLaterOpenerStillFindsItsCloserAfterAFailedSearch() {
        // The first `_` finds no closer on its line, so the `*` openers after it are searched on their own.
        #expect(styled("_a *b* c") == ["b:*b*"])
        #expect(styled("*a *b\n*c*") == ["b:*c*"])
    }

    // MARK: Strike and nesting

    @Test func marksStrike() {
        #expect(styled("a ~gone~ b") == ["s:~gone~"])
        #expect(styled("~one two~") == ["s:~one two~"])
    }

    @Test func strikeFollowsTheSameRulesAsTheOtherSpans() {
        #expect(styled("snake~case~name and 2~3~4").isEmpty)
        #expect(styled("a ~ b ~ c").isEmpty)
        #expect(styled("~~").isEmpty)
        #expect(styled("~never closed").isEmpty)
        #expect(styled("~one\ntwo~").isEmpty)
        #expect(styled("~gone~x").isEmpty)
        #expect(styled("~gone~.") == ["s:~gone~"])
        #expect(styled("~ gone~").isEmpty)
        #expect(styled("~gone ~").isEmpty)
    }

    @Test func spansNestOuterFirst() {
        #expect(styled("*bold _and italic_ bold*") == ["b:*bold _and italic_ bold*", "i:_and italic_"])
        #expect(styled("*_~all~_*") == ["b:*_~all~_*", "i:_~all~_", "s:~all~"])
        #expect(styled("_~a~ b_") == ["i:_~a~ b_", "s:~a~"])
    }

    @Test func nothingOpensInsideCode() {
        #expect(styled("`a *b* ~c~`") == ["c:`a *b* ~c~`"])
    }

    // MARK: Blocks

    private func blocks(_ text: String) -> [String] {
        MessageStyling.blocks(in: text).map { ($0.isPreformatted ? "pre" : "text") + "\($0.depth):" + $0.text }
    }

    @Test func aLineFencedOnBothEndsIsNotABlock() {
        #expect(blocks("```npm i```\nthen run it") == ["text0:```npm i```\nthen run it"])
        #expect(blocks("run\n```npm i```") == ["text0:run\n```npm i```"])
        #expect(blocks("> ```npm i```\n> then") == ["text1:```npm i```\nthen"])
        // A fence with a hint still opens one, and so does a bare one.
        #expect(blocks("```swift\nlet a = 1\n```") == ["pre0:let a = 1"])
        #expect(blocks("```\n```npm i```\n```") == ["pre0:```npm i```"])
    }

    @Test func quotesNestOnlyToTheCapAndDeeperMarkersStayText() {
        let deep = String(repeating: ">", count: MessageStyling.maxQuoteDepth + 3)
        let result = MessageStyling.blocks(in: "\(deep) hi")
        #expect(result.map(\.depth) == [MessageStyling.maxQuoteDepth])
        #expect(result.first?.text == "\(String(repeating: ">", count: 3)) hi")
        let huge = MessageStyling.blocks(in: String(repeating: ">", count: 60_000) + " x")
        #expect(huge.map(\.depth) == [MessageStyling.maxQuoteDepth])
    }

    @Test func aMessageIsSplitIntoBoundedBlocks() {
        let body = (0..<5_000).map { $0.isMultiple(of: 2) ? "> a" : ">> b" }.joined(separator: "\n")
        let result = MessageStyling.blocks(in: body)
        #expect(result.count == MessageStyling.maxBlocks + 1)
        #expect(result.last?.depth == 0)
        #expect(result.last?.isPreformatted == false)
        #expect(result.last?.text.split(separator: "\n").count == 5_000 - MessageStyling.maxBlocks)
    }

    @Test func aFenceOpensABlockAndALoneFenceClosesIt() {
        #expect(blocks("before\n```\nlet a = 1\n  b\n```\nafter") == ["text0:before", "pre0:let a = 1\n  b", "text0:after"])
    }

    @Test func theHintAfterTheFenceIsNotShown() {
        #expect(blocks("```swift\nlet a = 1\n```") == ["pre0:let a = 1"])
    }

    @Test func anUnclosedBlockRunsToTheEnd() {
        #expect(blocks("```\nfoo\nbar") == ["pre0:foo\nbar"])
        #expect(blocks("```\nfoo\n") == ["pre0:foo\n"])
    }

    @Test func nothingInsideABlockIsStyledOrQuoted() {
        #expect(blocks("```\n*a* > b\n> c\n```x\n```") == ["pre0:*a* > b\n> c\n```x"])
    }

    @Test func aFenceMidLineOrWithTrailingTextDoesNotClose() {
        #expect(blocks("a ```not a block```") == ["text0:a ```not a block```"])
        #expect(blocks("x```\ny") == ["text0:x```\ny"])
        #expect(blocks("```\na\n``` \nb\n```") == ["pre0:a\n``` \nb"])
    }

    @Test func anEmptyBlockShowsNothingSoTheTextAroundItJoins() {
        #expect(blocks("a\n```\n```\nb") == ["text0:a\nb"])
        #expect(blocks("```\n```") == ["text0:```\n```"])
    }

    @Test func aBlockInAQuoteEndsWithTheQuote() {
        #expect(blocks("> intro\n> ```\n> code\n> ```\n> outro\nplain") == ["text1:intro", "pre1:code", "text1:outro", "text0:plain"])
        #expect(blocks("> ```\n> code\nplain") == ["pre1:code", "text0:plain"])
        #expect(blocks("> ```\n> code\n>> deeper\n> ```") == ["pre1:code\n> deeper"])
    }

    @Test func aQuoteMarkerBeforeAFenceIsNotPartOfIt() {
        #expect(blocks(">```\nx") == ["text0:>```\nx"])
    }

    @Test func blocksWithoutDirectivesAreOneText() {
        #expect(blocks("a > b") == ["text0:a > b"])
    }

    // MARK: Equivalence with the straightforward algorithm

    /// The original scan, which looks for a closer from every opener.
    private func reference(_ text: String) -> [(NSRange, MessageStyling.SpanStyle)] {
        let markers: [Character: MessageStyling.SpanStyle] = ["*": .bold, "_": .italic, "`": .code, "~": .strike]
        var spans: [(NSRange, MessageStyling.SpanStyle)] = []
        var index = text.startIndex
        while index < text.endIndex {
            defer { index = text.index(after: index) }
            guard let style = markers[text[index]] else { continue }
            let marker = text[index]
            if index > text.startIndex, !text[text.index(before: index)].isWhitespace { continue }
            let afterOpen = text.index(after: index)
            guard afterOpen < text.endIndex, !text[afterOpen].isWhitespace, text[afterOpen] != marker else { continue }
            var end = afterOpen
            var closing: String.Index?
            while end < text.endIndex, !text[end].isNewline {
                if text[end] == marker, !text[text.index(before: end)].isWhitespace {
                    let next = text.index(after: end)
                    if next == text.endIndex || !text[next].isLetter && !text[next].isNumber {
                        closing = end
                        break
                    }
                }
                end = text.index(after: end)
            }
            guard let closing else { continue }
            spans.append((NSRange(index...closing, in: text), style))
            index = closing
        }
        return spans
    }

    private func sameSpans(_ text: String) -> Bool {
        // The reference has no nesting, so it's compared to the outermost spans.
        var outer: [(range: NSRange, style: MessageStyling.SpanStyle)] = []
        for span in MessageStyling.spans(in: text) where !(outer.last.map { NSIntersectionRange($0.range, span.range).length == span.range.length } ?? false) {
            outer.append(span)
        }
        let a = outer, b = reference(text)
        return a.count == b.count && zip(a, b).allSatisfy { $0.range == $1.0 && $0.style == $1.1 }
    }

    @Test func matchesTheReferenceOnFixedInputs() {
        for text in ["", "*", "*a", "*a*", " *a *b* c_ _d_", "a *b* c\n_d e_ `f`", "*a *b *c *d*", "_a_b_ _c_", "`a *b` c*", "😀 *é* _ü_"] {
            #expect(sameSpans(text), "\(text.debugDescription)")
        }
    }

    @Test func matchesTheReferenceOnRandomStrings() {
        var generator = SeededGenerator(seed: 42)
        let alphabet = Array("* _`~a \n.")
        for _ in 0..<500 {
            let text = String((0..<Int.random(in: 0...24, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            #expect(sameSpans(text), "\(text.debugDescription)")
        }
    }

    // MARK: Hostile input

    @Test(arguments: [" *a", " _a", " `a", " ~a"], [20_000, 85_000])
    func unclosedOpenersTakeLinearTime(unit: String, count: Int) {
        let text = String(repeating: unit, count: count)
        let clock = ContinuousClock()
        let time = clock.measure { _ = MessageStyling.spans(in: text) }
        #expect(time < .milliseconds(500), "\(count) x \(unit.debugDescription) took \(time)")
    }

    @Test func manyMarkersWithoutBreaksTakeLinearTime() {
        let clock = ContinuousClock()
        for text in [String(repeating: "*", count: 256_000), String(repeating: "* ", count: 128_000), String(repeating: " *a*", count: 64_000), String(repeating: " *a\n", count: 64_000)] {
            let time = clock.measure { _ = MessageStyling.spans(in: text) }
            #expect(time < .milliseconds(500), "\(time)")
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
