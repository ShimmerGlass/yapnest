import XCTest

/// The message list driven as the user does, on the dev fixtures
/// (`DevFixture` in the app), with the app's frame recorder catching what a
/// look at the screen now and then would miss: a frame that jumped, a list
/// left blank.
///
/// The keyboard tests need the simulator's software keyboard: with I/O >
/// Keyboard > Connect Hardware Keyboard on, no keyboard comes up.
@MainActor
final class ConversationScrollingUITests: XCTestCase {
    /// The most the topmost message may move when older ones come in above
    /// it. The drag that gets there is held still at its end, but a load can
    /// land a frame or two before it stops; a row that wasn't held moves by
    /// the height of everything inserted, thousands of points.
    private static let prependTolerance: CGFloat = 8

    private var d: ConversationDriver!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: A newest message taller than two screens

    func testTallNewestOpensAtTheBottom() throws {
        launch(fixture: "tall-newest")
        openChat("Mail")
        let newest = message(containing: "End of the Nestauth notice.")
        settle()
        assertShown(newest, "after opening")
        assertHeldAtBottom("while opening")
        settle()
        assertShown(newest, "a second after opening")
    }

    func testTallNewestStaysAtTheBottomAsTheKeyboardCloses() throws {
        launch(fixture: "tall-newest")
        openChat("Mail")
        let newest = message(containing: "End of the Nestauth notice.")
        settle()
        openKeyboard()
        assertShown(newest, "with the keyboard up")
        resetRecorder()
        closeKeyboard()
        settle()
        assertShown(newest, "after the keyboard closed")
        assertHeldAtBottom("while the keyboard closed")
        settle()
        assertShown(newest, "a second after the keyboard closed")
    }

    // MARK: More history than the first window

    func testLongHistoryOpensAtTheBottom() throws {
        launch(fixture: "long-history")
        openChat("History")
        let newest = message(containing: "History 0749:")
        settle()
        assertShown(newest, "after opening")
        assertHeldAtBottom("while opening")
    }

    func testLongHistoryStaysAtTheBottomAsTheKeyboardCloses() throws {
        launch(fixture: "long-history")
        openChat("History")
        let newest = message(containing: "History 0749:")
        settle()
        openKeyboard()
        assertShown(newest, "with the keyboard up")
        resetRecorder()
        closeKeyboard()
        settle()
        assertShown(newest, "after the keyboard closed")
        assertHeldAtBottom("while the keyboard closed")
    }

    /// The list runs on under the composer, so the messages show through its
    /// glass, while the newest one still rests just above it.
    func testTheListRunsUnderTheComposer() throws {
        launch(fixture: "long-history")
        openChat("History")
        let newest = message(containing: "History 0749:")
        settle()
        assertShown(newest, "after opening")
        assertListUnderComposer(holding: "History 0749:", "with the keyboard closed")
        openKeyboard()
        assertShown(newest, "with the keyboard up")
        assertListUnderComposer(holding: "History 0749:", "with the keyboard up")
        closeKeyboard()
        settle()
        assertShown(newest, "after the keyboard closed")
        assertListUnderComposer(holding: "History 0749:", "after the keyboard closed")
    }

    func testOlderMessagesComeInWithoutMovingTheList() throws {
        launch(fixture: "long-history")
        openChat("History")
        settle()
        let rowsAtOpen = try XCTUnwrap(recorder()["rows"])
        resetRecorder()
        let list = d.app.windows.firstMatch
        // Flicks get near the top quickly, stopping well short of where the
        // older page loads (30 rows from the oldest, some 6,000 points, and
        // the stack's guess of the distance is thousands too long). The last
        // stretch is dragged slowly and held, so the list is still when the
        // older page lands, and how far its rows move can be measured.
        var flicks = 0
        while (recorder()["top"] ?? 0) > 12000, flicks < 40 {
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 5000), thenHoldForDuration: 0)
            // XCUITest returns only once the coast has stopped; this is the
            // recorder's publish delay.
            settle(0.2)
            flicks += 1
        }
        waitForStillness()
        var drags = 0
        while (recorder()["measuredPrepends"] ?? 0) < 1, (recorder()["top"] ?? 0) > 0, drags < 40 {
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.8)
            drags += 1
        }
        settle()
        let record = recorder()
        XCTAssertGreaterThanOrEqual(record["measuredPrepends"] ?? 0, 1, "older messages never came in while the list was still: \(recorderSummary())")
        XCTAssertGreaterThan(record["rows"] ?? 0, rowsAtOpen, "the window didn't grow: \(recorderSummary())")
        XCTAssertLessThanOrEqual(record["maxPrependShift"] ?? .infinity, Self.prependTolerance, "the list moved as older messages came in: \(recorderSummary())")
        XCTAssertGreaterThan(record["visible"] ?? 0, 0, "the list is blank: \(recorderSummary())")
    }

    // MARK: A long chat of tall messages

    func testTallHistoryOpensAtTheBottom() throws {
        launch(fixture: "tall-history")
        openChat("Archive")
        let newest = message(containing: "End of Archive 0299.")
        settle()
        assertShown(newest, "after opening")
        assertHeldAtBottom("while opening")
    }

    func testTallHistoryStaysAtTheBottomAsTheKeyboardCloses() throws {
        launch(fixture: "tall-history")
        openChat("Archive")
        let newest = message(containing: "End of Archive 0299.")
        settle()
        for round in 1...3 {
            openKeyboard()
            assertShown(newest, "with the keyboard up, round \(round)")
            resetRecorder()
            closeKeyboard()
            settle()
            assertShown(newest, "after the keyboard closed, round \(round)")
            assertHeldAtBottom("while the keyboard closed, round \(round)")
        }
    }

    // MARK: Driving the app

    private func launch(fixture: String) {
        d = ConversationDriver(
            fixture: fixture,
            // These chats are about rows taller than the screen, which long
            // bodies are otherwise cut short of.
            environment: ["YAPNEST_DEV_SHOW_WHOLE": "1"],
            context: "scrolling \(fixture)",
        )
    }

    private func openChat(_ name: String) { d.openChat(name) }
    private func openKeyboard() { d.openKeyboard() }
    private func closeKeyboard() { d.closeKeyboard() }
    private func settle(_ seconds: TimeInterval = 1) { d.settle(seconds) }
    private func waitForStillness() { d.waitForStillness() }
    private func message(containing text: String) -> XCUIElement { d.message(containing: text) }
    private func assertHeldAtBottom(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        d.assertHeldAtBottom(when, file: file, line: line)
    }
    private func recorder() -> [String: CGFloat] { d.recorder() }
    private func recorderSummary() -> String { d.recorderSummary() }
    private func resetRecorder() { d.resetRecorder() }

    private func assertListUnderComposer(holding text: String, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let list = d.app.scrollViews.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertGreaterThanOrEqual(list.frame.maxY, d.composer.frame.maxY, "the list stops above the composer \(when): \(list.frame), composer at \(d.composer.frame)", file: file, line: line)
    }

    /// These chats have no reactions chip under the newest bubble, so the
    /// bubble must end within 40 points of the composer, not the driver's 60.
    private func assertShown(_ message: XCUIElement, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        d.assertShown(message, when, maxGap: 40, file: file, line: line)
    }
}
