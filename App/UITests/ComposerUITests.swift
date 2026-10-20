import XCTest

/// The composer on the Nest chat: when it offers to send, what sending
/// leaves in the list, the attach menu, a staged picture, and the reply bar.
final class ComposerUITests: InteractionsTestCase {
    /// Hidden while there is nothing to send, though it stays in the tree.
    private var send: XCUIElement { app.buttons["Send"] }

    private func waitUntilHittable(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "\(what) isn't there", file: file, line: line)
    }

    private func waitUntilHidden(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed, "\(what) is still there", file: file, line: line)
    }

    func testTheSendButtonIsThereOnlyWithText() {
        XCTAssertFalse(send.isHittable, "a send button with nothing to send")
        driver.composer.tap()
        driver.composer.typeText("Hello")
        waitUntilHittable(send, "the send button")
        // Only whitespace is nothing to send.
        driver.composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        waitUntilHidden(send, "the send button after the text was deleted")
    }

    func testSendingPutsANewBubbleAtTheNewestEnd() {
        driver.composer.tap()
        driver.composer.typeText("A brand new message")
        send.tap()
        let sent = driver.message(containing: "A brand new message")
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "no bubble for the sent message")
        driver.waitForStillness()
        driver.assertShown(sent, "after sending")
        waitUntilHidden(send, "the send button after sending")
    }

    func testTheAttachMenuOffersWhatCanBeAttached() {
        app.buttons["Attach"].tap()
        for item in ["Photos", "Camera", "File", "Location", "Contact"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5), "no \(item) in the attach menu")
        }
    }

    func testReplyBarCanBeCancelled() {
        openMenu(on: "React to this one.")
        app.buttons["Reply"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no reply bar to cancel")
        XCTAssertEqual(app.staticTexts.matching(identifier: "React to this one.").count, 2, "the reply bar doesn't repeat the message")
        cancel.tap()
        waitUntilGone(cancel, "the reply bar")
        XCTAssertEqual(app.staticTexts.matching(identifier: "React to this one.").count, 1, "the quote stayed after cancelling")
    }

    func testAPastedPictureWaitsInTheTrayAndCanBeRemoved() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        driver.composer.tap()
        driver.composer.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste offered with a picture on the pasteboard")
        paste.tap()
        // Pasting from another app asks first.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let tile = app.otherElements["Photo"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the pasted picture isn't in the tray")
        waitUntilHittable(send, "the send button with a picture staged")
        app.buttons["Remove"].firstMatch.tap()
        waitUntilGone(tile, "the removed picture")
        waitUntilHidden(send, "the send button with nothing staged")
    }
}
