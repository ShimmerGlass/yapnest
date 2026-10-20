import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
import YapnestKit
@testable import Yapnest

/// Behaviour that was broken once and fixed. Each test fails if its fix is taken out.
@MainActor
struct ConversationRegressionTests {
    private func attach(_ f: ConversationFixture) -> ConversationInputBar {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        bar.onTextChanged = { [weak model = f.model] text in model?.textChanged(text) }
        f.model.composer.bar = bar
        f.model.composerAttached()
        return bar
    }

    private func copy(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data("contents of \(name)".utf8).write(to: file)
        return file
    }

    private func messageCount(_ f: ConversationFixture) -> Int {
        (try? f.database.reader.read { try Message.filter(Column("conversationId") == f.conversation.id!).fetchCount($0) }) ?? 0
    }

    // MARK: Sending

    @Test func leavingTheChatMidSendStillSendsEveryStagedFileAndClearsTheCopies() async throws {
        let f = try ConversationFixture()
        let files = try [copy("one.txt"), copy("two.txt"), copy("three.txt")]
        for file in files { f.model.stage(file, isPhoto: false) }
        f.model.send("")
        // The chat is left before the sends ran.
        f.reopen()

        await eventually("the staged files were never sent") { messageCount(f) == 3 }
        await eventually("the copies were never removed") { files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
    }

    @Test func sendingAnEditKeepsWhatIsStagedForTheNextMessage() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo", .outgoing, remoteId: "r1")
        await f.start()
        let file = try copy("keep.txt")
        f.model.stage(file, isPhoto: false)
        f.model.startEditing(mine.id!)
        f.model.send("fixed")

        #expect(f.model.pendingAttachments.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await eventually("the edit never applied") { f.model.rows.first?.message.body == "fixed" }
        #expect(messageCount(f) == 1)
        AttachmentPicker.discardCopy(file)
    }

    @Test func twoAttachFailuresMakeOnePromptThatNamesBoth() throws {
        struct Failure: LocalizedError { var errorDescription: String? }
        let f = try ConversationFixture()
        f.model.reportAttachFailure(Failure(errorDescription: "too big"))
        f.model.reportAttachFailure(Failure(errorDescription: "unreadable"))
        guard case .notice(let title, let message)? = f.model.prompt else {
            Issue.record("no prompt")
            return
        }
        #expect(message.contains("too big") && message.contains("unreadable"))
        #expect(title == String(localized: "\(2) files couldn't be attached"))

        // The same reason twice is said once.
        f.model.reportAttachFailure(Failure(errorDescription: "unreadable"))
        guard case .notice(_, let again)? = f.model.prompt else { return }
        #expect(again.components(separatedBy: "unreadable").count == 2)

        // An alert the user dismissed doesn't collect the next failure.
        f.model.prompt = nil
        f.model.reportAttachFailure(Failure(errorDescription: "gone"))
        guard case .notice(_, let fresh)? = f.model.prompt else { return }
        #expect(fresh == "gone")
    }

    // MARK: Rows

    @Test func aFailedFileIsReadOutWithItsNameThatItWasNotSentAndWhen() async throws {
        let f = try ConversationFixture()
        let failed = try f.add("", .outgoing, status: .failed)
        try f.attach("report.pdf", to: failed)
        await f.start()
        let label = f.model.rows[0].content.accessibilityLabel
        #expect(label.contains("report.pdf"))
        #expect(label.contains(String(localized: "Not sent")))
        #expect(label.contains(failed.timestamp.formatted(date: .omitted, time: .shortened)))
    }

    @Test func dayHeadersFollowTheClockWhenTheDayChanges() async throws {
        let f = try ConversationFixture()
        let cal = Calendar.current
        let day = cal.date(bySettingHour: 12, month: 3, day: 5, year: 2024)
        try f.add("hi", at: day, read: true)
        f.model.now = { day.addingTimeInterval(3600) }
        await f.start()
        #expect(f.model.rows[0].content.layout.dayHeader == String(localized: "Today"))

        f.model.now = { day.addingTimeInterval(24 * 3600) }
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        await eventually("the header stayed stale") { f.model.rows[0].content.layout.dayHeader == String(localized: "Yesterday") }
    }

