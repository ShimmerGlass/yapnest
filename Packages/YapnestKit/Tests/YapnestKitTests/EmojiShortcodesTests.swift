import Foundation
import Testing
@testable import YapnestKit

@Suite struct EmojiShortcodesTests {
    private let shortcodes = EmojiShortcodes(tsv: """
    😀\tgrinning\tsmile,happy
    😄\tsmile\thappy,joy
    🙂\tslightly_smiling_face\tsmile
    😸\tsmile_cat\t
    ❤️\theart\tlove
    👍\t+1,thumbsup\tapprove
    🐱\tcat\tpet
    """)

    private func trigger(_ text: String, cursor: Int? = nil) -> EmojiShortcodes.Trigger? {
        EmojiShortcodes.trigger(in: text, cursor: cursor ?? (text as NSString).length)
    }

    @Test func triggersAtStartAndAfterSpaceOrBracket() {
        #expect(trigger(":sm")?.query == "sm")
        #expect(trigger("hello :sm")?.range == NSRange(location: 6, length: 3))
        #expect(trigger("(:sm")?.query == "sm")
        #expect(trigger("a\n:sm")?.query == "sm")
    }

    @Test func ignoresTimesUrlsAndWordColons() {
        #expect(trigger("10:30") == nil)
        #expect(trigger("see http://x") == nil)
        #expect(trigger("a:bc") == nil)
        #expect(trigger("::sm") == nil)
    }

    @Test func needsTwoCharacters() {
        #expect(trigger(":s") == nil)
        #expect(trigger(":") == nil)
        #expect(trigger(":+1")?.query == "+1")
    }

    @Test func endsAtSpaceAndFollowsTheCursor() {
        #expect(trigger(":sm ") == nil)
        #expect(trigger(":smile and more", cursor: 6)?.query == "smile")
        #expect(trigger(":sm", cursor: 1) == nil)
    }

    @Test func prefixMatchesComeBeforeContainsAndKeywords() {
        let results = shortcodes.matches(for: "smile").map(\.shortcode)
        // Prefix: smile, smile_cat; contains: slightly_smiling_face has no
        // "smile"; keyword: grinning, via "smile".
        #expect(results == ["smile", "smile_cat", "grinning", "slightly_smiling_face"])
        #expect(shortcodes.matches(for: "cat").map(\.shortcode) == ["cat", "smile_cat"])
    }

    @Test func shorterShortcodesComeFirst() {
        #expect(shortcodes.matches(for: "sm").map(\.shortcode).prefix(2) == ["smile", "smile_cat"])
    }

    @Test func recentEmojiAreBoostedWithinAGroup() {
        let results = shortcodes.matches(for: "smile", recents: ["😸"]).map(\.shortcode)
        #expect(results.prefix(2) == ["smile_cat", "smile"])
    }

    @Test func tooShortQueryAndLimit() {
        #expect(shortcodes.matches(for: "s").isEmpty)
        #expect(shortcodes.matches(for: "sm", limit: 1).count == 1)
    }

    @Test func replacesAnExactCompletedCode() {
        let text = "hi :smile:"
        let replacement = shortcodes.completedShortcode(in: text, cursor: 10)
        #expect(replacement?.emoji == "😄")
        #expect(replacement?.range == NSRange(location: 3, length: 7))
        #expect(shortcodes.completedShortcode(in: ":smil:", cursor: 6) == nil)
        #expect(shortcodes.completedShortcode(in: "a:smile:", cursor: 8) == nil)
        #expect(shortcodes.completedShortcode(in: ":+1:", cursor: 4)?.emoji == "👍")
    }

    @Test func bundledDataLoads() {
        let results = EmojiShortcodes.shared.matches(for: "thumbsup")
        #expect(results.first?.emoji == "👍")
        #expect(EmojiShortcodes.shared.completedShortcode(in: ":smile:", cursor: 7)?.emoji == "😄")
    }
}
