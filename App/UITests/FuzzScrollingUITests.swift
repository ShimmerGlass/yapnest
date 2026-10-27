import XCTest

/// The message list's checks on seeded chats of every kind of content
/// (`FuzzFixture` in the app): opening at the bottom, the keyboard closing,
/// scrolling all the way up and back, and never a blank list, for a 1:1 chat
/// and a group.
///
/// The seeds are fixed so a run is repeatable. A failure names its seed;
/// replay it by hand with `YAPNEST_DEV_FIXTURE=fuzz:<seed>` (see CONTRIBUTING.md),
/// or run more seeds with `TEST_RUNNER_YAPNEST_FUZZ_SEEDS=4,5,6`.
///
/// Like the other UI tests, these need the simulator's software keyboard.
///
/// The checks are spread over several classes because parallel testing hands
/// out whole classes to its simulators: with all of them in one, they would
/// run one after another on a single simulator and set the length of the run.
@MainActor
class FuzzScrollingTestCase: XCTestCase {
    override func setUp() async throws {
        // Every check of a seed is worth seeing, not just the first.
        continueAfterFailure = true
    }

    // MARK: The checks

    func neverBlank(seed: UInt64, name: String, address: String, flicks: Int) {
        // The app's frame log then still holds the failing chat.
        continueAfterFailure = false
        let driver = ConversationDriver(
            fixture: "fuzz:\(seed)", open: address,
            context: "seed \(seed), \(name) (replay: YAPNEST_DEV_FIXTURE=fuzz:\(seed) YAPNEST_DEV_OPEN=\(address))",
        )
        driver.waitForOpenChat()
        driver.settle()
        for flick in 1...flicks {
            driver.flickTowardsOlder()
            driver.settle(0.6)
            driver.waitForStillness(timeout: 8)
            driver.assertNotBlank("at rest after flick \(flick) towards older messages")
        }
    }

    /// A history of tall messages comes to rest with rows that are each less
    /// than half in view, which is not a blank list: the recovery must leave
    /// it where it is. Each rest is watched for a second for any move.
    func tallRowsPartlyInViewAreLeftWhereTheyRest() {
        continueAfterFailure = false
        let driver = ConversationDriver(fixture: "tall-history", context: "tall-history")
        driver.openChat("Archive")
        driver.settle()
        for flick in 1...12 {
            driver.flickTowardsOlder()
            driver.settle(0.6)
            driver.waitForStillness(timeout: 8)
            let resting = driver.recorder()["top"] ?? 0
            driver.settle(1.5)
            let later = driver.recorder()["top"] ?? 0
            XCTAssertEqual(later, resting, accuracy: 1, "\(driver.context): the list moved by itself after resting, flick \(flick): \(driver.recorderSummary())")
            driver.assertNotBlank("at rest after flick \(flick)")
        }
    }

    // MARK: One seed

    func run(seed: UInt64) {
        runChat(seed: seed)
        runGroup(seed: seed)
    }

    func runChat(seed: UInt64) {
        checkChat(seed: seed, name: "Fuzz", address: "fuzz@fixture.test", newest: "Fuzz \(seed) newest.", keyboardRounds: 2)
    }

    func runGroup(seed: UInt64) {
        checkChat(seed: seed, name: "Fuzz Group", address: "fuzz-group@conference.fixture.test", newest: "Fuzz \(seed) group newest.", keyboardRounds: 1)
    }

    /// The chat is opened at launch, not from the chat list: these check the
    /// content, and a tap in the list can land while it's still settling.
    private func checkChat(seed: UInt64, name: String, address: String, newest marker: String, keyboardRounds: Int) {
        let driver = ConversationDriver(
            fixture: "fuzz:\(seed)", open: address,
            context: "seed \(seed), \(name) (replay: YAPNEST_DEV_FIXTURE=fuzz:\(seed) YAPNEST_DEV_OPEN=\(address))",
        )
        driver.waitForOpenChat()
        let newest = driver.message(containing: marker)
        driver.settle()
        driver.assertShown(newest, "after opening")
        driver.assertHeldAtBottom("while opening")

        for round in 1...keyboardRounds {
            driver.openKeyboard()
            driver.assertShown(newest, "with the keyboard up, round \(round)")
            driver.resetRecorder()
            driver.closeKeyboard()
            driver.settle()
            driver.assertShown(newest, "after the keyboard closed, round \(round)")
            driver.assertHeldAtBottom("while the keyboard closed, round \(round)")
        }

        scrollToTheTop(driver)
        // A chat shorter than the screen never leaves the bottom, and has no button.
        if driver.scrollToLatestButton.waitForExistence(timeout: 2) {
            driver.resetRecorder()
            driver.scrollToLatestButton.tap()
            driver.settle(1.5)
            driver.waitForStillness()
            let record = driver.recorder()
            XCTAssertFalse(
                record["top"] == 0 && driver.scrollToLatestButton.exists,
                "\(driver.context): the list stayed at its top when the scroll to latest button was tapped: \(driver.recorderSummary())",
            )
        }
        driver.assertShown(newest, "after scrolling back to the latest message")
    }

