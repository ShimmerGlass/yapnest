import XCTest

/// A group is joined again on every connection, which usually takes a
/// moment, so its header says "Joining…" only once that takes longer. The
/// fixture's session never connects, so the fuzz group stays joining.
@MainActor
final class GroupHeaderUITests: XCTestCase {
    func testJoiningShowsOnlyOnceItTakesAWhile() {
        let driver = ConversationDriver(fixture: "fuzz:1", open: "fuzz-group@conference.fixture.test", context: name)
        driver.waitForOpenChat()
        let joining = driver.app.staticTexts["Joining…"].firstMatch
        XCTAssertFalse(joining.exists, "the header says Joining… as soon as the group opens")
        XCTAssertTrue(joining.waitForExistence(timeout: 10), "the header never says Joining…")
    }
}
