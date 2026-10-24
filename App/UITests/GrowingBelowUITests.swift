import XCTest

/// Scrolled up, the user is reading a particular place. Rows below it, nearer
/// the newest message, that grow as their content arrives (a photo whose
/// shape was only known once downloaded, a link's preview card) must leave
/// what's on screen where it is. Flipped, those rows sit between the scroll
/// view's resting point and what the user reads, so their growth moved it.
@MainActor
final class GrowingBelowUITests: XCTestCase {
    private var driver: ConversationDriver!

    override func setUp() async throws {
        continueAfterFailure = false
        driver = ConversationDriver(
            fixture: "late-content", open: "late@fixture.test", environment: ["YAPNEST_DEV_HOLD_DOWNLOADS": "1"], context: "growing below",
        )
        driver.waitForOpenChat()
    }

    func testRowsGrowingBelowLeaveTheListWhereItIs() throws {
        driver.waitForStillness()
        driver.assertShown(driver.message(containing: "End of the late content."), "at the start")
        // Up just past the rows that will grow, so they are near enough to
        // be laid out but none is on screen.
        var tries = 0
        while growingRowsOnScreen() > 0 {
            tries += 1
            XCTAssertLessThan(tries, 8, "the rows that will grow never left the screen")
            driver.drag(towardsOlder: true, times: 1)
            driver.waitForStillness()
        }
        let label = try XCTUnwrap(middleMessage(), "no message on screen")
        let reading = driver.message(containing: label)
        let before = reading.frame.minY

        driver.app.buttons["releaseDownloads"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        driver.settle(2)
        driver.waitForStillness()

        XCTAssertTrue(reading.exists, "the message being read is gone: \(driver.recorderSummary())")
        XCTAssertEqual(reading.frame.minY, before, accuracy: 0.5, "the list moved as rows below grew: \(driver.recorderSummary())")
        driver.assertNotBlank("after rows below grew")

        // What grew waited for the list to be back at the newest message,
        // and is drawn grown there.
        let end = driver.message(containing: "End of the late content.")
        tries = 0
        while !(end.exists && end.isHittable) {
            tries += 1
            XCTAssertLessThan(tries, 8, "never got back to the newest message: \(driver.recorderSummary())")
            driver.drag(towardsOlder: false, times: 1, hold: 0.2)
        }
        driver.waitForStillness()
        driver.assertShown(end, "back at the newest message")
        let card = driver.message(containing: "A page worth reading")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no preview card once back down")
        let atEnd = driver.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "📷 Photo")).allElementsBoundByIndex
        XCTAssertFalse(atEnd.isEmpty, "no photos once back down")
        XCTAssertTrue(atEnd.allSatisfy { !$0.label.contains("Tap to download") }, "a photo still waits: \(atEnd.map(\.label))")
    }

    /// How many of the photos and links, the rows that grow, reach into the
    /// part of the list the user sees.
    private func growingRowsOnScreen() -> Int {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", "📷 Photo", "Have a look"))
            .allElementsBoundByIndex
            .filter(isOnScreen)
            .count
    }

    /// Whether the element reaches into the part of the list the user sees.
    private func isOnScreen(_ element: XCUIElement) -> Bool {
        let top = driver.app.navigationBars.firstMatch.frame.maxY
        let bottom = driver.composer.frame.minY
        return element.exists && element.frame.height > 0 && element.frame.maxY > top && element.frame.minY < bottom
    }

    /// The words that name a message near the middle of the screen.
    private func middleMessage() -> String? {
        let middle = driver.app.windows.firstMatch.frame.midY
        guard let snapshot = try? driver.app.snapshot() else { return nil }
        var candidates: [(String, CGRect)] = []
        var stack = [snapshot]
        while let element = stack.popLast() {
            stack.append(contentsOf: element.children)
            guard element.elementType == .staticText, let match = element.label.range(of: #"Late \d{4}"#, options: .regularExpression) else { continue }
            candidates.append((String(element.label[match]), element.frame))
        }
        return candidates.min { abs($0.1.midY - middle) < abs($1.1.midY - middle) }.map(\.0)
    }
}
