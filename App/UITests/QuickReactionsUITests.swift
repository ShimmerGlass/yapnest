import XCTest

/// The long-press menu offers the reactions the account has learned.
@MainActor
final class QuickReactionsUITests: XCTestCase {
    func testTheMenuShowsTheLearnedRow() throws {
        let driver = ConversationDriver(fixture: "learned-reactions", open: "reactions@fixture.test", context: "learned-reactions")
        driver.waitForOpenChat()
        let message = driver.app.staticTexts["Long-press this one."].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 1.0)

        let learned = ["🔥", "🎉", "😢", "🙏", "👍"]
        let buttons = learned.map { driver.app.descendants(matching: .any).matching(identifier: $0).firstMatch }
        for (emoji, button) in zip(learned, buttons) {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(emoji) isn't in the row")
        }
        let xs = buttons.map(\.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "the row isn't in rank order")
        XCTAssertFalse(driver.app.descendants(matching: .any).matching(identifier: "😮").firstMatch.exists, "a default that was ranked out is still offered")

        let attachment = XCTAttachment(screenshot: driver.app.screenshot())
        attachment.name = "learned-row"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["YAPNEST_SCREENSHOT_DIR"] {
            try? driver.app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("learned-row.png"))
        }
    }
}
