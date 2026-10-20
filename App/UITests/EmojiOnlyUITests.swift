import XCTest

/// A message of nothing but emoji is drawn without a bubble, and still has
/// its time and status and its menu. The `interactions` fixture's Emoji chat
/// holds one in each direction and one as a reply, which keeps its bubble.
@MainActor
final class EmojiOnlyUITests: InteractionsTestCase {
    override var chat: String? { "emoji@fixture.test" }

    func testEmojiAloneAreShownInBothDirectionsWithTheirTimes() {
        XCTAssertTrue(driver.text(containing: "🪺🐣").waitForExistence(timeout: 10), "the received emoji isn't shown")
        XCTAssertTrue(driver.text(containing: "🥚").exists, "the sent emoji isn't shown")
        XCTAssertTrue(driver.text(containing: "🐦").exists, "the emoji reply isn't shown")
        // The time is part of the caption under the emoji, as a text of its own.
        let times = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"^\d{1,2}[:.]\d{2}(\s?[AP]M)?$"#))
        XCTAssertGreaterThanOrEqual(times.count, 3, "the emoji messages' times aren't readable")
    }

    func testTheMenuOpensOnAnEmojiWithoutABubble() {
        openMenu(on: "🪺🐣")
        XCTAssertTrue(app.buttons["Copy"].exists, "no Copy in the menu")
    }

    func testTheMenuOpensOnOurOwnEmoji() {
        openMenu(on: "🥚")
        XCTAssertTrue(app.buttons["Edit"].exists, "no Edit in the menu")
    }
}
