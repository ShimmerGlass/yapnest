import XCTest

/// An offline contact's header says when they were last seen while the user
/// shares their own last seen, and says nothing once they stop. The
/// fixture's session never connects, so what shows is what it stored.
@MainActor
final class LastSeenUITests: XCTestCase {
    private func lastSeen(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last seen")).firstMatch
    }

    func testTheHeaderSaysWhenAnOfflineContactWasLastSeen() {
        let driver = ConversationDriver(fixture: "last-seen", open: "wren@fixture.test", context: name)
        driver.waitForOpenChat()
        let text = lastSeen(driver.app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "no last seen in the header")
        XCTAssertTrue(text.label.contains("2 hours ago"), text.label)
    }

    func testTurningLastSeenOffRemovesIt() {
        let driver = ConversationDriver(fixture: "last-seen", context: name)
        let app = driver.app
        driver.openSettings()
        let toggle = app.switches["Last Seen"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no Last Seen setting")
        XCTAssertEqual(toggle.value as? String, "1", "the fixture shares last seen")
        toggle.switches.firstMatch.tap()
        let off = NSPredicate(format: "value == %@", "0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: off, object: toggle)], timeout: 10), .completed, "the switch didn't turn off")
        app.buttons["Done"].tap()

        driver.openChat("Wren")
        XCTAssertTrue(app.staticTexts["offline"].firstMatch.waitForExistence(timeout: 10), "the header should say offline")
        XCTAssertFalse(lastSeen(app).exists, "last seen is still shown")
    }
}
