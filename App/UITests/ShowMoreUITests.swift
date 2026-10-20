import XCTest

/// A long message is shown cut short behind "Show more", and opened by it.
/// The `interactions` fixture's Long chat ends in a 30 line message and
/// Wordy has one above two short ones (`InteractionsFixture.longBody`).
@MainActor
final class ShowMoreUITests: InteractionsTestCase {
    override var chat: String? { "long@fixture.test" }

    private let firstLine = "Line 01 of a message that runs on."
    private let lastLine = "Line 30 is where it finally ends."

    private func showMore(_ app: XCUIApplication) -> XCUIElement { app.buttons["Show more"].firstMatch }

    func testALongMessageIsCutShortBehindShowMore() {
        XCTAssertTrue(showMore(app).waitForExistence(timeout: 10), "the long message has no Show more button")
        XCTAssertEqual(app.buttons.matching(identifier: "Show more").count, 1, "the short message has a Show more button too")
        XCTAssertTrue(driver.text(containing: firstLine).exists, "the start of the long message isn't shown")
        XCTAssertFalse(driver.text(containing: lastLine).exists, "the end of the long message is shown before Show more")
        XCTAssertTrue(bubble("Just a short one.").exists)
    }

    func testShowMoreOpensTheWholeMessageAndTheListStaysAtTheNewestEnd() {
        let newest = driver.message(containing: firstLine)
        driver.assertShown(newest, "with the message cut short")
        driver.resetRecorder()
        showMore(app).tap()
        XCTAssertTrue(driver.text(containing: lastLine).waitForExistence(timeout: 10), "the end of the message didn't show after Show more")
        waitUntilGone(showMore(app), "the Show more button")
        driver.settle()
        driver.waitForStillness()
        driver.assertShown(newest, "after Show more")
        driver.assertHeldAtBottom("while the message grew")
    }

    /// The long message is above two short ones, so it grows off to one side
    /// of the newest end and the list must not be moved by it.
    func testAMessageAboveOthersOpensWithoutMovingTheListFromTheNewest() {
        app.terminate()
        let wordy = ConversationDriver(fixture: "interactions", open: "wordy@fixture.test", context: name)
        wordy.waitForOpenChat()
        wordy.waitForStillness()
        let newest = wordy.message(containing: "Wordy newest.")
        wordy.assertShown(newest, "before Show more")
        wordy.resetRecorder()
        showMore(wordy.app).tap()
        XCTAssertTrue(wordy.text(containing: lastLine).waitForExistence(timeout: 10), "the end of the message didn't show after Show more")
        wordy.settle()
        wordy.waitForStillness()
        wordy.assertShown(newest, "after Show more")
        wordy.assertHeldAtBottom("while the message grew")
        XCTAssertFalse(showMore(wordy.app).exists, "Show more is still there")
    }

    /// VoiceOver reads the row's label. It holds the whole message and not
    /// the cut text with its ellipsis: someone who can't see the cut would
    /// otherwise hear a message that stops mid-sentence.
    func testTheCutMessageIsReadWhole() {
        let row = driver.message(containing: lastLine)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no element reads the end of the message")
        XCTAssertFalse(row.label.contains("…"), "the label ends in the cut: \(row.label)")
        XCTAssertTrue(row.label.contains(firstLine))
    }

    /// Show more and Show link preview share the footer's line: the button's
    /// middle is where the time's is, about 13 points above the bubble's
    /// bottom edge (its 6 point padding and half the footer), not a line higher.
    private func assertOnFooterLine(_ button: XCUIElement, in row: XCUIElement, _ what: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(what)")
        let fromBottom = row.frame.maxY - button.frame.midY
        XCTAssertEqual(fromBottom, 13, accuracy: 6, "\(what) isn't on the footer's line: its middle is \(fromBottom) above the bottom of \(row.frame)")
    }

    func testShowMoreSitsOnTheFootersLine() {
        XCTAssertTrue(showMore(app).waitForExistence(timeout: 10))
        assertOnFooterLine(showMore(app), in: driver.message(containing: firstLine), "Show more")
    }

    func testShowLinkPreviewSitsOnTheFootersLine() {
        app.terminate()
        let nest = ConversationDriver(fixture: "interactions", open: "nest@fixture.test", context: name)
        nest.waitForOpenChat()
        nest.waitForStillness()
        let buttons = nest.app.buttons.matching(identifier: "Show link preview")
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10), "the link has no Show link preview button")
        let row = nest.message(containing: "nest-notes")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // The chat holds other links, each with a button of its own.
        guard let button = buttons.allElementsBoundByIndex.first(where: { row.frame.contains($0.frame.origin) }) else {
            return XCTFail("the link's row has no Show link preview button: \(buttons.allElementsBoundByIndex.map(\.frame)) against \(row.frame)")
        }
        assertOnFooterLine(button, in: row, "Show link preview")
    }
}
