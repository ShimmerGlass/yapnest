import XCTest

/// `xmpp:` links opened from outside the app, on the `interactions`
/// fixture, whose account is offline: these check what the app shows for a
/// link, not the server's answer to it.
final class XMPPLinkUITests: InteractionsTestCase {
    override var chat: String? { nil }

    private func open(_ link: String) {
        app.open(URL(string: link)!)
    }

    func testALinkToAContactOpensTheChatWithTheBodyInTheComposer() {
        open("xmpp:nest@fixture.test?message;body=Hello%20nest")
        XCTAssertTrue(driver.recorderElement.waitForExistence(timeout: ConversationDriver.openTimeout), "the chat didn't open")
        let composer = driver.composer
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Hello nest"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 10), .completed, "the composer holds \(String(describing: composer.value))")
    }

    func testALinkToAStrangerAsksBeforeAddingThem() {
        open("xmpp:stranger@elsewhere.test?roster;name=Sam;preauth=abc123;ibr=y")
        XCTAssertTrue(app.staticTexts["stranger@elsewhere.test"].waitForExistence(timeout: 15), "the address isn't shown to confirm")
        XCTAssertTrue(app.buttons["Add"].exists)
        XCTAssertTrue(app.textFields["Name (optional)"].exists)
        app.buttons["Cancel"].tap()
        waitUntilGone(app.buttons["Add"], "the confirmation")
        XCTAssertFalse(driver.recorderElement.exists, "cancelling opened a chat")
    }

    func testAPlainLinkToAStrangerOffersToChatWithoutAdding() {
        open("xmpp:stranger@elsewhere.test")
        XCTAssertTrue(app.staticTexts["stranger@elsewhere.test"].waitForExistence(timeout: 15))
        app.buttons["Chat Without Adding"].tap()
        XCTAssertTrue(driver.recorderElement.waitForExistence(timeout: ConversationDriver.openTimeout), "the chat didn't open")
    }

    func testAGroupLinkAsksBeforeJoining() {
        open("xmpp:room@conference.elsewhere.test?join")
        XCTAssertTrue(app.navigationBars["Join Group"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["group@conference.example.org"].value as? String, "room@conference.elsewhere.test")
        XCTAssertTrue(app.buttons["Join"].exists)
    }

    func testALinkWithAControlCharacterInItsBodyIsRefused() {
        open("xmpp:nest@fixture.test?message;body=%00")
        XCTAssertTrue(app.alerts["Couldn't open the link"].waitForExistence(timeout: 15), "no alert for a refused link")
    }
}
