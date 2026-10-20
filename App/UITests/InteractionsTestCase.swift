import XCTest

/// A base for the tests on the `interactions` fixture: small chats for what a
/// person does with a message, the composer, the chat list and a chat's
/// banners. The account is offline, so these check what the screen shows at
/// once, not a server's answer.
@MainActor
class InteractionsTestCase: XCTestCase {
    var driver: ConversationDriver!

    /// The chat opened at launch; the chat list if nil.
    var chat: String? { "nest@fixture.test" }

    override func setUp() async throws {
        continueAfterFailure = false
        driver = ConversationDriver(fixture: "interactions", open: chat, context: name)
        if chat != nil {
            driver.waitForOpenChat()
            driver.waitForStillness()
        }
    }

    var app: XCUIApplication { driver.app }

    func bubble(_ words: String) -> XCUIElement {
        let text = app.staticTexts[words].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "no message saying \"\(words)\"")
        return text
    }

    func openMenu(on words: String, file: StaticString = #filePath, line: UInt = #line) {
        driver.openMenu(on: bubble(words), "\"\(words)\"", file: file, line: line)
    }

    func waitUntilGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, "\(what) is still there", file: file, line: line)
    }

    /// A reactions chip, which reads as "<emoji> <count>", then "Sending" while unanswered.
    func chip(_ emoji: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", emoji)).firstMatch
    }
}
