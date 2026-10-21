import XCTest

/// What the long-press menu does with a message, on the Nest chat of the
/// `interactions` fixture.
final class MessageActionsUITests: InteractionsTestCase {
    func testPickingAQuickReactionPutsAChipOnTheBubble() {
        XCTAssertFalse(chip("❤️").exists, "a ❤️ chip is there before reacting")
        openMenu(on: "React to this one.")
        app.descendants(matching: .any).matching(identifier: "❤️").firstMatch.tap()
        XCTAssertTrue(chip("❤️").waitForExistence(timeout: 10), "no ❤️ chip appeared on the bubble")
    }

    func testTappingYourOwnReactionTakesItBack() {
        let chip = chip("👍")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the message has no 👍 chip to begin with")
        chip.tap()
        let mine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "tap to remove")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5), "tapping the chip didn't offer to take the reaction back")
        mine.tap()
        waitUntilGone(chip, "the 👍 chip")
    }

    func testMoreReactionsBringsUpTheEmojiKeyboard() {
        openMenu(on: "React to this one.")
        app.buttons["More Reactions"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "no keyboard came up to pick an emoji")
    }

    func testCopyPutsTheMessageOnThePasteboard() {
        openMenu(on: "Copy me please.")
        app.buttons["Copy"].tap()
        // The runner can't read the pasteboard, so the composer does.
        let composer = driver.composer
        composer.tap()
        composer.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste offered, so nothing was copied")
        paste.tap()
        XCTAssertEqual(composer.value as? String, "Copy me please.", "what was copied isn't the message")
    }

    func testEditPutsTheTextInTheComposerAndSendingChangesTheBubble() {
        openMenu(on: "Edit me please.")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.staticTexts["Edit Message"].waitForExistence(timeout: 5), "no edit banner above the composer")
        let composer = driver.composer
        XCTAssertEqual(composer.value as? String, "Edit me please.", "the composer doesn't hold the message")
        composer.typeText(" Done.")
        app.buttons["Send"].tap()
        // Offline, a message that hasn't gone out is simply changed, with no
        // "edited" mark, as nobody has seen the first words.
        XCTAssertTrue(app.staticTexts["Edit me please. Done."].waitForExistence(timeout: 10), "the bubble doesn't have the new words")
        XCTAssertFalse(app.staticTexts["Edit me please."].exists, "the old words are still drawn")
        XCTAssertFalse(app.staticTexts["Edit Message"].exists, "the edit banner stayed after sending")
    }

    /// The fixture never connects: the edit is applied here and waits to be
    /// sent, with no error.
    func testEditingAMessageThatWasSentOfflineAppliesItAndQueuesIt() {
        openMenu(on: "Sent already.")
        app.buttons["Edit"].tap()
        driver.composer.typeText(" Again.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Sent already. Again."].waitForExistence(timeout: 10), "the bubble doesn't have the new words")
        XCTAssertFalse(app.alerts.firstMatch.exists, "an edit made offline was refused")
    }

    func testDeleteAsksFirstAndRemovesTheMessage() {
        openMenu(on: "Delete me please.")
        app.buttons["Delete for Everyone"].tap()
        let confirm = app.sheets.firstMatch.buttons["Delete for Everyone"]
        if !confirm.waitForExistence(timeout: 5) { print(app.debugDescription) }
        XCTAssertTrue(confirm.exists, "no confirmation before deleting")
        XCTAssertTrue(app.staticTexts["Delete me please."].exists, "the message went before it was confirmed")
        confirm.tap()
        waitUntilGone(app.staticTexts["Delete me please."].firstMatch, "the deleted message")
    }

    func testCancellingTheDeletionKeepsTheMessage() {
        openMenu(on: "Delete me please.")
        app.buttons["Delete for Everyone"].tap()
        let confirm = app.sheets.firstMatch.buttons["Delete for Everyone"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation before deleting")
        // The dialog is a popover on the phone too, with no Cancel: a tap
        // beside it puts it away.
        let cancel = app.sheets.firstMatch.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)).tap()
        }
        waitUntilGone(confirm, "the confirmation")
        XCTAssertTrue(app.staticTexts["Delete me please."].exists, "cancelling deleted the message")
    }
}
