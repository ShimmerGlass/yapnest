import XCTest

/// A flick back towards the newest message, from far up a long chat, coasts
/// on its own. Nothing may take over the coast, which pauses the list just
/// short of the end, and nothing may move the list once it stops (#232). A
/// coast that runs out a little short of the end stays there, as a weaker
/// flick does under load: the list isn't pulled the rest of the way.
@MainActor
final class FlickBackToNewestUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testAFlickBackToTheNewestMessageCoastsToTheEndAndStays() throws {
        let driver = ConversationDriver(fixture: "long-history", open: "history@fixture.test", context: "flick back to the newest")
        driver.waitForOpenChat()
        let newest = driver.message(containing: "History 0749:")
        driver.settle()
        driver.assertShown(newest, "after opening")

        // A coast goes about half its velocity in points, so these end at,
        // or a little short of, the newest end of what one flick up covered.
        for velocity in [5000, 5800, 6200] as [CGFloat] {
            driver.flickTowardsOlder()
            // Long enough for the list to hold its newest end, which it does
            // once it has been away from the bottom for a moment.
            driver.settle(1.5)
            driver.waitForStillness()
            XCTAssertGreaterThan(driver.recorder()["top"] ?? 0, 0, "\(driver.context): the list didn't go up: \(driver.recorderSummary())")
            driver.resetRecorder()

            driver.flickTowardsNewer(velocity: velocity)
            driver.settle(3)
            driver.waitForStillness()

            XCTAssertTrue(newest.exists, "\(driver.context): a flick back at \(velocity) didn't reach the newest message: \(driver.recorderSummary())")
            let rested = newest.frame
            driver.settle(1)
            XCTAssertEqual(newest.frame.minY, rested.minY, accuracy: 1, "\(driver.context): the list moved after a flick back at \(velocity) came to rest: \(driver.recorderSummary())")
            XCTAssertEqual(driver.recorder()["takeovers"], 0, "\(driver.context): an animated scroll took over the coast of a flick back at \(velocity): \(driver.recorderSummary())")
        }
    }
}