    @Test func aLocaleChangeBuildsTheRowsAgain() async throws {
        let f = try ConversationFixture()
        let day = Calendar.current.date(bySettingHour: 12, month: 3, day: 5, year: 2024)
        try f.add("hi", at: day, read: true)
        f.model.now = { day }
        await f.start()
        let before = f.model.rows[0].revision

        // Seen through the header, which depends on the clock.
        f.model.now = { day.addingTimeInterval(24 * 3600) }
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        await eventually("the rows were never built again") { f.model.rows[0].revision > before }
    }

    @Test func theReplyBannerSaysWhatIsRepliedToNotItsRawBody() async throws {
        let f = try ConversationFixture()
        let photo = try f.add("aesgcm://example.com/abc.jpg#0123", read: true)
        try f.attach("abc.jpg", to: photo, state: .remote, mimeType: "image/jpeg")
        let place = try f.add("geo:48.85,2.35", read: true)
        await f.start()
        let bar = attach(f)

        f.model.reply(to: photo.id!)
        #expect(bar.replyText.text == String(localized: "📷 Photo"))
        f.model.reply(to: place.id!)
        #expect(bar.replyText.text == GeoLocation.summary)
        #expect(!(bar.replyText.text ?? "").contains("aesgcm"))
    }

    // MARK: Composer

    @Test func theMentionHandlerIsThereEvenIfTheComposerAppearsBeforeTheGroupIsKnown() async throws {
        let f = try ConversationFixture(kind: .groupchat)
        try f.makeGroup()
        let bar = attach(f)
        // The composer is up before `start` has read that this is a group.
        #expect(bar.onMentionQuery != nil)
        await f.start()
        #expect(f.model.isGroup)
        #expect(bar.onMentionQuery != nil)
    }

    @Test func inAOneToOneChatMentionsSuggestNobody() async throws {
        let f = try ConversationFixture()
        await f.start()
        let bar = attach(f)
        bar.onMentionQuery?("a")
        #expect(bar.mentionSuggestions.isEmpty)
    }

    // MARK: Drafts

    @Test func typedTextSurvivesTheChatBeingTornDownAndComesBackOnReopen() async throws {
        let f = try ConversationFixture()
        let bar = attach(f)
        await f.start()
        bar.setText("unfinished", notify: true)

        // Gone before the debounce or any flush ran.
        f.reopen()
        await DraftWriter.shared.settled()
        #expect(try f.database.draft(peer: f.peer) == "unfinished")

        let again = attach(f)
        await f.start()
        #expect(again.text == "unfinished")
    }

    @Test func anEditStartedWhileTheComposerIsGoneStillGivesTheDraftBack() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo", .outgoing)
        let bar = attach(f)
        await f.start()
        bar.setText("my draft", notify: true)

