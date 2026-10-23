import XCTest

/// Drives the app on a dev fixture and reads its frame recorder, for UI
/// tests that check the message list. Every failure starts with `context`,
/// so a fuzz failure says which seed to replay.
@MainActor
final class ConversationDriver {
    /// How far from the bottom a list that follows it may be, in points.
    static let bottomTolerance: CGFloat = 2

    // How long to wait for the app to be ready, never for how quickly it
    // gets there: a loaded machine, or a cold launch of a heavy fixture, is
    // slow, and a test that asserts speed uses its own, shorter window.
    /// For a chat to open and its frame recorder to appear.
    static let openTimeout: TimeInterval = 30
    /// For the chat list, or a row in it, to show.
    static let listTimeout: TimeInterval = 30
    /// For the first message of an open chat to show.
    static let contentTimeout: TimeInterval = 20

    let app = XCUIApplication()
    let context: String

    /// - Parameter open: a chat's address, to open it straight away rather
    ///   than by tapping it in the chat list.
    init(fixture: String, open: String? = nil, environment: [String: String] = [:], context: String) {
        self.context = context
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchEnvironment["YAPNEST_DEV_FIXTURE"] = fixture
        if let open { app.launchEnvironment["YAPNEST_DEV_OPEN"] = open }
        app.launchEnvironment["YAPNEST_DEV_FRAME_LOG"] = "1"
        app.launch()
    }

    /// Waits for the chat opened at launch.
    func waitForOpenChat(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(recorderElement.waitForExistence(timeout: Self.openTimeout), "\(context): the chat didn't open, or has no frame recorder; is this a Debug build?", file: file, line: line)
    }

    // MARK: Driving the app

    func openChat(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        // A chat's row reads as one button: its name, then the rest.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.listTimeout), "\(context): no chat named \(name) in the list", file: file, line: line)
        Self.tapToOpen(row, recorder: recorderElement, context: context, file: file, line: line)
    }

    /// Taps a chat's row and waits for its recorder. A tap that lands while
    /// the list is still settling can be lost, so one that brought nothing in
    /// half the time is repeated once; never more, or the chat opens twice.
    static func tapToOpen(_ row: XCUIElement, recorder: XCUIElement, context: String, file: StaticString = #filePath, line: UInt = #line) {
        row.tap()
        if !recorder.waitForExistence(timeout: openTimeout / 2), row.exists {
            row.tap()
        }
        XCTAssertTrue(recorder.waitForExistence(timeout: openTimeout), "\(context): the conversation has no frame recorder; is this a Debug build?", file: file, line: line)
    }

    var composer: XCUIElement { app.textViews["composer"] }

