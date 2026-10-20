import XCTest

/// Voice messages on the `interactions` fixture's Voice chat: a clip not yet
/// downloaded, one without a known length, one that is ready, one that failed,
/// a song, and an Opus one, which the player can't play and so shows as a file.
@MainActor
final class VoiceMessageUITests: InteractionsTestCase {
    override var chat: String? { "voice@fixture.test" }

    /// The players, top to bottom: a player is 220 by 40 points, which tells it
    /// from the row of the message around it and from a file's row.
    private func clips() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Voice message", "Audio file"))
            .allElementsBoundByIndex
            .filter { abs($0.frame.height - 40) < 1 && abs($0.frame.width - 220) < 1 }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    func testEveryStateOfAClipIsAsTallAsTheOthers() {
        let found = clips()
        XCTAssertEqual(found.count, 5, "the clips on screen: \(found.map(\.label))")
        XCTAssertEqual(found[0].label, "Voice message, 0:12")
        XCTAssertEqual(found[1].label, "Voice message", "a clip of unknown length")
        XCTAssertEqual(found[3].label, "Voice message, 0:05")
        XCTAssertEqual(found[4].label, "Audio file: Song.mp3, 3:20", "a song keeps the player but is not a voice message")
    }

    func testDownloadingAClipDoesNotMoveTheList() {
        let before = clips()
        let newest = driver.message(containing: "Voice chat newest.")
        driver.assertShown(newest, "before the download")
        let frames = before.map(\.frame) + [newest.frame]
        driver.resetRecorder()
        // Offline, so this one fails: the bubble then says so in the same space.
        before[0].tap()
        driver.settle(2)
        let after = clips()
        XCTAssertEqual(after.count, before.count)
        for (index, (was, now)) in zip(frames, after.map(\.frame) + [driver.message(containing: "Voice chat newest.").frame]).enumerated() {
            XCTAssertEqual(now.height, was.height, accuracy: 0.5, "row \(index) changed height after a download: \(was) -> \(now)")
            XCTAssertEqual(now.minY, was.minY, accuracy: 0.5, "row \(index) moved after a download: \(was) -> \(now)")
        }
        driver.assertShown(driver.message(containing: "Voice chat newest."), "after a clip was downloaded")
    }

    func testAnOpusClipIsShownAsAFile() {
        XCTAssertTrue(app.staticTexts["RECORDING_20260101_101011123.oga"].waitForExistence(timeout: 10), "no file row for the Opus clip")
        XCTAssertEqual(clips().count, 5, "the Opus clip is drawn as a player")
    }

    func testPlayingAClipShowsItsPosition() {
        let ready = clips()[2]
        XCTAssertEqual(ready.value as? String ?? "", "", "a clip not played has a position")
        ready.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != ''"), object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed, "the clip never started: \(ready.debugDescription)")
        // Paused, so the test doesn't leave sound playing.
        ready.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
    }
}
