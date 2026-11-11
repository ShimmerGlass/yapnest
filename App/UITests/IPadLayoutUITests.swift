import XCTest

/// On an iPad whose window is wide, the layout is the Mac's: the chat list
/// beside the open chat, the chat's own header instead of the navigation
/// bar, and the account at the foot of the list. Skipped elsewhere.
final class IPadLayoutUITests: InteractionsTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the desktop layout is the iPad's and the Mac's")
        try await super.setUp()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private func checkDesktopLayout() {
        let list = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Calls,")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the chat list isn't beside the chat")
        let message = bubble("React to this one.")
        XCTAssertLessThan(list.frame.maxX, message.frame.minX, "the list isn't left of the chat")
        XCTAssertTrue(app.buttons["Chat Settings"].firstMatch.exists, "no header in the chat")
        XCTAssertEqual(app.navigationBars.buttons.count, 0, "the navigation bar has buttons: \(app.navigationBars.buttons.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(app.textFields["Search"].exists, "no drawn search field")
        XCTAssertEqual(app.searchFields.count, 0, "the drawer's search field is shown")
        let footer = app.buttons.matching(identifier: "Profile")
        XCTAssertEqual(footer.count, 1, "the account footer isn't the only Profile button")
        XCTAssertLessThan(footer.firstMatch.frame.maxX, message.frame.minX, "the footer isn't in the sidebar")
    }

    /// The elements are there all along, so waiting for them doesn't wait for
    /// the rotation; their frames would be read halfway through it.
    private func turn(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let window = app.windows.firstMatch
        let turned = NSPredicate { _, _ in
            let size = window.frame.size
            return orientation.isLandscape == (size.width > size.height)
        }
        wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 10)
        // The split settles its columns after the window does.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    func testPortraitShowsTheListBesideTheChat() {
        turn(to: .portrait)
        checkDesktopLayout()
    }

    func testLandscapeShowsTheListBesideTheChat() {
        turn(to: .landscapeLeft)
        checkDesktopLayout()
    }
}