    func openKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        composer.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "\(context): no keyboard came up: turn off I/O > Keyboard > Connect Hardware Keyboard in the simulator", file: file, line: line,
        )
        settle()
    }

    /// Taps in a margin of the list beside the messages, where the list's
    /// tap puts the keyboard away. A fixed spot isn't safe: a photo, link or
    /// file can reach into the leading margin, and a tap on it opens it.
    func closeKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: freeMargin()).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "\(context): the keyboard didn't close", file: file, line: line)
    }

    /// Somewhere in the list a tap only puts the keyboard away, as a
    /// fraction of the window: a margin beside messages that have nothing to
    /// open, or failing that the middle of such a message. A message's row
    /// reads as one element, "Sender: words". One with a photo, file, link
    /// or button inside opens on a tap anywhere across its row, margin
    /// included, so its whole row is kept clear of.
    private func freeMargin() -> CGVector {
        let window = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = composer.frame.minY - 8
        let list = CGRect(x: 0, y: top, width: window.width, height: max(0, bottom - top))
        var covers: [CGRect] = []
        var plainRows: [CGRect] = []
        func isRow(_ element: XCUIElementSnapshot) -> Bool {
            element.label.range(of: #"^[^:\n]{1,40}: "#, options: .regularExpression) != nil
        }
        func opens(_ element: XCUIElementSnapshot) -> Bool {
            element.children.contains { child in
                ((child.elementType == .button || child.elementType == .link) && !isRow(child)) || opens(child)
            }
        }
        if let snapshot = try? app.snapshot() {
            var stack = [snapshot]
            while let element = stack.popLast() {
                if isRow(element) {
                    if opens(element) { covers.append(element.frame) } else { plainRows.append(element.frame) }
                    continue
                }
                stack.append(contentsOf: element.children)
                if element.elementType == .button || element.elementType == .link, element.identifier != "scrollRecorder",
                   element.frame.width < window.width * 0.9 {
                    covers.append(element.frame)
                }
            }
        }
        func isFree(_ point: CGPoint) -> Bool {
            list.contains(point) && !covers.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
        var candidates: [CGPoint] = []
        for fraction in stride(from: 0.1, through: 0.9, by: 0.1) {
            let y = top + (bottom - top) * fraction
            candidates += [CGPoint(x: window.width * 0.02, y: y), CGPoint(x: window.width * 0.98, y: y)]
        }
        for row in plainRows {
            let visible = row.intersection(list)
            if !visible.isNull { candidates.append(CGPoint(x: min(max(row.midX, 40), window.width - 40), y: visible.midY)) }
        }
        if let point = candidates.first(where: isFree) {
            return CGVector(dx: point.x / window.width, dy: point.y / window.height)
        }
        XCTFail("\(context): nowhere in the list to tap that doesn't open something; kept clear of \(covers)")
        return CGVector(dx: 0.02, dy: 0.3)
    }

    /// A fast drag down in the middle of the list, which coasts on towards older messages.
    func flickTowardsOlder() {
        let list = app.windows.firstMatch
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 5000), thenHoldForDuration: 0)
    }

    /// Slow drags that stop where they end, `times` over, towards older
    /// messages or back towards the newest.
    func drag(towardsOlder: Bool, times: Int = 3, hold: TimeInterval = 0.5) {
        let list = app.windows.firstMatch
        for _ in 0..<times {
            let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let bottom = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let (from, to) = towardsOlder ? (top, bottom) : (bottom, top)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 600), thenHoldForDuration: hold)
        }
    }

    var scrollToLatestButton: XCUIElement { app.buttons["Scroll to latest message"] }

    func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits until the list stops reporting new frames.
    func waitForStillness(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = recorder()["samples"]
        while Date() < deadline {
            settle(0.3)
            let now = recorder()["samples"]
            if now == last { return }
            last = now
        }
    }

    // MARK: Messages

    /// A text drawn on screen with these words in it. Unlike `message(containing:)`
    /// it only looks at static texts, so a row's own label doesn't match.
    func text(containing words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// A long press sometimes isn't taken while the list is still settling, so it's tried again.
    func openMenu(on target: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            target.press(forDuration: 1.0)
            if app.buttons["Reply"].waitForExistence(timeout: 4) { return }
        }
        XCTFail("\(context): the menu didn't come up on \(what)", file: file, line: line)
    }

    /// Opens the Settings sheet from the chat list.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "\(context): no Settings button on the chat list", file: file, line: line)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "\(context): Settings didn't open", file: file, line: line)
    }

    /// Opens the open chat's settings from its header. A group's are titled "Group Settings".
    func openChatSettings(title: String = "Chat Settings", file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons["Chat Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "\(context): no Chat Settings button in the header", file: file, line: line)
        settings.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "\(context): \(title) didn't open", file: file, line: line)
    }

    /// The chat settings row for the contact's nickname, which reads as one button: "Nickname", then its value.
    var nicknameRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Nickname")).firstMatch
    }

    /// A message's row, which reads as one element: who sent it, then its words.
    func message(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The message is drawn where it can be read: the list isn't blank, and
    /// the message's bubble reaches into the room between the bars and the
    /// composer, ending just above the composer.
    func assertShown(_ message: XCUIElement, _ when: String, maxGap: CGFloat = 60, file: StaticString = #filePath, line: UInt = #line) {
        guard message.waitForExistence(timeout: 5) else {
            // Its frame can't be read either, and asking throws.
            XCTFail("\(context): the newest message isn't there \(when): \(recorderSummary())", file: file, line: line)
            return
        }
        XCTAssertTrue(message.isHittable, "\(context): the newest message can't be reached \(when): \(recorderSummary())", file: file, line: line)
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = composer.frame.minY
        let room = CGRect(x: 0, y: top, width: app.windows.firstMatch.frame.width, height: max(0, bottom - top))
        XCTAssertTrue(message.frame.intersects(room), "\(context): the newest message is off screen \(when): \(message.frame) not in \(room)", file: file, line: line)
        // A little room is left under the newest bubble, plus its reactions
        // chip, which hangs below it.
        XCTAssertLessThanOrEqual(message.frame.maxY, bottom + 1, "\(context): the newest message runs under the composer \(when)", file: file, line: line)
        XCTAssertGreaterThan(message.frame.maxY, bottom - maxGap, "\(context): the newest message ends far above the composer \(when): \(message.frame), composer at \(bottom)", file: file, line: line)
        assertNotBlank(when, file: file, line: line)
    }

    func assertNotBlank(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(recorder()["visible"] ?? 0, 0, "\(context): the list reports no rows on screen \(when): \(recorderSummary())", file: file, line: line)
    }

    func assertHeldAtBottom(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let record = recorder()
        XCTAssertGreaterThan(record["samples"] ?? 0, 0, "\(context): the recorder saw no frames \(when)", file: file, line: line)
        XCTAssertLessThanOrEqual(
            record["maxAway"] ?? .infinity, Self.bottomTolerance,
            "\(context): the list left the bottom \(when): \(recorderSummary())", file: file, line: line,
        )
    }

    // MARK: The frame recorder

    var recorderElement: XCUIElement { app.buttons["scrollRecorder"] }

    func recorderSummary() -> String {
        recorderElement.value as? String ?? ""
    }

    /// The recorder's numbers, by name (see `ScrollRecord.summary`).
    func recorder() -> [String: CGFloat] {
        var values: [String: CGFloat] = [:]
        for pair in recorderSummary().split(separator: " ") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let value = Double(parts[1]) { values[String(parts[0])] = CGFloat(value) }
        }
        return values
    }

    func resetRecorder(file: StaticString = #filePath, line: UInt = #line) {
        recorderElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The summary is published a moment after it changes.
        settle(0.2)
        XCTAssertEqual(recorder()["samples"], 0, "\(context): the recorder didn't reset: \(recorderSummary())", file: file, line: line)
    }
}
