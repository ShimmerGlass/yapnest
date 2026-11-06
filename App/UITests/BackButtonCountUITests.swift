import XCTest

/// With the chat list hidden behind a chat, the system's back button counts
/// what's unread in the other chats, where the list would show it. It was a
/// badge of its own beside back, which did nothing when tapped.
final class BackButtonCountUITests: InteractionsTestCase {
    override var chat: String? { name.contains("Tapped") ? nil : "nest@fixture.test" }

    /// One more message from the Unread chat, late enough that Nest has been
    /// open for a while. Only for the test that waits for it, as a slow
    /// launch would have it arrive before the others read the first count.
    override var environment: [String: String] {
        // Enough for two digits, the widest count that has to fit.
        if name.contains("CallButton") {
            return [
                "YAPNEST_DEV_CALLABLE": "nest@fixture.test",
                "YAPNEST_DEV_INCOMING": Array(repeating: "0", count: 9).joined(separator: ","),
                "YAPNEST_DEV_INCOMING_FROM": "unread@fixture.test",
            ]
        }
        guard name.contains("Arriving") else { return [:] }
        return ["YAPNEST_DEV_INCOMING": "15", "YAPNEST_DEV_INCOMING_FROM": "unread@fixture.test"]
    }

    private var back: XCUIElement { app.navigationBars.buttons.firstMatch }

    private func row(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch
    }

    private func waitForBack(saying label: String, timeout: TimeInterval = 10) {
        let said = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [said], timeout: timeout), .completed, "back reads \"\(back.label)\", not \"\(label)\"")
    }

    /// XCUI reads back as one element, so what's drawn is kept to look at.
    private func keepScreenshot() {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testBackCountsTheOtherChatsAndGoesBackToTheList() {
        waitForBack(saying: "3")
        back.tap()
        XCTAssertTrue(row("Unread").waitForExistence(timeout: ConversationDriver.listTimeout), "the list isn't back")
    }

    /// Opened from the list, the counts are known before the push, unlike a
    /// chat opened at launch.
    func testBackCountsTheOtherChatsInAChatTappedInTheList() {
        let nest = row("Nest")
        XCTAssertTrue(nest.waitForExistence(timeout: ConversationDriver.listTimeout), "no Nest row")
        nest.tap()
        waitForBack(saying: "3")
        keepScreenshot()
    }

    /// A chat with someone who can be called has a button on the other side of
    /// the bar, as a group doesn't. Short of room, the bar draws back as only
    /// its chevron, round, with XCUI's label still saying the count.
    func testBackCountsTheOtherChatsBesideTheCallButton() {
        waitForBack(saying: "12")
        driver.waitForStillness()
        keepScreenshot()
        XCTAssertGreaterThan(back.frame.width, back.frame.height + 4, "back is only its chevron")
    }

    /// The count is set on the list's own back item, which every screen
    /// pushed over the list shows, so it has to go with the chat.
    func testTheCountLeavesWithTheChat() {
        waitForBack(saying: "3")
        back.tap()
        let blocked = row("Blocked")
        XCTAssertTrue(blocked.waitForExistence(timeout: ConversationDriver.listTimeout), "the list isn't back")
        let bar = app.buttons["New Chat"]
        for _ in 0..<3 where blocked.frame.midY > bar.frame.minY - 20 { app.swipeUp() }
        driver.openMenu(on: blocked, "the Blocked row", showing: "Archive")
        app.buttons["Archive"].firstMatch.tap()
        let archived = app.buttons["Archived Chats (1)"]
        for _ in 0..<5 where !archived.waitForExistence(timeout: 2) { app.swipeUp() }
        archived.tap()
        XCTAssertTrue(blocked.waitForExistence(timeout: ConversationDriver.listTimeout), "the archive didn't open")
        waitForBack(saying: "Chats")
    }

    func testBackCountsAMessageArrivingInAnotherChat() {
        waitForBack(saying: "3")
        waitForBack(saying: "4", timeout: 30)
        keepScreenshot()
    }
}
