import XCTest

/// The Encryption Keys screen shows when each of our devices was last used,
/// and offers to remove the ones nobody uses. The fixture's session never
/// connects, so a removal is refused, which is the error path.
@MainActor
final class DevicesUITests: XCTestCase {
    private func openDevices() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["YAPNEST_DEV_FIXTURE"] = "devices"
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: ConversationDriver.listTimeout), "no Settings button on the chat list")
        settings.tap()
        // Below the fold on a phone.
        let keys = app.descendants(matching: .any).matching(identifier: "Encryption Keys").firstMatch
        _ = keys.waitForExistence(timeout: 5)
        for _ in 0..<8 where !keys.exists || !keys.isHittable { app.swipeUp() }
        XCTAssertTrue(keys.exists, "no Encryption Keys in Settings: \(app.debugDescription.prefix(3000))")
        keys.tap()
        XCTAssertTrue(app.otherElements["device-101"].waitForExistence(timeout: 10) || app.staticTexts["Never seen"].firstMatch.waitForExistence(timeout: 10), "the devices didn't show")
        return app
    }

    private func texts(_ label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", label))
    }

    func testEachDeviceSaysWhenItWasLastUsed() {
        let app = openDevices()
        XCTAssertEqual(texts("Never seen", in: app).count, 2, "devices 103 and 104 never sent anything")
        XCTAssertEqual(texts("Last used", in: app).count, 2, "devices 101 and 102 did")
        XCTAssertEqual(texts("Inactive", in: app).matching(NSPredicate(format: "label == %@", "Inactive")).count, 2, "102 (quiet) and 103 (never seen for 200 days) are inactive, 104 is new")
    }

    func testRemovingTheUnusedDevicesAsksFirstAndReportsAFailure() {
        let app = openDevices()
        let button = app.buttons["removeUnusedDevices"]
        _ = button.waitForExistence(timeout: 3)
        for _ in 0..<5 where !button.exists || !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.exists, "no button to remove the unused devices")
        XCTAssertTrue(button.label.contains("2"), "it should count 102 and 103, not the new 104: \(button.label)")
        button.tap()

        let confirm = app.alerts["Remove 2 devices?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "removing wasn't confirmed first")
        XCTAssertTrue(confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "adds itself back")).firstMatch.exists
            || confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "add themselves back")).firstMatch.exists,
            "the alert doesn't say a device in use returns")
        confirm.buttons["Remove"].tap()

        let failure = app.alerts["Couldn't remove"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), "a refused removal wasn't reported")
        XCTAssertTrue(failure.staticTexts["You're offline."].exists, "the reason is missing")
        failure.buttons["OK"].tap()
        XCTAssertEqual(texts("Never seen", in: app).count, 2, "devices were dropped though the server never accepted")
    }

    func testOneDeviceCanBeRemovedAndTheConfirmationCanBeCancelled() {
        let app = openDevices()
        let device = app.otherElements["device-102"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        device.buttons["Device options"].tap()
        app.buttons["Remove device"].tap()
        let confirm = app.alerts["Remove this device?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "removing wasn't confirmed first")
        confirm.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts["Couldn't remove"].exists)
        XCTAssertTrue(device.exists)
    }
}
