import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

/// What a user would see: which stretches of a message are links or styled,
/// and what is left as plain text.
@MainActor
struct MessageTextTests {
    struct Run: Equatable {
        var text: String
        var link: String?
        var font: Font?
    }

    private func runs(_ body: String, kind: MessageText.Kind = .normal) -> [[Run]] {
        MessageText.render(body, kind: kind).segments.map { segment in
            segment.text.runs.map { run in
                Run(text: String(segment.text[run.range].characters), link: run.link?.absoluteString, font: run.font)
            }
        }
    }

    private func links(_ body: String) -> [String] {
        runs(body).flatMap { $0 }.compactMap { $0.link == nil ? nil : $0.text }
    }

    @Test func theRenderedTextKeepsItsLinksForTheMenu() {
        let rendered = MessageText.render("see https://example.com/a and\n> https://example.org/b\n```\nhttps://example.net/c\n```", kind: .normal)
        #expect(rendered.links.map(\.absoluteString) == ["https://example.com/a", "https://example.org/b", "https://example.net/c"])
        // In the bubble the code block's address stays text.
        #expect(rendered.segments.last?.text.runs.allSatisfy { $0.link == nil } == true)
    }

    private func styled(_ body: String, _ font: Font) -> [String] {
        runs(body).flatMap { $0 }.filter { $0.font == font && $0.link == nil }.map(\.text)
    }

    // MARK: Links

    @Test func aLinkIsOnlyTheAddress() {
        #expect(links("see https://example.com/page now") == ["https://example.com/page"])
    }

    @Test(arguments: [
        ("visit https://example.com.", "https://example.com"),
        ("go to https://example.com/a, then", "https://example.com/a"),
        ("(https://example.com/a)", "https://example.com/a"),
        ("\"https://example.com/a\"", "https://example.com/a"),
    ])
    func punctuationAfterALinkIsNotPartOfIt(body: String, link: String) {
        #expect(links(body) == [link])
    }

    @Test func schemesThatCouldRunSomethingStayText() {
        #expect(links("ftp://example.com/file javascript:alert(1) tel:+3312345678").isEmpty)
    }

    @Test func mailAddressesAreLinks() {
        #expect(links("write to me@example.com please") == ["me@example.com"])
    }

    @Test func aLinkAfterWideCharactersIsStillFoundWhereItIs() {
        // Emoji take two UTF-16 units, which the detector counts in.
        #expect(links("👍🏽👍🏽 https://example.com/x 🎉") == ["https://example.com/x"])
    }

    // MARK: Quotes

    @Test func quoteMarkersAreDroppedAndDepthsSplitTheBlocks() {
        let blocks = MessageStyling.blocks(in: "> one\n> two\nplain\n>> deep\n> back")
        #expect(blocks.map(\.text) == ["one\ntwo", "plain", "deep", "back"])
        #expect(blocks.map(\.depth) == [1, 0, 2, 1])
    }

    @Test func aMarkerNeedsASpaceOrTheEndOfTheLine() {
        let blocks = MessageStyling.blocks(in: ">not a quote\n>\n> real")
        // ">" alone is an empty quoted line, joined to the one after it.
        #expect(blocks.map(\.text) == [">not a quote", "\nreal"])
        #expect(blocks.map(\.depth) == [0, 1])
    }

    @Test func textWithoutAMarkerIsOneUnquotedBlock() {
        let blocks = MessageStyling.blocks(in: "a > b")
        #expect(blocks.map(\.text) == ["a > b"])
        #expect(blocks.map(\.depth) == [0])
    }

    @Test func eachQuoteDepthIsItsOwnSegmentWithStylingInside() {
        let rendered = MessageText.render("> a *bold* quote\nreply", kind: .normal)
        #expect(rendered.segments.map(\.depth) == [1, 0])
        #expect(styled("> a *bold* quote\nreply", Font.body.bold()) == ["*bold*"])
    }

    // MARK: Long bodies

    @Test func aBodyThatFitsIsNotCollapsed() {
        let body = (1...MessageText.collapsedLineLimit).map { "line \($0)" }.joined(separator: "\n")
        #expect(MessageText.collapse(body) == nil)
        #expect(!MessageText.render(body, kind: .normal, collapsed: true).isCollapsed)
    }

    @Test func aBodyWithTooManyLinesIsCutAfterTheLimit() throws {
        let body = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let start = try #require(MessageText.collapse(body))
        #expect(start.split(separator: "\n").count == MessageText.collapsedLineLimit)
        #expect(start.hasPrefix("line 1\nline 2\n"))
        #expect(start.hasSuffix("line \(MessageText.collapsedLineLimit)…"))
    }

