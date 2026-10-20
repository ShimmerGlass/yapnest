import XCTest

/// Settings from the chat list: opening and closing it, and the list of
/// open source licences. Reads the licence texts bundled with the app.
final class SettingsUITests: InteractionsTestCase {
    override var chat: String? { nil }

    func testSettingsOpensAndDoneClosesIt() {
        driver.openSettings()
        app.buttons["Done"].tap()
        waitUntilGone(app.navigationBars["Settings"], "Settings")
        XCTAssertTrue(app.buttons["Settings"].exists, "the chat list isn't back")
    }

    func testTheLicencesListNamesTheLibrariesAndOpensOne() {
        driver.openSettings()
        let licences = app.buttons["Open Source Licences"].firstMatch
        for _ in 0..<5 where !licences.isHittable { app.swipeUp() }
        XCTAssertTrue(licences.waitForExistence(timeout: 5), "no Open Source Licences in Settings")
        licences.tap()
        let grdb = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "GRDB")).firstMatch
        XCTAssertTrue(grdb.waitForExistence(timeout: 10), "the licences list doesn't name GRDB")
        XCTAssertTrue(app.buttons["Yapnest"].exists, "the licences list has no entry for Yapnest's own licence")
        grdb.tap()
        let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Permission is hereby granted", "Permission is hereby granted")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "GRDB's licence text isn't shown")
        app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "GRDB")).buttons.firstMatch.tap()
        XCTAssertTrue(grdb.waitForExistence(timeout: 5), "back doesn't return to the list")
    }

    func testTheGifSettingTogglesWhenTheAppHasAKey() throws {
        driver.openSettings()
        let toggle = app.switches["GIFs"]
        try XCTSkipUnless(toggle.waitForExistence(timeout: 3), "this build has no KLIPY key, so Settings has no GIF setting")
        let before = toggle.value as? String
        toggle.switches.firstMatch.tap()
        XCTAssertNotEqual(toggle.value as? String, before, "the GIF switch didn't change")
    }

    /// The fixture's account never connects; the check is local, so nothing is sent.
    func testChangePasswordRefusesPasswordsThatDontMatch() {
        driver.openSettings()
        let link = app.buttons["Change Password"].firstMatch
        for _ in 0..<8 where !link.exists || !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.exists, "no Change Password in Settings")
        link.tap()
        XCTAssertTrue(app.navigationBars["Change Password"].waitForExistence(timeout: 10), "Change Password didn't open")
        XCTAssertTrue(app.staticTexts["Your other devices will need the new password."].exists, "the footer about other devices is missing")

        func type(_ text: String, into field: String) {
            let secure = app.secureTextFields[field]
            XCTAssertTrue(secure.waitForExistence(timeout: 5), "no \(field) field")
            secure.tap()
            secure.typeText(text)
        }
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "Save is on with nothing typed")
        type("old-password", into: "Current Password")
        type("new-password", into: "New Password")
        type("other-password", into: "Confirm New Password")
        let problem = app.staticTexts["passwordProblem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "mismatched passwords weren't flagged")
        XCTAssertEqual(problem.label, "The new passwords don't match.")
        XCTAssertFalse(save.isEnabled, "Save is on though the passwords differ")

        // Typing the rest of the matching password fixes it.
        let confirm = app.secureTextFields["Confirm New Password"]
        confirm.tap()
        confirm.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "other-password".count))
        confirm.typeText("new-password")
        waitUntilGone(problem, "the mismatch message")
        XCTAssertTrue(save.isEnabled, "Save is off though the passwords match")
    }
}

/// Exporting logs builds a file from the app's own log, which needs no
/// connection, so it works on the fixture.
final class ExportLogsUITests: InteractionsTestCase {
    override var chat: String? { nil }

    func testExportLogsOpensTheShareSheetWithoutAnError() {
        driver.openSettings()
        let row = app.buttons["exportLogs"].firstMatch
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, "no Export Logs row in Settings")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "holds no messages, contacts or addresses")).firstMatch.exists,
            "the footer doesn't say what the logs hold")
        row.tap()
        XCTAssertFalse(app.alerts["Couldn't export the logs"].waitForExistence(timeout: 3), "the export failed")
        let shown = app.otherElements["diagnosticsShareSheet"].firstMatch.waitForExistence(timeout: 10)
            || app.otherElements["ActivityListView"].waitForExistence(timeout: 5)
            || app.buttons["Copy"].waitForExistence(timeout: 5)
            || app.navigationBars["ActivityListView"].exists
        XCTAssertTrue(shown, "the share sheet didn't open: \(app.debugDescription.prefix(2000))")
    }
}
