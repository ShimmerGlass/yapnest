import XCTest

/// A chat with a few dozen unread messages opens at the first of them, not
/// at the bottom. The list is hidden while it finds that place, and shown as
/// soon as it has: a fixed wait there kept it blank for over half a second.
@MainActor
final class OpeningAtUnreadUITests: XCTestCase {
    private var driver: ConversationDriver!

    override func setUp() async throws {
        continueAfterFailure = false
        driver = ConversationDriver(fixture: "unread", open: "unread@fixture.test", context: "unread")
        driver.waitForOpenChat()
    }

    func testOpensAtTheFirstUnreadMessage() {
        let firstUnread = driver.message(containing: "Unread 0260")
        XCTAssertTrue(firstUnread.waitForExistence(timeout: ConversationDriver.contentTimeout), "the first unread message never showed")
        driver.waitForStillness()

        let app = driver.app
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = driver.composer.frame.minY
        XCTAssertTrue(firstUnread.isHittable, "the first unread message can't be reached: \(driver.recorderSummary())")
        XCTAssertGreaterThanOrEqual(firstUnread.frame.minY, top - 1, "the first unread message starts under the bars: \(firstUnread.frame)")
        XCTAssertLessThan(firstUnread.frame.minY, bottom, "the first unread message is below the composer: \(firstUnread.frame)")
        XCTAssertTrue(app.staticTexts["Unread messages"].isHittable, "no unread divider on screen")
        XCTAssertFalse(driver.message(containing: "Unread 0299").isHittable, "the chat opened at its newest message")
        driver.assertNotBlank("after opening at the unread messages")
    }
}