    @Test func aLongParagraphIsCutAtAWord() throws {
        let body = String(repeating: "word ", count: 400)
        let start = try #require(MessageText.collapse(body))
        #expect(start.count <= MessageText.collapsedCharacterLimit + 1)
        #expect(start.hasSuffix("word…"))
    }

    @Test func aLongUnbrokenTokenIsCutAtTheLimit() throws {
        let start = try #require(MessageText.collapse(String(repeating: "x", count: 5000)))
        #expect(start.count == MessageText.collapsedCharacterLimit + 1)
    }

    /// A code block whose closing fence is the last line that fits, quoted to `depth`.
    @Test(arguments: [0, 1, 2])
    func aCutRightAfterAClosingFenceKeepsTheDotsOutOfTheBlock(depth: Int) throws {
        let marker = depth == 0 ? "" : String(repeating: ">", count: depth) + " "
        let lines = [marker + "```"] + (1...(MessageText.collapsedLineLimit - 2)).map { marker + "code \($0)" } + [marker + "```"]
        let body = (lines + ["after", "more"]).joined(separator: "\n")
        let start = try #require(MessageText.collapse(body))
        #expect(start.hasSuffix("\(marker)```\n…"))
        let rendered = MessageText.render(body, kind: .normal, collapsed: true)
        let block = try #require(rendered.segments.first)
        #expect(block.isPreformatted)
        #expect(!String(block.text.characters).contains("…"))
        #expect(rendered.segments.last.map { String($0.text.characters) } == "…")
    }

    @Test func collapsingOnlyShowsTheStartAndOpeningShowsAll() {
        let body = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let collapsed = MessageText.render(body, kind: .normal, collapsed: true)
        #expect(collapsed.isCollapsed)
        #expect(!String(collapsed.segments[0].text.characters).contains("line 40"))
        let whole = MessageText.render(body, kind: .normal)
        #expect(!whole.isCollapsed)
        #expect(String(whole.segments[0].text.characters).contains("line 40"))
    }

    // MARK: Styling

    @Test func boldItalicAndCodeGetTheirFont() {
        #expect(styled("*b* and _i_ and `c`", Font.body.bold()) == ["*b*"])
        #expect(styled("*b* and _i_ and `c`", Font.body.italic()) == ["_i_"])
        #expect(styled("*b* and _i_ and `c`", Font.body.monospaced()) == ["`c`"])
    }

    @Test(arguments: [
        "*never closed",
        "snake_case_name",
        "2*3*4",
        "* spaced *",
        "**",
        "*bold*s",
        "*two\nlines*",
    ])
    func textThatOnlyLooksStyledStaysPlain(body: String) {
        #expect(runs(body).flatMap { $0 }.allSatisfy { $0.font == Font.body })
    }

    @Test func aStyleInsideAnotherAddsToIt() {
        let found = runs("*bold _and more_ bold*").flatMap { $0 }
        #expect(found.map(\.text) == ["*bold ", "_and more_", " bold*"])
        #expect(found.map(\.font) == [Font.body.bold(), Font.body.bold().italic(), Font.body.bold()])
    }

    @Test func strikeKeepsTheFontAndCrossesTheTextOut() {
        let rendered = MessageText.render("a ~gone~ b", kind: .normal).segments[0].text
        let struck = rendered.runs.filter { $0.strikethroughStyle != nil }.map { String(rendered[$0.range].characters) }
        #expect(struck == ["~gone~"])
        #expect(rendered.runs.allSatisfy { $0.font == Font.body })
    }

    // MARK: Preformatted blocks

    @Test func aPreformattedBlockIsItsOwnVerbatimMonospacedSegment() {
        let body = "see\n```swift\nlet a = *1* https://example.com\n```\nok"
        let rendered = MessageText.render(body, kind: .normal)
        #expect(rendered.segments.map(\.isPreformatted) == [false, true, false])
        #expect(rendered.segments.map { String($0.text.characters) } == ["see", "let a = *1* https://example.com", "ok"])
        let code = rendered.segments[1].text.runs
        #expect(code.count == 1)
        #expect(code.allSatisfy { $0.font == Font.body.monospaced() && $0.link == nil })
    }

    @Test func aBlockInAQuoteKeepsItsDepth() {
        let rendered = MessageText.render("> ```\n> code\n> ```", kind: .normal)
        #expect(rendered.segments.map(\.depth) == [1])
        #expect(rendered.segments.map(\.isPreformatted) == [true])
    }

