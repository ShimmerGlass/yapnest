import XCTest

/// The welcome screen after a first sign-in, forced on a fixture with
/// `YAPNEST_DEV_WELCOME`. Fixtures never show it otherwise.
@MainActor
final class WelcomeUITests: XCTestCase {
    func testTheWelcomeShowsItsSwitchesAndContinueClosesIt() {
        let driver = ConversationDriver(fixture: "interactions", environment: ["YAPNEST_DEV_WELCOME": "1"], context: name)
        let app = driver.app
        let encrypt = app.switches["Encrypt New Chats"]
        XCTAssertTrue(encrypt.waitForExistence(timeout: 20), "the welcome screen isn't shown")
        XCTAssertTrue(app.switches["Send Read Receipts"].exists)
        XCTAssertTrue(app.switches["Send Typing Indicator"].exists)
        XCTAssertTrue(app.switches["Last Seen"].exists)

        let before = encrypt.value as? String
        encrypt.switches.firstMatch.tap()
        XCTAssertNotEqual(encrypt.value as? String, before, "the switch didn't change")

        let done = app.buttons["welcomeContinue"]
        XCTAssertTrue(done.isEnabled)
        done.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: encrypt)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "Continue didn't close the welcome screen")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10), "the chat list isn't back")
    }

    func testFixturesDoNotShowItByDefault() {
        let driver = ConversationDriver(fixture: "interactions", context: name)
        XCTAssertTrue(driver.app.buttons["Settings"].waitForExistence(timeout: 20))
        XCTAssertFalse(driver.app.switches["Encrypt New Chats"].exists)
    }
}
