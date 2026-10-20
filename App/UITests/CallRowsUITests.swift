import XCTest

/// A call is drawn as a small line in the chat, not as an empty bubble, and
/// the chat list reads it as the last message. The `interactions` fixture's
/// Calls chat holds a call of each outcome.
@MainActor
final class CallRowsUITests: InteractionsTestCase {
    override var chat: String? { "calls@fixture.test" }

    func testEachOutcomeHasItsRow() {
        for title in ["Outgoing call · 2:31", "Incoming call · 0:42", "Missed call", "Declined call", "Cancelled call", "Busy", "Call failed"] {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "no call row for \"\(title)\"")
        }
    }
}
