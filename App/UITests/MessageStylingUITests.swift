import XCTest

/// Strikethrough, nested spans and preformatted blocks in the Styling chat of
/// the `interactions` fixture: the code is shown as written, and the list
/// scrolls through the taller rows without a jump or a blank.
final class MessageStylingUITests: InteractionsTestCase {
    override var chat: String? { "styling@fixture.test" }

    func testCodeIsShownAsWrittenAndTheListScrollsThroughIt() {
        let newest = driver.message(containing: "Styling ends here.")
        driver.assertShown(newest, "after opening")
        driver.assertHeldAtBottom("while opening")

        // Nothing inside a block is styled, and the fences are not shown.
        var seen = Set<String>()
        let expected = ["let nest = Nest()", "nest.hatch()", "still code *not bold* ~not struck~", "quoted code", "struck out"]
        driver.resetRecorder()
        for _ in 0..<12 {
            for words in expected where driver.text(containing: words).exists { seen.insert(words) }
            XCTAssertFalse(driver.text(containing: "```").exists, "a fence is on screen")
            driver.assertNotBlank("while scrolling up")
            if seen.count == expected.count { break }
            driver.flickTowardsOlder()
            driver.settle(0.8)
        }
        XCTAssertEqual(seen, Set(expected), "some code or styled text never showed as written")
        XCTAssertLessThanOrEqual(driver.recorder()["maxPrependShift"] ?? 0, 2, driver.recorderSummary())

        if driver.scrollToLatestButton.waitForExistence(timeout: 2) {
            driver.scrollToLatestButton.tap()
            driver.settle(1.5)
            driver.waitForStillness()
        }
        driver.assertShown(newest, "after scrolling back to the latest message")
    }

    func testShowMoreOnALongBlockOpensTheRestOfIt() {
        let lastLine = "block line 40"
        let more = app.buttons["Show more"]
        for _ in 0..<12 where !(more.exists && more.isHittable) {
            driver.flickTowardsOlder()
            driver.settle(0.8)
        }
        XCTAssertTrue(more.exists, "the long block has no Show more")
        XCTAssertFalse(driver.text(containing: lastLine).exists, "the whole block is shown before Show more")
        more.tap()
        XCTAssertTrue(driver.text(containing: lastLine).waitForExistence(timeout: 5), "Show more didn't open the block")
        driver.assertNotBlank("after Show more")
    }
}
