import XCTest

/// The round button over the composer that takes the list back to the newest
/// message, tapped at the moments a person taps it: straight after a flick,
/// once the list has stopped, and as soon as the button shows. The tap has
/// to reach the button and not the photo beneath it, and the list has to end
/// at the newest message from wherever it was.
///
/// A tap waits for the app to be idle, so these can't land on a list that is
/// still coasting; `ConversationScrollTests` covers the model's side of that.
///
/// Like the other UI tests, these need the simulator's software keyboard.
@MainActor
final class ScrollToLatestButtonUITests: ScrollToLatestTestCase {
    /// Tapped as soon as the flick is over.
    func testTapStraightAfterTheFlick() throws {
        try check(seed: 19, flicks: 2, settleAfterFlick: 0, "straight after the flick")
    }

    /// Tapped once the list has stopped.
    func testTapAfterTheListSettled() throws {
        try check(seed: 19, flicks: 3, settleAfterFlick: 2, "after the list settled")
    }

    /// Tapped as soon as the button is on screen, which is at the start of
    /// the first flick away from the bottom.
    func testTapAsTheButtonAppears() throws {
        try check(seed: 28, flicks: 1, settleAfterFlick: 0, "as the button appeared")
    }
}

/// Split from the class above, as parallel testing hands out whole classes.
@MainActor
final class ScrollToLatestGroupUITests: ScrollToLatestTestCase {
    /// The same on a group chat, whose photos sit under the button too.
    func testTapInAGroupChat() throws {
        try check(seed: 19, flicks: 2, settleAfterFlick: 0.3, "in the group chat", group: true)
    }
}

@MainActor
final class ScrollToLatestFarEndUITests: ScrollToLatestTestCase {
    /// From the far end of a chat whose newest message is taller than the
    /// scroll view's half-in-view rule can report, the scroll to latest lands
    /// on a row that fills the view without anything reporting it. The list
    /// is right, and the app must leave it alone rather than nudge its margin
    /// to recover it. It is the later trips that show it.
    func testTapFromTheFarEndLeavesAListThatShowsTheNewestMessageAlone() throws {
        try check(seed: 28, flicks: 40, settleAfterFlick: 0.8, "from the far end", group: true, untilNearTop: true, expectsNoNudges: true)
    }
}

@MainActor
final class ScrollToLatestPlacementUITests: XCTestCase {
    /// The button sits in a column with the microphone at the end of the
    /// composer's row. It was laid out with its own margin, which put it to
    /// the left of the microphone.
    func testTheButtonIsCentredOverTheMicrophone() throws {
        let driver = ConversationDriver(fixture: "fuzz:19", open: "fuzz@fixture.test", context: "seed 19, 1:1")
        driver.waitForOpenChat()
        driver.settle()
        driver.flickTowardsOlder()
        XCTAssertTrue(driver.scrollToLatestButton.waitForExistence(timeout: 5), "\(driver.context): no button after flicking up")
        let microphone = driver.app.buttons["Record voice message"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 2), "\(driver.context): no microphone button")
        XCTAssertEqual(driver.scrollToLatestButton.frame.midX, microphone.frame.midX, accuracy: 0.5, "\(driver.context): the button isn't over the microphone")
    }
}

@MainActor
class ScrollToLatestTestCase: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func check(seed: UInt64, flicks: Int, settleAfterFlick: TimeInterval, _ when: String, group: Bool = false, rounds: Int = 3, untilNearTop: Bool = false, expectsNoNudges: Bool = false) throws {
        let address = group ? "fuzz-group@conference.fixture.test" : "fuzz@fixture.test"
        let marker = group ? "Fuzz \(seed) group newest." : "Fuzz \(seed) newest."
        let driver = ConversationDriver(
            fixture: "fuzz:\(seed)", open: address,
            context: "seed \(seed), \(group ? "group" : "1:1") (replay: YAPNEST_DEV_FIXTURE=fuzz:\(seed) YAPNEST_DEV_OPEN=\(address))",
        )
        driver.waitForOpenChat()
        let newest = driver.message(containing: marker)
        driver.settle()
        driver.assertShown(newest, "after opening")
        // At the bottom there is nothing to scroll to. A button left in the
        // tree at no opacity would stand in for the real one here, and a tap
        // on it falls through to the row beneath.
        XCTAssertFalse(driver.scrollToLatestButton.exists, "\(driver.context): the scroll to latest button is there at the bottom")

        for round in 1...rounds {
            for _ in 0..<flicks {
                driver.flickTowardsOlder()
                if settleAfterFlick > 0 { driver.settle(settleAfterFlick) }
                if untilNearTop, (driver.recorder()["top"] ?? .infinity) <= 5000 { break }
            }
            // Past its far end the list is blank and shows no button. That's a
            // separate known bug, a blank list far up the history, not this.
            try XCTSkipIf(untilNearTop && (driver.recorder()["top"] ?? 0) < 0, "\(driver.context): the list went past its far end: \(driver.recorderSummary())")
            XCTAssertTrue(driver.scrollToLatestButton.waitForExistence(timeout: 5),"\(driver.context): no button after flicking up, round \(round): \(driver.recorderSummary())")
            driver.resetRecorder()
            driver.scrollToLatestButton.tap()
            let tapped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'latestTaps=1'"), object: driver.recorderElement)
            XCTAssertEqual(XCTWaiter.wait(for: [tapped], timeout: 3), .completed, "\(driver.context): the tap didn't reach the button \(when), round \(round): \(driver.recorderSummary())")
            XCTAssertFalse(driver.app.buttons["Done"].exists, "\(driver.context): a photo opened in the viewer \(when), round \(round)")
            driver.settle(1.5)
            driver.waitForStillness()
            driver.assertShown(newest, "after scrolling to the latest message \(when), round \(round)")
            if expectsNoNudges {
                XCTAssertEqual(driver.recorder()["endNudges"], 0, "\(driver.context): the list was nudged at its end though it showed the newest message \(when), round \(round): \(driver.recorderSummary())")
            }
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: driver.scrollToLatestButton)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "\(driver.context): the button is still there \(when), round \(round): \(driver.recorderSummary())")
        }
    }
}
