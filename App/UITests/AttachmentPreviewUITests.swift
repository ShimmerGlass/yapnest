import XCTest

/// Photos announced with their shape and a preview (`PreviewsFixture` in the
/// app): the preview is drawn before the download, and no row changes size,
/// or moves the list, when the download finishes.
@MainActor
final class AttachmentPreviewUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func photos(_ driver: ConversationDriver) -> [XCUIElement] {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "📷 Photo"))
            .allElementsBoundByIndex
            .filter { $0.frame.height > 20 }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    func testPreviewsShowBeforeTheDownloadAndRowsKeepTheirSize() throws {
        let driver = ConversationDriver(
            fixture: "previews", open: "previews@fixture.test", environment: ["YAPNEST_DEV_HOLD_DOWNLOADS": "1"], context: "previews",
        )
        driver.waitForOpenChat()
        driver.waitForStillness()

        let end = driver.message(containing: "End of the previews.")
        driver.assertShown(end, "at the start")
        let before = photos(driver)
        XCTAssertGreaterThanOrEqual(before.count, 2, "no photos on screen: \(driver.recorderSummary())")
        XCTAssertTrue(before.allSatisfy { ($0.label).contains("Tap to download") }, "downloads finished too early: \(before.map(\.label))")
        let framesBefore = before.map(\.frame) + [end.frame]

        // The photo nearest the composer is drawn from its preview: colour, not the grey of an empty bubble.
        let newest = try XCTUnwrap(before.last)
        let color = averageColor(of: newest, at: CGPoint(x: 0.2, y: 0.25))
        XCTAssertGreaterThan(color.saturation, 0.3, "the preview isn't drawn: \(color)")

        driver.resetRecorder()
        // The downloads waited for this tap, so nothing above raced them.
        driver.app.buttons["releaseDownloads"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS %@)", "Tap to download"), object: before[0])
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed, "the downloads never finished")
        driver.settle(1.5)

        let after = photos(driver)
        XCTAssertEqual(after.count, before.count, "the photos on screen changed")
        XCTAssertTrue(after.allSatisfy { !$0.label.contains("Tap to download") }, "not all downloaded: \(after.map(\.label))")
        let framesAfter = after.map(\.frame) + [end.frame]
        for (index, (was, now)) in zip(framesBefore, framesAfter).enumerated() {
            XCTAssertEqual(now.height, was.height, accuracy: 0.5, "row \(index) changed height when its download finished: \(was) -> \(now)")
            XCTAssertEqual(now.minY, was.minY, accuracy: 0.5, "row \(index) moved when a download finished: \(was) -> \(now)")
        }
        driver.assertHeldAtBottom("while the downloads finished")
    }

    /// The colour at `point` (0...1 across and down) of what `element` shows.
    private func averageColor(of element: XCUIElement, at point: CGPoint) -> (red: Double, green: Double, blue: Double, saturation: Double) {
        guard let image = element.screenshot().image.cgImage else { return (0, 0, 0, 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )
        let (x, y) = (Int(Double(image.width) * point.x), Int(Double(image.height) * point.y))
        guard let patch = image.cropping(to: CGRect(x: x, y: y, width: 4, height: 4)) else { return (0, 0, 0, 0) }
        context?.interpolationQuality = .medium
        context?.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let (r, g, b) = (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        let high = max(r, g, b), low = min(r, g, b)
        return (r, g, b, high == 0 ? 0 : (high - low) / high)
    }
}
