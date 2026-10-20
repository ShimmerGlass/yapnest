import XCTest

/// What a tap on a bubble's content opens, on the Nest chat: a photo and a
/// file open in QuickLook, which Done closes, and a link leaves for the browser.
final class BubbleTapsUITests: InteractionsTestCase {
    private var viewer: XCUIElement { app.otherElements["QLPreviewControllerView"] }

    private func attachment(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    /// QuickLook hides its bars after a moment, and a tap on the content
    /// brings them back, so it looks for Done again if the bars went meanwhile.
    /// The tap goes to where Done was seen, as asking the element again can
    /// fail if the bars have gone in between.
    private func closeViewer(file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        for _ in 0..<4 where viewer.exists {
            if done.waitForExistence(timeout: 2), let seen = try? done.snapshot().frame {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: seen.midX, dy: seen.midY)).tap()
                _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: viewer)], timeout: 4)
            } else if viewer.exists {
                viewer.tap()
            }
        }
        waitUntilGone(viewer, "the viewer", file: file, line: line)
    }

    func testTappingAPhotoOpensItAndDoneClosesIt() {
        let photo = attachment("📷 Photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "no photo in the chat")
        photo.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "the photo didn't open")
        closeViewer()
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "the chat isn't back")
    }

    func testTappingAFileOpensItAndDoneClosesIt() {
        let file = attachment("📎 eggs.txt")
        XCTAssertTrue(file.waitForExistence(timeout: 10), "no file in the chat")
        file.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "the file didn't open")
        closeViewer()
        XCTAssertTrue(file.waitForExistence(timeout: 5), "the chat isn't back")
    }

    func testTappingALinkLeavesForTheBrowser() {
        let link = app.links["https://example.com/nest-notes"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the message has no link")
        // It's in the oldest message, which opens partly under the navigation
        // bar: a tap on it there lands on the bar.
        let bar = app.navigationBars.firstMatch
        for _ in 0..<3 where link.frame.minY < bar.frame.maxY {
            let list = app.windows.firstMatch
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            driver.waitForStillness()
        }
        XCTAssertGreaterThanOrEqual(link.frame.minY, bar.frame.maxY, "the link stays under the navigation bar")
        link.tap()
        let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue), object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 15), .completed, "the link didn't open anywhere")
        app.activate()
    }
}
