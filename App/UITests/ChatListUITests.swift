import XCTest

/// The chat list of the `interactions` fixture: opening a chat, the unread
/// badge, the row's menu and swipes, and the request at the top.
final class ChatListUITests: InteractionsTestCase {
    override var chat: String? { nil }

    private func row(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch
    }

    private func waitForRow(_ name: String) -> XCUIElement {
        let row = row(name)
        XCTAssertTrue(row.waitForExistence(timeout: ConversationDriver.listTimeout), "no chat named \(name) in the list")
        return row
    }

    /// A row reads as its name, the time, the last words, then the unread count.
    private func unreadCount(of row: XCUIElement) -> Int? {
        row.label.split(separator: ",").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func back() {
        app.navigationBars.buttons.firstMatch.tap()
    }

    func testOpeningAChatShowsItAndBackReturnsToTheList() {
        waitForRow("Nest").tap()
        XCTAssertTrue(driver.recorderElement.waitForExistence(timeout: ConversationDriver.openTimeout), "the chat didn't open")
        XCTAssertTrue(app.staticTexts["React to this one."].waitForExistence(timeout: ConversationDriver.contentTimeout), "the chat's messages aren't shown")
        back()
        XCTAssertTrue(row("Nest").waitForExistence(timeout: ConversationDriver.listTimeout), "the list isn't back")
    }

    func testTheUnreadBadgeClearsOnceTheChatIsOpened() {
        let unread = waitForRow("Unread")
        XCTAssertEqual(unreadCount(of: unread), 3, "the row doesn't count the 3 unread messages: \(unread.label)")
        XCTAssertNil(unreadCount(of: row("Nest")), "a chat with nothing unread has a badge: \(row("Nest").label)")
        unread.tap()
        XCTAssertTrue(driver.recorderElement.waitForExistence(timeout: ConversationDriver.openTimeout), "the chat didn't open")
        XCTAssertTrue(app.staticTexts["Third unread."].waitForExistence(timeout: ConversationDriver.contentTimeout))
        back()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "unread."), object: row("Unread"))
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 15), .completed, "the badge stayed after reading: \(row("Unread").label)")
    }

    func testTheRowsMenuPinsAChat() {
        let nest = waitForRow("Nest")
        nest.press(forDuration: 1.0)
        app.buttons["Pin"].firstMatch.tap()
        let pinned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Pinned"), object: row("Nest"))
        XCTAssertEqual(XCTWaiter.wait(for: [pinned], timeout: 10), .completed, "the chat isn't marked pinned: \(row("Nest").label)")
        // Pinned chats go to the top.
        XCTAssertLessThan(row("Nest").frame.minY, row("Unread").frame.minY, "the pinned chat isn't first")
    }

    func testTheRowsMenuArchivesAChat() {
        waitForRow("Blocked").press(forDuration: 1.0)
        app.buttons["Archive"].firstMatch.tap()
        waitUntilGone(row("Blocked"), "the archived chat's row")
        // The entry ends the list, which the fixture's chats run past the
        // screen, and a lazy list only makes the rows it shows.
        let archived = app.buttons["Archived Chats (1)"]
        for _ in 0..<5 where !archived.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(archived.waitForExistence(timeout: ConversationDriver.listTimeout), "no entry for the archive")
        archived.tap()
        XCTAssertTrue(row("Blocked").waitForExistence(timeout: ConversationDriver.listTimeout), "the archive doesn't hold the chat")
    }

    func testDeletingAChatAsksFirst() {
        waitForRow("Unread").press(forDuration: 1.0)
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.sheets.firstMatch.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation before deleting")
        XCTAssertTrue(row("Unread").exists, "the chat went before it was confirmed")
        confirm.tap()
        waitUntilGone(row("Unread"), "the deleted chat's row")
    }

    func testSwipingARowRightOffersReadAndPin() {
        waitForRow("Nest").swipeRight()
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 5), "no Pin on the leading swipe")
        XCTAssertTrue(app.buttons["Unread"].exists, "no Unread on the leading swipe")
    }

    func testSwipingARowLeftOffersDeleteAndArchive() {
        waitForRow("Nest").swipeLeft()
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 5), "no Archive on the trailing swipe")
        XCTAssertTrue(app.buttons["Delete"].exists, "no Delete on the trailing swipe")
    }

    func testAContactRequestShowsAtTheTopAndAnsweringNeedsAConnection() {
        let request = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "robin@fixture.test")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: ConversationDriver.listTimeout), "the request isn't in the list")
        XCTAssertTrue(request.label.contains("Robin"), "the request doesn't name who asked: \(request.label)")
        XCTAssertTrue(app.buttons["Decline"].exists, "no Decline")
        app.buttons["Accept"].tap()
        let alert = app.alerts["Couldn't answer"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no word that the request couldn't be answered offline")
        alert.buttons["OK"].tap()
        XCTAssertTrue(request.exists, "the request went though it wasn't answered")
    }

    func testNewChatOpensItsSheetAndCancelClosesIt() {
        let new = app.buttons["New Chat"]
        XCTAssertTrue(new.waitForExistence(timeout: ConversationDriver.listTimeout), "no New Chat button")
        new.tap()
        let sheet = app.navigationBars["New Chat"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the New Chat sheet didn't open")
        XCTAssertTrue(app.buttons["New Group"].exists, "no New Group in the sheet")
        XCTAssertTrue(app.buttons["Join a Group"].exists, "no Join a Group in the sheet")
        sheet.buttons["Cancel"].tap()
        waitUntilGone(sheet, "the New Chat sheet")
    }
}
