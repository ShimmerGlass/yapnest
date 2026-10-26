import Testing
import YapnestKit
@testable import Yapnest

/// When messages count as read.
@MainActor
struct ConversationReadTests {
    private func unread(_ f: ConversationFixture) throws -> Int {
        try f.database.unreadMessageCount(peer: f.peer)
    }

    private func openedWithUnread(_ count: Int = 5) async throws -> (ConversationFixture, [Message]) {
        let f = try ConversationFixture()
        try f.addMany(4)
        let messages = try (0..<count).map { try f.add("new \($0)") }
        await f.start(waitingForPosition: true)
        f.model.setOnScreen(true)
        return (f, messages)
    }

    @Test func readsThroughTheNewestVisibleMessageAndLeavesTheOnesBelow() async throws {
        let (f, messages) = try await openedWithUnread()
        f.model.visibleChanged([messages[0].id!, messages[1].id!])
        await eventually("the visible messages were never read") { (try? unread(f)) == 3 }
        #expect(await stays { (try? unread(f)) == 3 })

        f.model.visibleChanged(messages.map { $0.id! })
        await eventually("the rest was never read") { (try? unread(f)) == 0 }
        await eventually("the count never dropped") { f.model.unreadCount == 0 }
    }

    @Test func nothingIsReadWhileTheChatIsNotInFront() async throws {
        let (f, messages) = try await openedWithUnread()
        f.model.setOnScreen(false)
        f.model.visibleChanged(messages.map { $0.id! })
        #expect(await stays { (try? unread(f)) == 5 })
    }

    @Test func nothingIsReadWhileTheWindowIsOutOfSightAndTheRestOnceItShows() async throws {
        let (f, messages) = try await openedWithUnread()
        // The Mac with its screen locked: the app is still active.
        f.model.windowVisibilityChanged(false)
        f.model.visibleChanged(messages.map { $0.id! })
        #expect(await stays { (try? unread(f)) == 5 })

        f.model.windowVisibilityChanged(true)
        await eventually("nothing was read once the window showed") { (try? unread(f)) == 0 }
    }

    @Test func nothingIsReadWhileTheListIsStillBeingTakenToTheFirstUnread() async throws {
        let f = try ConversationFixture()
        try f.addMany(4)
        let messages = try (0..<5).map { try f.add("new \($0)") }
        await f.start()
        f.model.setOnScreen(true)
        #expect(!f.model.isPositioned)

        // What it reports while hidden is its default place, not what the user will see.
        f.model.visibleChanged([messages[4].id!])
        #expect(try unread(f) == 5)
        #expect(await stays(for: .milliseconds(300)) { !f.model.isPositioned && (try? unread(f)) == 5 })

        await eventually("the visible message was never read once shown") { (try? unread(f)) == 0 }
    }

    @Test func ourOwnMessagesAndAlreadyReadOnesAskForNothing() async throws {
        let (f, messages) = try await openedWithUnread(2)
        let mine = try f.add("mine", .outgoing)
        await eventually("the message never showed") { f.rowIDs.last == mine.id }
        f.model.visibleChanged([mine.id!, f.rowIDs[0]])
        #expect(await stays { (try? unread(f)) == messages.count })
    }

    @Test func aMessageOlderThanWhatWasReadIsStillMarkedReadWhenSeen() async throws {
        let (f, messages) = try await openedWithUnread(2)
        f.model.visibleChanged([messages[1].id!])
        await eventually("nothing was read") { (try? unread(f)) == 0 }

        // Late from the archive, older than what was read, but unread.
        let late = try f.add("late arrival", at: messages[0].timestamp.addingTimeInterval(1))
        await eventually("the late message never showed") { f.rowIDs.contains(late.id!) }
        #expect(try unread(f) == 1)
        f.model.visibleChanged([late.id!])
        await eventually("the late message was never read") { (try? unread(f)) == 0 }
    }

    @Test func aMessageArrivingPastABoundedWindowIsCountedAsUnread() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(1700)
        await f.start()
        f.model.reveal(all[0].id!)
        await eventually("the bounded window never opened") { f.model.isBounded && f.rowIDs.first == all[0].id }
        #expect(f.model.unreadCount == 0)

        let arrived = try f.add("arrived")
        #expect(await stays(for: .milliseconds(100)) { !f.rowIDs.contains(arrived.id!) })
        await eventually("the count never took the message past the window") { f.model.unreadCount == 1 }
    }
}
