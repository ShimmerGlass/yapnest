import XCTest

/// The chat's settings from the header.
final class ChatSettingsUITests: InteractionsTestCase {
    func testChatSettingsOpensFromTheHeaderAndDoneClosesIt() {
        driver.openChatSettings()
        app.buttons["Done"].tap()
        waitUntilGone(app.navigationBars["Chat Settings"], "Chat Settings")
        XCTAssertTrue(app.staticTexts["React to this one."].exists, "the chat isn't back")
    }

    /// A pushed screen used to have only Back, so closing took going back first.
    func testDoneOnAPushedScreenClosesChatSettings() {
        driver.openChatSettings()
        // Its label carries the chosen sound after the name.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notification sound")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Notification Sound"].waitForExistence(timeout: 10), "the sound picker didn't open")
        app.navigationBars["Notification Sound"].buttons["Done"].tap()
        waitUntilGone(app.navigationBars["Notification Sound"], "the sound picker")
        XCTAssertFalse(app.navigationBars["Chat Settings"].exists, "Done only went back to the settings")
        XCTAssertTrue(app.staticTexts["React to this one."].exists, "the chat isn't back")
    }

    func testTheHeaderIsCenteredInTheBar() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .mac, "the Mac has its own strip")
        let header = app.buttons["Chat Settings"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "no header")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(header.frame.midX, window.midX, accuracy: 2, "the header is off centre: \(header.frame) in \(window)")
    }

    func testTheSettingsShowTheContactsAddress() {
        driver.openChatSettings()
        XCTAssertTrue(app.staticTexts["nest@fixture.test"].waitForExistence(timeout: 10), "the contact's address isn't shown")
    }

    func testSearchIsInTheSettingsAndOpensTheSearchField() {
        driver.openChatSettings()
        app.buttons["Search"].tap()
        waitUntilGone(app.navigationBars["Chat Settings"], "Chat Settings")
        XCTAssertTrue(app.textFields["Search in Chat"].waitForExistence(timeout: 10), "no search field")
    }
}

/// The Call button shares the bar's trailing side with nothing else, and
/// the name stays centred all the same.
final class CallableChatHeaderUITests: InteractionsTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        driver = ConversationDriver(fixture: "interactions", open: chat, environment: ["YAPNEST_DEV_CALLABLE": "nest@fixture.test"], context: name)
        driver.waitForOpenChat()
        driver.waitForStillness()
    }

    func testTheHeaderIsCenteredNextToTheCallButton() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .mac, "the Mac has its own strip")
        XCTAssertTrue(app.buttons["Call"].firstMatch.waitForExistence(timeout: 10), "no Call button in the bar")
        let header = app.buttons["Chat Settings"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "no header")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(header.frame.midX, window.midX, accuracy: 2, "the header is off centre: \(header.frame) in \(window)")
    }

    func testTheSettingsOfferCallAndSearch() {
        driver.openChatSettings()
        XCTAssertTrue(app.buttons["Call"].firstMatch.exists, "no Call in the settings")
        XCTAssertTrue(app.buttons["Search"].exists, "no Search in the settings")
    }

    func testTheSettingsOfferVideoWhenThePeerTakesIt() {
        driver.openChatSettings()
        XCTAssertTrue(app.buttons["Video"].exists, "no Video in the settings")
    }
}

final class ContactRequestBannerUITests: InteractionsTestCase {
    override var chat: String? { "robin@fixture.test" }

    func testTheBannerOffersAcceptDeclineAndBlock() {
        let banner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "wants to add you as a contact")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no banner saying who wants to add us")
        XCTAssertTrue(banner.label.contains("Robin"), "the banner doesn't name who asked: \(banner.label)")
        for button in ["Accept", "Decline", "Block"] {
            XCTAssertTrue(app.buttons[button].exists, "no \(button) on the banner")
        }
    }

    func testAnsweringOfflineSaysSoAndKeepsTheBanner() {
        app.buttons["Decline"].tap()
        let alert = app.alerts["Couldn't answer"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no word that the request couldn't be answered offline")
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Accept"].exists, "the banner went though the request wasn't answered")
    }
}

final class BlockedBarUITests: InteractionsTestCase {
    override var chat: String? { "blocked@fixture.test" }

    func testABlockedContactReplacesTheComposerWithAnUnblockBar() {
        XCTAssertTrue(app.staticTexts["You blocked this contact."].waitForExistence(timeout: 10), "no bar saying the contact is blocked")
        XCTAssertTrue(app.buttons["Unblock"].exists, "no Unblock button")
        XCTAssertFalse(driver.composer.exists, "the composer is there for a blocked contact")
    }
}

final class ContactNicknameUITests: InteractionsTestCase {
    private func setNickname(_ name: String) {
        driver.nicknameRow.tap()
        let field = app.alerts["Nickname"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no nickname field")
        field.tap()
        // Prefilled with the current name; the placeholder is not a value.
        let current = (field.value as? String).flatMap { $0 == field.placeholderValue ? nil : $0 } ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + name)
        app.alerts["Nickname"].buttons["Save"].tap()
    }

    func testNamingAContactShowsTheNameInTheSettings() {
        driver.openChatSettings()
        setNickname("Nesty")
        XCTAssertTrue(app.staticTexts["Nesty"].waitForExistence(timeout: 10), "the nickname isn't shown in the settings")
        app.buttons["Done"].tap()
        waitUntilGone(app.navigationBars["Chat Settings"], "Chat Settings")
        XCTAssertTrue(app.staticTexts["Nesty"].waitForExistence(timeout: 10), "the header doesn't show the nickname")
    }

    func testClearingTheNicknameFallsBackToTheAddress() {
        driver.openChatSettings()
        setNickname("Nesty")
        XCTAssertTrue(app.staticTexts["Nesty"].waitForExistence(timeout: 10), "the nickname wasn't saved")
        setNickname("")
        XCTAssertTrue(app.staticTexts["None"].waitForExistence(timeout: 10), "the nickname wasn't cleared")
    }
}

final class StrangerNicknameUITests: InteractionsTestCase {
    override var chat: String? { "robin@fixture.test" }

    func testSomeoneNotInTheRosterHasNoNicknameRow() {
        driver.openChatSettings()
        XCTAssertTrue(app.buttons["Block"].waitForExistence(timeout: 10), "the settings didn't load")
        XCTAssertFalse(driver.nicknameRow.exists, "a nickname row for someone who isn't a contact")
    }
}
