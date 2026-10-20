import XCTest

/// A bubble's long-press menu and swipe to reply, in the message list as the
/// phone draws it, upside down. What the lift looks like isn't asserted here;
/// it's a transient, and checked by recording the screen.
@MainActor
final class MessageMenuUITests: XCTestCase {
    private var driver: ConversationDriver!

    override func setUp() async throws {
        continueAfterFailure = false
        driver = ConversationDriver(fixture: "learned-reactions", open: "reactions@fixture.test", context: "message menu")
        driver.waitForOpenChat()
        driver.settle()
    }

    private func action(_ name: String) -> XCUIElement {
        driver.app.buttons[name].firstMatch
    }

    func testLongPressOnAReceivedMessageOffersItsActions() {
        driver.app.staticTexts["Long-press this one."].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(action("Reply").waitForExistence(timeout: 5), "no Reply in the menu")
        XCTAssertTrue(action("Copy").exists, "no Copy in the menu")
        XCTAssertFalse(action("Delete for Everyone").exists, "a message that isn't ours offers deleting it")
    }

    func testLongPressOnOurOwnMessageOffersEditingAndDeleting() {
        driver.app.staticTexts["Three eggs now!"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(action("Reply").waitForExistence(timeout: 5), "no Reply in the menu")
        XCTAssertTrue(action("Edit").exists, "no Edit in the menu")
        XCTAssertTrue(action("Delete for Everyone").exists, "no Delete for Everyone in the menu")
    }

    func testReplyFromTheMenuQuotesTheMessage() {
        let message = driver.app.staticTexts["Long-press this one."].firstMatch
        XCTAssertEqual(driver.app.staticTexts.matching(identifier: "Long-press this one.").count, 1, "the message is drawn more than once before replying")
        message.press(forDuration: 1.0)
        action("Reply").tap()
        // The composer's reply bar repeats the text, so it's now drawn twice.
        let both = NSPredicate(format: "count >= 2")
        let quoted = XCTNSPredicateExpectation(predicate: both, object: driver.app.staticTexts.matching(identifier: "Long-press this one."))
        XCTAssertEqual(XCTWaiter.wait(for: [quoted], timeout: 5), .completed, "the reply bar didn't come up")
    }

    func testSwipingAMessageStartsAReply() {
        let message = driver.app.staticTexts["Long-press this one."].firstMatch
        XCTAssertEqual(driver.app.staticTexts.matching(identifier: "Long-press this one.").count, 1, "the message is drawn more than once before replying")
        let start = message.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)))
        let both = NSPredicate(format: "count >= 2")
        let quoted = XCTNSPredicateExpectation(predicate: both, object: driver.app.staticTexts.matching(identifier: "Long-press this one."))
        XCTAssertEqual(XCTWaiter.wait(for: [quoted], timeout: 5), .completed, "swiping the message didn't start a reply")
    }
}