    @Test func aCutInsideABlockStillDrawsTheBlock() throws {
        let body = "```\n" + (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        let rendered = MessageText.render(body, kind: .normal, collapsed: true)
        #expect(rendered.isCollapsed)
        #expect(rendered.segments.count == 1)
        #expect(rendered.segments[0].isPreformatted)
        #expect(String(rendered.segments[0].text.characters).hasSuffix("line 13…"))
    }

    @Test func dotsAfterTheClosingFenceDoNotBecomeCode() throws {
        let body = "```\n" + (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n```\n" + (1...20).map { "after \($0)" }.joined(separator: "\n")
        let start = try #require(MessageText.collapse(body))
        #expect(start.hasSuffix("```\n…"))
        let rendered = MessageText.render(body, kind: .normal, collapsed: true)
        #expect(rendered.segments.map(\.isPreformatted) == [true, false])
    }

    @Test func aLinkIsNotRestyledByMarkersThatCrossIt() {
        let found = runs("_see https://example.com/a_b_ now").flatMap { $0 }
        #expect(found.filter { $0.link != nil }.map(\.text) == ["https://example.com/a_b_"])
        #expect(found.filter { $0.link != nil }.allSatisfy { $0.font == Font.body })
    }

    // MARK: Emoji

    @Test(arguments: [
        ("👍", 1), ("👍👍👍", 3), ("🇫🇷", 1), ("👨‍👩‍👧", 1), ("❤️", 1), ("  🎉🎉 \n", 2), ("1️⃣", 1),
        ("👍👍👍👍👍👍", 6),
    ])
    func emojiOnlyTextCountsItsEmoji(body: String, count: Int) {
        #expect(MessageText.emojiOnlyCount(body) == count)
    }

    @Test(arguments: ["", "   ", "hi 👍", "1", "©", "👍👍👍👍👍👍👍", "👍 a"])
    func anythingElseIsNotEmojiOnly(body: String) {
        #expect(MessageText.emojiOnlyCount(body) == nil)
    }

    @Test func fewEmojiAreDrawnLargerThanMany() {
        #expect(runs("👍👍👍").first?.first?.font == MessageText.BodyFont.scaled(56, like: .largeTitle).swiftUI)
        #expect(runs("👍👍👍👍").first?.first?.font == MessageText.BodyFont.scaled(40, like: .title1).swiftUI)
        #expect(runs("good 👍").first?.first?.font == Font.body)
    }

    // MARK: Other kinds, and text that isn't left to right

    @Test func aMessageThatCouldNotBeDecryptedNeverShowsItsBody() {
        let shown = runs("secret", kind: .undecryptable).flatMap { $0 }.map(\.text).joined()
        #expect(!shown.contains("secret"))
        #expect(!shown.isEmpty)
    }

    @Test func aDeletedMessageSaysWhoDeletedIt() {
        let mine = runs("old text", kind: .retracted(outgoing: true)).flatMap { $0 }.map(\.text).joined()
        let theirs = runs("old text", kind: .retracted(outgoing: false)).flatMap { $0 }.map(\.text).joined()
        #expect(mine != theirs)
        #expect(!mine.contains("old text") && !theirs.contains("old text"))
    }

    @Test func aModeratedMessageSaysAModeratorRemovedItAndNothingElse() {
        let shown = runs("old text", kind: .moderated).flatMap { $0 }.map(\.text).joined()
        #expect(shown == "Removed by a moderator")
    }

    @Test func anActionReadsAsTheNameThenWhatTheyDo() {
        let shown = runs("/me waves", kind: .action(name: "Alice")).flatMap { $0 }
        #expect(shown.map(\.text).joined() == "Alice waves")
        #expect(shown.allSatisfy { $0.font == Font.body.italic() })
    }

    @Test func rightToLeftTextKeepsItsLinksAndStyles() {
        let body = "مرحبا *عالم* https://example.com/ar ثم _نص_"
        #expect(links(body) == ["https://example.com/ar"])
        #expect(styled(body, Font.body.bold()) == ["*عالم*"])
        #expect(styled(body, Font.body.italic()) == ["_نص_"])
    }

    @Test func mixedDirectionTextKeepsEveryCharacter() {
        let body = "שלום world `code` שלום"
        let shown = runs(body).flatMap { $0 }.map(\.text).joined()
        #expect(shown == body)
        #expect(styled(body, Font.body.monospaced()) == ["`code`"])
    }

    @Test func aHugeMessageWithOnlyOpenersIsRenderedWithoutStyles() {
        let body = String(repeating: "_a *b `c ", count: 20_000)
        let rendered = runs(body).flatMap { $0 }
        #expect(rendered.allSatisfy { $0.font == Font.body })
    }

    @Test func blankLinesAroundATextAreNotDrawn() {
        let body = String(repeating: "\n", count: 50_000) + "hello\n \n" + String(repeating: "\n", count: 50_000)
        #expect(runs(body).flatMap { $0 }.map(\.text).joined() == "hello")
    }
}
