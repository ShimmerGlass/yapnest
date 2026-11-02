import XCTest

/// A chat a little taller than the view. Dragged to its oldest end, the list
/// must rest with the oldest message below the navigation bar. It sprang back
/// to the newest message instead when the content was less than 120 pt taller
/// than the view (#229): pulled past the oldest end, the list counted as away
/// from the newest message, held it back, and on the way back, which ends
/// within that distance, let it in and followed it down. The counts run from
/// a chat that fits to one that scrolls a screen's worth, so the range that
/// fails is covered on any screen size.
@MainActor
final class ShortChatReachUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func assertReachesOldest(count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let driver = ConversationDriver(fixture: "fit:\(count)", open: "fit@fixture.test", context: "fit:\(count)")
        driver.waitForOpenChat(file: file, line: line)
        driver.waitForStillness()
        let oldest = driver.message(containing: "Fit message 01.")
        driver.waitForContent(oldest, "the oldest message", file: file, line: line)
        let bar = driver.app.navigationBars.firstMatch
        // Slow drags that end on a release, as a user's does; the spring back
        // happens after the finger lifts.
        for _ in 0..<4 where oldest.frame.minY < bar.frame.maxY || !oldest.isHittable {
            driver.drag(towardsOlder: true, times: 1, hold: 0)
            driver.waitForStillness()
            driver.settle(1)
        }
        driver.settle(1)
        XCTAssertGreaterThanOrEqual(oldest.frame.minY, bar.frame.maxY, "the oldest message rests under the navigation bar: \(oldest.frame), bar to \(bar.frame.maxY): \(driver.recorderSummary())", file: file, line: line)
    }

    // About 60 pt a row: a list scrolls by less than 120 pt (the distance
    // that counts as away from the newest message) for about one count in
    // a few, which count that is depends on the screen.
    func testElevenMessages() { assertReachesOldest(count: 11) }
    func testTwelveMessages() { assertReachesOldest(count: 12) }
    func testThirteenMessages() { assertReachesOldest(count: 13) }
    func testFourteenMessages() { assertReachesOldest(count: 14) }
    func testFifteenMessages() { assertReachesOldest(count: 15) }
}
