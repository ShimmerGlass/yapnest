import XCTest

/// Scrolled up, the user is reading a particular place. A message arriving
/// at the newest end must leave what's on screen where it is: on the flipped
/// list it waits below until the user scrolls back down.
@MainActor
final class ArrivingWhileScrolledUpUITests: XCTestCase {
    private var driver: ConversationDriver!
    private var launched = Date()
    /// When the message arrives, after launch: time to open the chat and
    /// scroll up first.
    private static let arrival: TimeInterval = 30

    override func setUp() async throws {
        continueAfterFailure = false
        driver = ConversationDriver(
            fixture: "long-history",
            open: "history@fixture.test",
            environment: ["YAPNEST_DEV_INCOMING": "\(Self.arrival)"],
            context: "arriving while scrolled up",
        )
        launched = Date()
        driver.waitForOpenChat()
    }

    func testAMessageArrivingLeavesTheListWhereItIs() throws {
        driver.settle()
        driver.drag(towardsOlder: true)
        driver.waitForStillness()
        let label = try XCTUnwrap(middleMessage(), "no message on screen")
        let reading = driver.message(containing: label)
        let before = reading.frame.minY

        // The window is full, so the row count doesn't say when it came:
        // it's waited for by the clock.
        XCTAssertLessThan(Date().timeIntervalSince(launched), Self.arrival - 1, "scrolling up took until the message arrived")
        driver.settle(Self.arrival + 2 - Date().timeIntervalSince(launched))
        driver.waitForStillness()

        XCTAssertTrue(reading.exists, "the message being read is gone: \(driver.recorderSummary())")
        XCTAssertEqual(reading.frame.minY, before, accuracy: 2, "the list moved as a message arrived: \(driver.recorderSummary())")
        XCTAssertFalse(driver.message(containing: "A message arriving").isHittable, "the list followed the new message")
        driver.assertNotBlank("after a message arrived")

        // It waited below, and is there once the user scrolls back down.
        driver.drag(towardsOlder: false, hold: 0.2)
        let arrived = driver.message(containing: "A message arriving")
        XCTAssertTrue(arrived.waitForExistence(timeout: 5), "the message that waited never came in: \(driver.recorderSummary())")
        driver.waitForStillness()
        driver.assertShown(arrived, "once back at the bottom")
    }

    /// The words that name a message near the middle of the screen.
    private func middleMessage() -> String? {
        let middle = driver.app.windows.firstMatch.frame.midY
        guard let snapshot = try? driver.app.snapshot() else { return nil }
        var candidates: [(String, CGRect)] = []
        var stack = [snapshot]
        while let element = stack.popLast() {
            stack.append(contentsOf: element.children)
            guard element.elementType == .staticText, let match = element.label.range(of: #"History \d{4}"#, options: .regularExpression) else { continue }
            candidates.append((String(element.label[match]), element.frame))
        }
        return candidates.min { abs($0.1.midY - middle) < abs($1.1.midY - middle) }.map(\.0)
    }
}
