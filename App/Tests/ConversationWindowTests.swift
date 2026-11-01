import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

/// Paging back through history, and the bounded window a far jump opens.
@MainActor
struct ConversationWindowTests {
    @Test func scrollingToTheTopWidensTheWindowByWhatIsStored() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(700)
        await f.start()
        #expect(f.model.rows.count == 500)

        f.model.nearTopChanged(true)
        await eventually("older messages never loaded") { f.model.rows.count == 700 }
        #expect(f.rowIDs == all.map { $0.id! })
    }

    @Test func drawingARowNearTheWindowsOldestFetchesTheNextPageBeforeTheListLooksNearTheTop() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(700)
        await f.start()
        #expect(f.model.rows.count == 500)

        // Rows far from the oldest wait for the list to say it is near the top.
        f.model.rowBuiltChanged(f.rowIDs[300], true)
        #expect(await stays { f.model.rows.count == 500 })

        f.model.rowBuiltChanged(f.rowIDs[20], true)
        await eventually("the page before the window's end never loaded") { f.model.rows.count == 700 }
        #expect(f.rowIDs == all.map { $0.id! })
    }

    @Test func atTheTopOfACompleteArchiveTheListSaysThereIsNothingOlder() async throws {
        let f = try ConversationFixture()
        try f.addMany(20)
        try f.database.setHistoryState(peer: f.peer, isComplete: true, cursor: nil)
        await f.start()
        f.model.nearTopChanged(true)
        await eventually("the end of history was never reached") { f.model.olderState == .complete }
    }

    @Test func atTheTopWhileOfflineItNeitherFailsNorGivesUp() async throws {
        let f = try ConversationFixture()
        try f.addMany(20)
        await f.start()
        f.model.nearTopChanged(true)
        // The server can't be asked; the connection coming back asks again.
        #expect(await stays { f.model.olderState == .idle })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    @Test func aRefusedOlderPageSaysWhyTheServerRefused() async throws {
        let f = try ConversationFixture()
        try f.addMany(20)
        f.model.loadOlderPage = { _, _ in throw ServerError(condition: "forbidden", type: .auth, text: "Not allowed here") }
        await f.start()

        f.model.nearTopChanged(true)

        await eventually("the failure was never reported") { f.model.olderState == .failed }
        #expect(f.model.olderFailure?.contains("Not allowed here") == true)
    }

    @Test func aTimeoutOnAnOlderPageIsAskedAgainWithoutWaitingForRetry() async throws {
        let f = try ConversationFixture()
        try f.addMany(20)
        let calls = Counter()
        f.model.olderRetryBackoff = .milliseconds(10)
        f.model.loadOlderPage = { _, _ in
            if calls.next() == 1 { throw ServerError(condition: "remote-server-timeout") }
            throw ServerError(condition: "forbidden", type: .auth)
        }
        await f.start()

        f.model.nearTopChanged(true)

        await eventually("the second request never came") { f.model.olderState == .failed }
        #expect(calls.count == 2, "the timeout waited for a tap on Retry")
    }

    @Test func aFailureOfAnArchiveRequestThatAJumpLeftBehindDoesNotMarkTheNewWindow() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(20)
        let gate = Gate()
        f.model.loadOlderPage = { _, _ in
            await gate.pass()
            throw ServerError(condition: "forbidden", type: .auth, text: "Late refusal")
        }
        await f.start()
        f.model.nearTopChanged(true)
        await eventually("the request never started") { gate.entered }

        f.model.reveal(all[10].id!)
        gate.open()

        #expect(await stays(for: .milliseconds(500)) { f.model.olderState != .failed })
    }

    @Test(arguments: [false, true]) func aFarJumpOpensABoundedWindowAndTheButtonBringsTheNewestBack(flipped: Bool) async throws {
        let f = try ConversationFixture(isFlipped: flipped)
        let all = try f.addMany(1700)
        await f.start()
        #expect(!f.model.isBounded)

        let oldest = all[0]
        f.model.reveal(oldest.id!)
        await eventually("the bounded window never opened") { f.model.isBounded && f.rowIDs.first == oldest.id }
        // Not a thousand-odd messages through to the newest.
        #expect(f.model.rows.count < 300)
        #expect(f.model.scroll.messageID == oldest.id)
        await eventually("the target was never flashed") { f.model.flashID == oldest.id }

        // A new message is past the window's end, so the rows don't take it.
        let arrived = try f.add("arrived", read: true)
        #expect(await stays { !f.rowIDs.contains(arrived.id!) })

        f.model.scrollToLatest()
        await eventually("the newest messages never came back") { !f.model.isBounded && f.rowIDs.last == arrived.id }
        #expect(f.model.rows.count == 500)
        #expect(flipped ? f.model.scroll.edge == .top : f.model.scroll.messageID == arrived.id)
    }

    @Test func aLongWindowIsCutBackToTheNewestWhenTheUserIsBackAtTheBottom() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(1700)
        await f.start()

        await eventually("history never grew to 1700") {
            f.model.nearTopChanged(true)
            return f.model.rows.count == 1700
        }
        #expect(f.rowIDs.first == all[0].id)

        await eventually("the window was never cut back") {
            f.model.scrollSettled()
            return f.model.rows.count == 500
        }
        #expect(f.rowIDs.last == all.last?.id)
        #expect(f.rowIDs.first == all[1200].id)
    }

    @Test func aWindowIsNotCutBackWhileTheUserIsReadingUpTheList() async throws {
        let f = try ConversationFixture()
        try f.addMany(1700)
        await f.start()
        await eventually("history never grew to 1700") {
            f.model.nearTopChanged(true)
            return f.model.rows.count == 1700
        }
        f.model.geometryChanged(geometry(distanceFromBottom: 5_000))
        f.model.scrollSettled()
        #expect(await stays { f.model.rows.count == 1700 })
    }
}
