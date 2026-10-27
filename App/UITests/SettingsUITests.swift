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

    /// A pushed screen used to have only Back, so closing took going back first.
    func testDoneOnAPushedScreenClosesSettings() {
        driver.openSettings()
        let licences = app.buttons["Open Source Licences"].firstMatch
        for _ in 0..<5 where !licences.isHittable { app.swipeUp() }
        licences.tap()
        XCTAssertTrue(app.navigationBars["Licences"].waitForExistence(timeout: 10), "the licences didn't open")
        app.navigationBars["Licences"].buttons["Done"].tap()
        waitUntilGone(app.navigationBars["Licences"], "the licences")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "the chat list isn't back")
        XCTAssertFalse(app.navigationBars["Settings"].exists, "Done only went back to Settings")
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

    func testHideScreenInAppSwitcherIsOffByDefault() {
        driver.openSettings()
        let toggle = app.switches["Hide Screen in App Switcher"]
        for _ in 0..<5 where !toggle.exists || !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.exists, "no Hide Screen in App Switcher in Settings")
        XCTAssertEqual(toggle.value as? String, "0", "the setting is on by default")
    }

    /// The snapshot can't be read, so the debug footer counts the covers
    /// raised. The cover is a window of its own, so it's gone from the app's
    /// elements once the app is back.
    func testTheCoverGoesUpWhenTheAppLeavesAndIsGoneOnReturn() {
        driver.openSettings()
        let toggle = app.switches["Hide Screen in App Switcher"]
        for _ in 0..<5 where !toggle.exists || !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.exists, "no Hide Screen in App Switcher in Settings")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1", "the switch didn't turn on")
        let count = app.staticTexts["appSwitcherCoverCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), "no cover counter")
        XCTAssertEqual(count.value as? String, "0")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings isn't back")
        let raised = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [raised], timeout: 10), .completed, "the cover didn't go up: \(count.value ?? "nil")")
        waitUntilGone(app.otherElements["appSwitcherCover"], "the cover")
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

        // Replacing the confirmation with the matching password fixes it.
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
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not who you talked to or what was said")).firstMatch
        // The row can be hittable at the screen's bottom edge with its footer
        // still below, not yet in the list.
        for _ in 0..<8 where !row.exists || !row.isHittable || !footer.exists { app.swipeUp() }
        XCTAssertTrue(row.exists, "no Export Logs row in Settings")
        XCTAssertTrue(footer.exists, "the footer doesn't say what the logs hold")
        row.tap()
        XCTAssertFalse(app.alerts["Couldn't export the logs"].waitForExistence(timeout: 3), "the export failed")
        let shown = app.otherElements["diagnosticsShareSheet"].firstMatch.waitForExistence(timeout: 10)
            || app.otherElements["ActivityListView"].waitForExistence(timeout: 5)
            || app.buttons["Copy"].waitForExistence(timeout: 5)
            || app.navigationBars["ActivityListView"].exists
        XCTAssertTrue(shown, "the share sheet didn't open: \(app.debugDescription.prefix(2000))")
    }
}