    /// How many flicks may reach the top of a chat, or the top of what has
    /// been loaded so far.
    private static let flicksToTheTop = 50

    /// Flicks up until the list stops at its top, checking at every stop that
    /// it isn't blank. A chat past the first window loads older messages on
    /// the way, and must end up with more rows than it opened with.
    private func scrollToTheTop(_ driver: ConversationDriver) {
        let rowsAtOpen = driver.recorder()["rows"] ?? 0
        var flicks = 0
        var stuck = 0
        var lastTop = driver.recorder()["top"] ?? 0
        while flicks < 80 {
            driver.flickTowardsOlder()
            driver.settle(1.2)
            flicks += 1
            driver.assertNotBlank("after flick \(flicks) towards older messages")
            let top = driver.recorder()["top"] ?? 0
            if top <= 1 {
                // The top may still grow if an older page is on its way.
                driver.waitForStillness()
                if (driver.recorder()["top"] ?? 0) <= 1 { break }
            }
            stuck = abs(top - lastTop) < 1 ? stuck + 1 : 0
            lastTop = top
            if stuck >= 3 { break }
        }
        driver.waitForStillness()
        let record = driver.recorder()
        // A person flicking through a long history gets somewhere: the lazy
        // stack's guess of the rows it hasn't drawn must not run away with
        // the distance (it did, with rows of a few thousand points among rows
        // of a hundred, and 80 flicks left over 400,000 points).
        XCTAssertLessThanOrEqual(flicks, Self.flicksToTheTop, "\(driver.context): took \(flicks) flicks to reach the top: \(driver.recorderSummary())")
        XCTAssertLessThanOrEqual(record["top"] ?? .infinity, 1, "\(driver.context): the list didn't reach its top after \(flicks) flicks: \(driver.recorderSummary())")
        if rowsAtOpen >= 500 {
            XCTAssertGreaterThan(record["rows"] ?? 0, rowsAtOpen, "\(driver.context): no older messages came in: \(driver.recorderSummary())")
        }
        driver.assertNotBlank("at the top")
    }
}

@MainActor
final class FuzzScrollingUITests: FuzzScrollingTestCase {
    /// A chat of 22 messages, all on the first screens, and a group of 120.
    func testSeed1() { run(seed: 1) }
    /// A chat of 33 messages and a group of 114.
    func testSeed13() { run(seed: 13) }

    func testSeedsFromTheEnvironment() throws {
        let seeds = (ProcessInfo.processInfo.environment["YAPNEST_FUZZ_SEEDS"] ?? "").split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        try XCTSkipIf(seeds.isEmpty, "set TEST_RUNNER_YAPNEST_FUZZ_SEEDS to run more seeds")
        for seed in seeds { run(seed: seed) }
    }
}

// The long seeds' two chats are in classes of their own, so that two
// simulators can take them at once.

/// 258 messages.
@MainActor
final class FuzzSeed6ChatUITests: FuzzScrollingTestCase {
    func testSeed6() { runChat(seed: 6) }
}

@MainActor
final class FuzzSeed6GroupUITests: FuzzScrollingTestCase {
    func testSeed6() { runGroup(seed: 6) }
}

/// 296 messages.
@MainActor
final class FuzzSeed28ChatUITests: FuzzScrollingTestCase {
    func testSeed28() { runChat(seed: 28) }
}

@MainActor
final class FuzzSeed28GroupUITests: FuzzScrollingTestCase {
    func testSeed28() { runGroup(seed: 28) }
}

/// 570 messages, past the 500 the chat opens with, so older ones load.
@MainActor
final class FuzzSeed19ChatUITests: FuzzScrollingTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // It takes about 239 seconds on an iPhone 17, against the 240 every
        // other test gets (`task ui`), so a slightly busy run timed it out.
        executionTimeAllowance = 360
    }

    func testSeed19() { runChat(seed: 19) }
}

@MainActor
final class FuzzSeed19GroupUITests: FuzzScrollingTestCase {
    func testSeed19() { runGroup(seed: 19) }
}

/// The chats that went blank far up the history: seed 1's group (before
/// the list was flipped), seed 28's chat and group on iOS 26.5. Only the
/// blank is checked, at rest after every flick, so a chat whose top is
/// out of reach doesn't fail them.
@MainActor
final class FuzzNeverBlankUITests: FuzzScrollingTestCase {
    func testSeed1GroupNeverBlankFarUp() { neverBlank(seed: 1, name: "Fuzz Group", address: "fuzz-group@conference.fixture.test", flicks: 20) }
    func testSeed28GroupNeverBlankFarUp() { neverBlank(seed: 28, name: "Fuzz Group", address: "fuzz-group@conference.fixture.test", flicks: 30) }
    func testTallRowsPartlyInViewAreLeftWhereTheyRest() { tallRowsPartlyInViewAreLeftWhereTheyRest() }
}

@MainActor
final class FuzzNeverBlankChatUITests: FuzzScrollingTestCase {
    func testSeed28ChatNeverBlankFarUp() { neverBlank(seed: 28, name: "Fuzz", address: "fuzz@fixture.test", flicks: 60) }
}
