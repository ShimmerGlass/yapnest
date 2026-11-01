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

    func neverBlank(seed: UInt64, name: String, address: String, flicks: Int, band: Band = .whole) {
        // The app's frame log then still holds the failing chat.
        continueAfterFailure = false
        let driver = ConversationDriver(
            fixture: "fuzz:\(seed)", open: address,
            context: "seed \(seed), \(name) (replay: YAPNEST_DEV_FIXTURE=fuzz:\(seed) YAPNEST_DEV_OPEN=\(address))",
        )
        driver.waitForOpenChat()
        driver.settle()
        let topAtOpen = driver.recorder()["top"] ?? 0
        jump(driver, to: band.start(of: topAtOpen))
        var flicksAtTheTop = 0
        for flick in 1...flicks {
            driver.flickTowardsOlder()
            driver.settle(0.6)
            driver.waitForStillness(timeout: 8)
            driver.assertNotBlank("at rest after flick \(flick) towards older messages")
            let top = driver.recorder()["top"] ?? .infinity
            if !band.isLast, top <= band.end(of: topAtOpen) { break }
            // Past the top a flick only bounces the list, and a chat that
            // takes 20 flicks to get there would spend the other 40 on it,
            // the most of the test's time. The bounce is still checked a few
            // times, and the flicks are a ceiling for a chat that takes more
            // to get there, as on the iPhone 17.
            if top <= 1 { flicksAtTheTop += 1 }
            if flicksAtTheTop > Self.flicksToBounceAtTheTop { break }
        }
    }

    private static let flicksToBounceAtTheTop = 3

    /// A share of the way up a chat, from where `from` to where `to` of the
    /// distance to its top is covered. A climb of 40 flicks, each taking
    /// seconds to coast, is too long for one test under load, and a test
    /// can't start part way up. So each share is a test of its own, which
    /// first gets to where its share starts with a few much faster flicks
    /// (`jump`) and checks the flicks from there. Together the shares check
    /// every stretch of the chat that one climb would. They aren't equal:
    /// the lazy stack's guess of the distance shrinks as rows are drawn, so
    /// a flick near the top covers far less of it than one at the start.
    struct Band {
        var from = 0.0
        var to = 1.0
        static let whole = Band()
        var isLast: Bool { to >= 1 }
        /// How far from the top of the chat a share starts and ends, given
        /// the distance when it opened.
        func start(of distance: CGFloat) -> CGFloat { distance * (1 - CGFloat(from)) }
        func end(of distance: CGFloat) -> CGFloat { distance * (1 - CGFloat(to)) }
    }

    /// Flicks up, unchecked, until the list is no farther from its top than
    /// `target`. Each is sized to the distance left, so it lands near. The
    /// velocity is capped: at 40,000 the app stopped answering on the iOS 26
    /// simulator, and 20,000 did once with six simulators running.
    func jump(_ driver: ConversationDriver, to target: CGFloat) {
        var jumps = 0
        while jumps < 15 {
            driver.settle(0.2)
            let left = (driver.recorder()["top"] ?? 0) - target
            if left <= 4000 { break }
            driver.flickTowardsOlder(velocity: min(12000, max(5000, left * 1.5)))
            jumps += 1
        }
        driver.waitForStillness(timeout: 8)
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

    /// What `checkChat` covers. A chat's two halves don't depend on each
    /// other, so the long seeds run them as tests of their own: the time
    /// allowance is per test, and a single one doing both ran past it when
    /// six simulators shared the Mac.
    enum Part {
        /// The keyboard opening and closing over the newest message.
        case keyboard
        /// Flicking up to the top and back to the newest message, or a
        /// share of the way up (see `Band`).
        case scrolling(Band = .whole)
    }

    static let everything: [Part] = [.keyboard, .scrolling()]

    func run(seed: UInt64) {
        runChat(seed: seed)
        runGroup(seed: seed)
    }

    func runChat(seed: UInt64, parts: [Part] = FuzzScrollingTestCase.everything) {
        checkChat(seed: seed, name: "Fuzz", address: "fuzz@fixture.test", newest: "Fuzz \(seed) newest.", keyboardRounds: 2, parts: parts)
    }

    func runGroup(seed: UInt64, parts: [Part] = FuzzScrollingTestCase.everything) {
        checkChat(seed: seed, name: "Fuzz Group", address: "fuzz-group@conference.fixture.test", newest: "Fuzz \(seed) group newest.", keyboardRounds: 1, parts: parts)
    }

    /// The chat is opened at launch, not from the chat list: these check the
    /// content, and a tap in the list can land while it's still settling.
    private func checkChat(seed: UInt64, name: String, address: String, newest marker: String, keyboardRounds: Int, parts: [Part]) {
        let driver = ConversationDriver(
            fixture: "fuzz:\(seed)", open: address,
            context: "seed \(seed), \(name) (replay: YAPNEST_DEV_FIXTURE=fuzz:\(seed) YAPNEST_DEV_OPEN=\(address))",
        )
        driver.waitForOpenChat()
        let newest = driver.message(containing: marker)
        driver.settle()
        driver.assertShown(newest, "after opening")
        driver.assertHeldAtBottom("while opening")

        for part in parts {
            switch part {
            case .keyboard:
                for round in 1...keyboardRounds {
                    driver.openKeyboard()
                    driver.assertShown(newest, "with the keyboard up, round \(round)")
                    driver.resetRecorder()
                    driver.closeKeyboard()
                    driver.settle()
                    driver.assertShown(newest, "after the keyboard closed, round \(round)")
                    driver.assertHeldAtBottom("while the keyboard closed, round \(round)")
                }
            case .scrolling(let band):
                scrollToTheTop(driver, band: band)
                guard band.isLast else { continue }
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
        }
    }

    /// How many flicks may reach the top of a chat, or the top of what has
    /// been loaded so far.
    private static let flicksToTheTop = 50

    /// Flicks up until the list stops at its top, checking at every stop that
    /// it isn't blank. A chat past the first window loads older messages on
    /// the way, and must end up with more rows than it opened with.
    private func scrollToTheTop(_ driver: ConversationDriver, band: Band) {
        let rowsAtOpen = driver.recorder()["rows"] ?? 0
        let topAtOpen = driver.recorder()["top"] ?? 0
        jump(driver, to: band.start(of: topAtOpen))
        var flicks = 0
        var stuck = 0
        var lastTop = driver.recorder()["top"] ?? 0
        while flicks < 80 {
            driver.flickTowardsOlder()
            // XCUITest returns only once the coast has stopped; this is the
            // recorder's publish delay.
            driver.settle(0.2)
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
            if !band.isLast, top <= band.end(of: topAtOpen) { break }
        }
        driver.waitForStillness()
        let record = driver.recorder()
        // A person flicking through a long history gets somewhere: the lazy
        // stack's guess of the rows it hasn't drawn must not run away with
        // the distance (it did, with rows of a few thousand points among rows
        // of a hundred, and 80 flicks left over 400,000 points). A share is
        // held to the whole climb's budget, so a runaway in any stretch of
        // the chat still fails.
        XCTAssertLessThanOrEqual(flicks, Self.flicksToTheTop, "\(driver.context): took \(flicks) flicks to reach the top: \(driver.recorderSummary())")
        guard band.isLast else {
            XCTAssertLessThanOrEqual(record["top"] ?? .infinity, band.end(of: topAtOpen), "\(driver.context): the list didn't reach the end of its share after \(flicks) flicks: \(driver.recorderSummary())")
            driver.assertNotBlank("at the end of its share of the way up")
            return
        }
        XCTAssertLessThanOrEqual(record["top"] ?? .infinity, 1, "\(driver.context): the list didn't reach its top after \(flicks) flicks: \(driver.recorderSummary())")
        if rowsAtOpen >= 500 {
            XCTAssertGreaterThan(record["rows"] ?? 0, rowsAtOpen, "\(driver.context): no older messages came in: \(driver.recorderSummary())")
        }
        driver.assertNotBlank("at the top")
    }
}

@MainActor
final class FuzzScrollingUITests: FuzzScrollingTestCase {
    func testSeedsFromTheEnvironment() throws {
        let seeds = (ProcessInfo.processInfo.environment["YAPNEST_FUZZ_SEEDS"] ?? "").split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        try XCTSkipIf(seeds.isEmpty, "set TEST_RUNNER_YAPNEST_FUZZ_SEEDS to run more seeds")
        for seed in seeds { run(seed: seed) }
    }
}

// Each seed's two chats are in classes of their own, so that two simulators
// can take them at once, and each chat's two halves are tests of their own
// (see `Part`).

/// A chat of 22 messages, all on the first screens.
@MainActor
final class FuzzSeed1ChatUITests: FuzzScrollingTestCase {
    func testSeed1Keyboard() { runChat(seed: 1, parts: [.keyboard]) }
    func testSeed1Scrolling() { runChat(seed: 1, parts: [.scrolling()]) }
}

/// A group of 120.
@MainActor
final class FuzzSeed1GroupUITests: FuzzScrollingTestCase {
    func testSeed1Keyboard() { runGroup(seed: 1, parts: [.keyboard]) }
    func testSeed1Scrolling() { runGroup(seed: 1, parts: [.scrolling()]) }
}

/// A chat of 33 messages.
@MainActor
final class FuzzSeed13ChatUITests: FuzzScrollingTestCase {
    func testSeed13Keyboard() { runChat(seed: 13, parts: [.keyboard]) }
    func testSeed13Scrolling() { runChat(seed: 13, parts: [.scrolling()]) }
}

/// A group of 114.
@MainActor
final class FuzzSeed13GroupUITests: FuzzScrollingTestCase {
    func testSeed13Keyboard() { runGroup(seed: 13, parts: [.keyboard]) }
    func testSeed13Scrolling() { runGroup(seed: 13, parts: [.scrolling()]) }
}

/// 258 messages.
@MainActor
final class FuzzSeed6ChatUITests: FuzzScrollingTestCase {
    func testSeed6Keyboard() { runChat(seed: 6, parts: [.keyboard]) }
    func testSeed6Scrolling() { runChat(seed: 6, parts: [.scrolling()]) }
}

@MainActor
final class FuzzSeed6GroupUITests: FuzzScrollingTestCase {
    func testSeed6Keyboard() { runGroup(seed: 6, parts: [.keyboard]) }
    func testSeed6Scrolling() { runGroup(seed: 6, parts: [.scrolling()]) }
}

/// 296 messages.
@MainActor
final class FuzzSeed28ChatUITests: FuzzScrollingTestCase {
    func testSeed28Keyboard() { runChat(seed: 28, parts: [.keyboard]) }
    func testSeed28ScrollingBand1() { runChat(seed: 28, parts: [.scrolling(Band(from: 0, to: 0.65))]) }
    func testSeed28ScrollingBand2() { runChat(seed: 28, parts: [.scrolling(Band(from: 0.65, to: 0.84))]) }
    func testSeed28ScrollingBand3() { runChat(seed: 28, parts: [.scrolling(Band(from: 0.84, to: 1))]) }
}

@MainActor
final class FuzzSeed28GroupUITests: FuzzScrollingTestCase {
    func testSeed28Keyboard() { runGroup(seed: 28, parts: [.keyboard]) }
    func testSeed28Scrolling() { runGroup(seed: 28, parts: [.scrolling()]) }
}

/// 570 messages, past the 500 the chat opens with, so older ones load.
@MainActor
final class FuzzSeed19ChatUITests: FuzzScrollingTestCase {
    func testSeed19Keyboard() { runChat(seed: 19, parts: [.keyboard]) }
    func testSeed19ScrollingBand1() { runChat(seed: 19, parts: [.scrolling(Band(from: 0, to: 0.24))]) }
    func testSeed19ScrollingBand2() { runChat(seed: 19, parts: [.scrolling(Band(from: 0.24, to: 0.46))]) }
    func testSeed19ScrollingBand3() { runChat(seed: 19, parts: [.scrolling(Band(from: 0.46, to: 0.66))]) }
    func testSeed19ScrollingBand4() { runChat(seed: 19, parts: [.scrolling(Band(from: 0.66, to: 0.84))]) }
    func testSeed19ScrollingBand5() { runChat(seed: 19, parts: [.scrolling(Band(from: 0.84, to: 1))]) }
}

@MainActor
final class FuzzSeed19GroupUITests: FuzzScrollingTestCase {
    func testSeed19Keyboard() { runGroup(seed: 19, parts: [.keyboard]) }
    func testSeed19Scrolling() { runGroup(seed: 19, parts: [.scrolling()]) }
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
    func testSeed28ChatNeverBlankFarUpBand1() { neverBlank(seed: 28, name: "Fuzz", address: "fuzz@fixture.test", flicks: 60, band: Band(from: 0, to: 0.65)) }
    func testSeed28ChatNeverBlankFarUpBand2() { neverBlank(seed: 28, name: "Fuzz", address: "fuzz@fixture.test", flicks: 60, band: Band(from: 0.65, to: 0.84)) }
    func testSeed28ChatNeverBlankFarUpBand3() { neverBlank(seed: 28, name: "Fuzz", address: "fuzz@fixture.test", flicks: 60, band: Band(from: 0.84, to: 1)) }
}
