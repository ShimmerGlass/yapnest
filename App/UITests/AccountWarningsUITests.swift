import XCTest

/// The warnings above the chat list, on the `warnings` fixture: one row for
/// all of them, the details behind it, and Retry clearing the one it ran.
@MainActor
final class AccountWarningsUITests: XCTestCase {
    func testWarningsShowDetailsAndRetryClearsOne() {
        continueAfterFailure = false
        let driver = ConversationDriver(fixture: "warnings", context: name)
        let app = driver.app
        let banner = app.descendants(matching: .any)["accountWarnings"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no warning above the list")
        XCTAssertTrue(banner.label.contains("1 more"), "the row doesn't count the other warning: \(banner.label)")
        banner.tap()
        XCTAssertTrue(app.staticTexts["The server refused the setting: Not allowed here (forbidden)"].waitForExistence(timeout: 5), "the sheet lacks the detail")
        let retries = app.buttons.matching(identifier: "accountWarningRetry")
        XCTAssertEqual(retries.count, 1, "only the profile warning can be retried")
        let retry = retries.firstMatch
        retry.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "Retry didn't clear the warning")
        XCTAssertTrue(app.staticTexts["A privacy setting wasn't saved"].exists)
        let dismiss = app.buttons.matching(identifier: "accountWarningDismiss").firstMatch
        dismiss.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["A privacy setting wasn't saved"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, "Dismiss didn't remove the warning")
    }
}