        f.model.composer.bar = nil
        f.model.startEditing(mine.id!)
        let back = attach(f)
        #expect(back.text == "typo")
        f.model.cancelReplyOrEdit()
        #expect(back.text == "my draft")
    }

    // MARK: Telling the contact we are typing

    /// Typing, then the chat going quiet and back: the state is `.active`, so
    /// anything that wrongly reports typing shows as `.composing`.
    private func typedThenActive(_ f: ConversationFixture, _ bar: ConversationInputBar, _ text: String) {
        f.model.setOnScreen(true)
        bar.setText(text, notify: true)
        #expect(f.model.chatState == .composing)
        f.model.setOnScreen(false)
        f.model.setOnScreen(true)
        #expect(f.model.chatState == .active)
    }

    @Test func restoringAStoredDraftDoesNotSayWeAreTyping() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("draft", peer: f.peer)
        let bar = attach(f)
        // In front before the draft is read, so typing would be reported.
        f.model.setOnScreen(true)
        await f.start()
        #expect(bar.text == "draft")
        #expect(f.model.chatState == .active)
    }

    @Test func aComposerGivenBackItsTextDoesNotSayWeAreTyping() async throws {
        let f = try ConversationFixture()
        let bar = attach(f)
        await f.start()
        typedThenActive(f, bar, "abc")
        let fresh = attach(f)
        #expect(fresh.text == "abc")
        #expect(f.model.chatState == .active)
    }

    @Test func cancellingAnEditDoesNotSayWeAreTyping() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo", .outgoing)
        let bar = attach(f)
        await f.start()
        typedThenActive(f, bar, "abc")
        f.model.startEditing(mine.id!)
        f.model.cancelReplyOrEdit()
        #expect(bar.text == "abc")
        #expect(f.model.chatState == .active)
    }

    @Test func sendingAnEditDoesNotSayWeAreTyping() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo", .outgoing)
        let bar = attach(f)
        await f.start()
        typedThenActive(f, bar, "abc")
        f.model.startEditing(mine.id!)
        f.model.send("fixed")
        #expect(bar.text == "abc")
        #expect(f.model.chatState == .active)
    }

    // MARK: Jumps and paging

    @Test func aJumpWithinTheWindowCancelsAnOlderLoadAndHoldsOffAnotherWhileSettling() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(700)
        await f.start()
        let target = all[300]

        f.model.nearTopChanged(true)
        f.model.reveal(target.id!)
        f.model.nearTopChanged(true)
        #expect(f.model.scroll.messageID == target.id)
        // The scroll can cross the near-top line; loading then would pin another row.
        #expect(await stays { f.model.rows.count == 500 && f.model.scroll.messageID == target.id })
    }

    @Test func aJumpOutsideTheWindowIsNotLostToAnOlderLoadStartedJustBefore() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(1700)
        await f.start()

        // The older page is held after it started, so the jump lands first and
        // the page then arrives for a window that is no longer the one it was for.
        let gate = Gate()
        f.model.olderLoadHook = { await gate.pass() }
        f.model.nearTopChanged(true)
        await eventually("the older load never started") { gate.entered }

        f.model.reveal(all[0].id!)
        await eventually("the jump never landed") { f.model.scroll.messageID == all[0].id && f.rowIDs.first == all[0].id }
        gate.open()
        // Nothing replaces the window under it afterwards.
        #expect(await stays(for: .milliseconds(500)) { f.rowIDs.first == all[0].id && f.model.scroll.messageID == all[0].id })
    }

    @Test func oneTriggerNearTheTopLoadsOnePageNotTwo() async throws {
        let f = try ConversationFixture()
        try f.addMany(1700)
        await f.start()
        f.model.nearTopChanged(true)
        await eventually("older messages never loaded") { f.model.rows.count == 700 }
        // The list hasn't reported where it is since, so it isn't known to be near the top.
        #expect(await stays(for: .milliseconds(700)) { f.model.rows.count == 700 })
    }

    @Test func aFarJumpOpensAWindowOfAboutTwoHundredAndNewerPagesLoadAtTheEnd() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(1700)
        await f.start()
        f.model.reveal(all[0].id!)
        await eventually("the window never opened") { f.model.isBounded && f.rowIDs.first == all[0].id }
        #expect(f.model.rows.count == 101)
        await eventually("the list was never settled") { f.model.flashID == all[0].id }

        // Scrolled to the end of what's loaded: more is read in from there.
        await eventually("newer pages never reached the newest message") {
            f.model.geometryChanged(geometry(distanceFromBottom: 100))
            f.model.nearEndChanged(true)
            return !f.model.isBounded && f.rowIDs.last == all.last?.id
        }
        #expect(f.rowIDs.first == all[0].id)
        #expect(f.model.rows.count == 1700)
    }
}

/// Holds whoever passes it until it's opened.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrived = false

    var entered: Bool { lock.withLock { arrived } }

    func pass() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            arrived = true
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let all = waiting
        waiting = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}
