import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

/// Where the list lands when a chat opens.
@MainActor
struct ConversationOpeningTests {
    @Test func opensAtTheFirstUnreadWhenItIsFarFromTheEndAndHidesTheListMeanwhile() async throws {
        let f = try ConversationFixture()
        try f.addMany(10, read: true)
        let unread = try (0..<6).map { try f.add("new \($0)") }
        await f.start()

        // The rows above aren't measured yet, so the list isn't shown.
        #expect(!f.model.isPositioned)
        await eventually("the list was never shown") { f.model.isPositioned }
        #expect(f.model.scroll.messageID == unread[0].id)
        #expect(f.model.unreadDividerId == unread[0].id)
    }

    @Test(arguments: [false, true]) func opensAtTheBottomWhenTheDividerIsAmongTheLastFewMessages(flipped: Bool) async throws {
        let f = try ConversationFixture(isFlipped: flipped)
        try f.addMany(10, read: true)
        try f.add("new 1")
        try f.add("new 2")
        await f.start()
        #expect(f.model.isPositioned)
        #expect(f.model.scroll.edge == (flipped ? .top : .bottom))
        #expect(f.model.scroll.messageID == nil)
    }

    @Test(arguments: [false, true]) func opensAtTheBottomWithNothingUnread(flipped: Bool) async throws {
        let f = try ConversationFixture(isFlipped: flipped)
        try f.addMany(10, read: true)
        await f.start()
        #expect(f.model.isPositioned)
        #expect(f.model.scroll.edge == (flipped ? .top : .bottom))
    }

    @Test func opensAtTheFirstUnreadEvenWhenItIsOlderThanTheUsualWindow() async throws {
        let f = try ConversationFixture()
        try f.addMany(10, read: true)
        let unread = try f.addMany(600, read: false)
        await f.start()
        // 600 unread is more than the newest 500, which would leave the first
        // one out; the window reaches back for it.
        #expect(f.rowIDs.contains(unread[0].id!))
        #expect(f.model.unreadDividerId == unread[0].id)
        await eventually("the list was never shown") { f.model.isPositioned }
        #expect(f.model.scroll.messageID == unread[0].id)
    }

    @Test func aJumpTargetBeatsTheUnreadMessageAndIsFlashed() async throws {
        let f = try ConversationFixture()
        let old = try f.addMany(700, read: true)
        try f.add("unread")
        try f.add("unread 2")
        try f.add("unread 3")
        try f.add("unread 4")
        let target = old[5]
        f.reopen(openingAt: target.id)
        await f.start()

        #expect(f.rowIDs.contains(target.id!))
        await eventually("the list never landed on the target") { f.model.isPositioned && f.model.scroll.messageID == target.id }
        await eventually("the target was never flashed") { f.model.flashID == target.id }
        await eventually("the flash never ended") { f.model.flashID == nil }
    }

    @Test(arguments: [false, true]) func aJumpTargetThatNoLongerExistsFallsBackToTheNormalOpening(flipped: Bool) async throws {
        let f = try ConversationFixture(isFlipped: flipped)
        try f.addMany(10, read: true)
        f.reopen(openingAt: 999_999)
        await f.start()
        #expect(f.model.isPositioned)
        #expect(f.model.scroll.edge == (flipped ? .top : .bottom))
        #expect(f.model.flashID == nil)
        #expect(f.model.rows.count == 10)
    }
}
