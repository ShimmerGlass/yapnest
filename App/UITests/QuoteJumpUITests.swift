import XCTest

/// Tapping the quote in a reply goes to the message it quotes, which is far
/// above, in the Quotes chat of the `interactions` fixture.
final class QuoteJumpUITests: InteractionsTestCase {
    override var chat: String? { "quotes@fixture.test" }

    func testTappingAReplysQuoteJumpsToTheOriginal() {
        let reply = app.staticTexts["Replying to the start."].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the reply isn't at the newest end")
        // The message just after the original, 40 messages up from the reply.
        let nextAfterOriginal = app.staticTexts["Filler 01 to push the start off screen."].firstMatch
        XCTAssertFalse(nextAfterOriginal.exists, "the start of the chat is on screen before the jump")
        let quote = app.staticTexts.matching(identifier: "The original words.").firstMatch
        XCTAssertTrue(quote.exists, "the reply doesn't show what it quotes")
        quote.tap()
        XCTAssertTrue(nextAfterOriginal.waitForExistence(timeout: 15), "the list didn't go to the original")
        // The original, and not just the quote in the reply.
        let words = app.staticTexts.matching(identifier: "The original words.").firstMatch
        XCTAssertTrue(words.isHittable, "the original isn't on screen")
        XCTAssertFalse(reply.exists && reply.isHittable, "the reply is still on screen")
    }
}
