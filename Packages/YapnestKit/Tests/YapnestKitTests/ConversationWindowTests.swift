import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct ConversationWindowTests {
    let db: AppDatabase
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    /// `count` messages one second apart, replying to the one before every
    /// tenth, with a reaction on every fifth.
    private func fill(_ count: Int) throws {
        let conversation = try db.conversation(with: alice)
        let id = conversation.id!
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try db.writer.write { db in
            for index in 0..<count {
                var message = Message(
                    conversationId: id, direction: index % 3 == 0 ? .outgoing : .incoming, sender: index % 3 == 0 ? me : alice,
                    body: "message \(index)", timestamp: t0 + Double(index), remoteId: "m\(index)",
                    replyToId: index % 10 == 9 ? "m\(index - 1)" : nil,
                )
                try message.insert(db)
                if index % 5 == 0 { try Reaction(messageId: message.id!, sender: alice, emoji: "👍").insert(db) }
            }
        }
    }

    @Test func defaultWindowIsTheNewestMessages() throws {
        try fill(600)
        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items.count == AppDatabase.initialWindow)
        #expect(items.first?.message.body == "message 100")
        #expect(items.last?.message.body == "message 599")
    }

    @Test func sinceStartsTheWindowAtTheCursorAndKeepsGrowing() throws {
        try fill(50)
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 1000) }
        let cursor = all[20].cursor
        var items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 5, since: cursor) }
        // The cursor wins over the limit, and includes its own message.
        #expect(items.count == 30)
        #expect(items.first?.message.body == "message 20")

        try db.insert(Message(conversationId: all[0].message.conversationId, direction: .incoming, sender: alice, body: "new", timestamp: Date(timeIntervalSince1970: 2_000_000), remoteId: "new"))
        items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: cursor) }
        #expect(items.count == 31)
        #expect(items.first?.message.body == "message 20")
    }

    @Test func cursorOrdersMessagesWithTheSameTimeById() throws {
        let id = try db.conversation(with: alice).id!
        let t = Date(timeIntervalSince1970: 5_000)
        for index in 0..<4 {
            try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "same \(index)", timestamp: t, remoteId: "s\(index)"))
        }
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(all.map(\.message.body) == ["same 0", "same 1", "same 2", "same 3"])
        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: all[2].cursor) }
        #expect(items.map(\.message.body) == ["same 2", "same 3"])
        let older = try db.olderCursor(peer: alice, before: all[2].cursor, count: 1)
        #expect(older?.cursor == all[1].cursor)
    }

    @Test func olderCursorReportsHowFarBackThereIs() throws {
        try fill(10)
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        let found = try #require(try db.olderCursor(peer: alice, before: all[7].cursor, count: 50))
        #expect(found.found == 7)
        #expect(found.cursor == all[0].cursor)
        let some = try #require(try db.olderCursor(peer: alice, before: all[7].cursor, count: 3))
        #expect(some.found == 3)
        #expect(some.cursor == all[4].cursor)
        #expect(try db.olderCursor(peer: alice, before: all[0].cursor, count: 50) == nil)
    }

    @Test func windowStartIncludesTheMessageWithMargin() throws {
        try fill(100)
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 1000) }
        let start = try #require(try db.windowStart(peer: alice, including: all[40].id, margin: 10))
        #expect(start == all[30].cursor)
        // Near the very start there's less margin to give.
        #expect(try db.windowStart(peer: alice, including: all[3].id, margin: 10) == all[0].cursor)
        #expect(try db.windowStart(peer: JID("bob@example.org")!, including: all[3].id) == nil)
    }

    @Test func openingWindowReachesTheFirstUnreadMessage() throws {
        try fill(1200)
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 2000) }
        let conversationId = all[0].message.conversationId
        try db.markRead(conversationId: conversationId)

        // Nothing unread: nothing to reach.
        var opening = try db.openingWindow(peer: alice)
        #expect(opening.firstUnread == nil && opening.start == nil)

        // Unread within the newest 500: the default window already has it.
        try db.writer.write { db in
            _ = try Message.filter(Column("id") == all[1000].id).updateAll(db, Column("isRead").set(to: false))
        }
        opening = try db.openingWindow(peer: alice)
        #expect(opening.firstUnread == all[1000].id && opening.start == nil)

        // Unread further back: the window starts a little above it.
        let unread = all[100...].first { $0.message.direction == .incoming }!
        try db.writer.write { db in
            _ = try Message.filter(Column("id") == unread.id).updateAll(db, Column("isRead").set(to: false))
        }
        opening = try db.openingWindow(peer: alice)
        #expect(opening.firstUnread == unread.id)
        let start = try #require(opening.start)
        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: start) }
        #expect(items.contains { $0.id == unread.id })
        #expect(items.count > AppDatabase.initialWindow)

        // Too far back to reach: the window stops at the limit.
        let capped = try db.openingWindow(peer: alice, limit: 600)
        #expect(capped.firstUnread == unread.id)
        let cappedItems = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: try #require(capped.start)) }
        #expect(cappedItems.count == 600)
    }

    @Test func referencedMessageFindsByAnyId() throws {
        try fill(5)
        #expect(try db.referencedMessage(peer: alice, id: "m3")?.body == "message 3")
        #expect(try db.referencedMessage(peer: alice, id: "nope") == nil)
    }

    @Test func untilEndsTheWindowAtTheCursor() throws {
        try fill(50)
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 1000) }
        // Bounded on both sides, both ends included.
        var items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: all[10].cursor, until: all[20].cursor) }
        #expect(items.map(\.id) == all[10...20].map(\.id))
        // Without a start the limit keeps the newest messages up to the end.
        items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 5, until: all[20].cursor) }
        #expect(items.map(\.id) == all[16...20].map(\.id))
    }

    @Test func observationRespectsUntil() async throws {
        try fill(30)
        let all = try allItems()
        var iterator = db.observeConversation(peer: alice, me: me, since: all[5].cursor, until: all[15].cursor)
            .values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.map(\.id) == all[5...15].map(\.id))
        // A message past the end is not shown; a change inside it is.
        try db.insert(Message(conversationId: all[0].message.conversationId, direction: .incoming, sender: alice, body: "new", timestamp: Date(timeIntervalSince1970: 2_000_000), remoteId: "new"))
        try db.setReactions(["🎉"], from: alice, conversationId: all[0].message.conversationId, messageRef: "m10")
        let second = try #require(try await iterator.next())
        #expect(second.map(\.id) == all[5...15].map(\.id))
        #expect(second.first { $0.message.remoteId == "m10" }?.reactions.map(\.emoji) == ["🎉"])
    }

    @Test func newerCursorReportsHowFarOnThereIs() throws {
        try fill(10)
        let all = try allItems()
        let found = try #require(try db.newerCursor(peer: alice, after: all[2].cursor, count: 50))
        #expect(found.found == 7)
        #expect(found.cursor == all[9].cursor)
        let some = try #require(try db.newerCursor(peer: alice, after: all[2].cursor, count: 3))
        #expect(some.found == 3)
        #expect(some.cursor == all[5].cursor)
        #expect(try db.newerCursor(peer: alice, after: all[9].cursor, count: 50) == nil)
    }

    @Test func windowAroundRunsToTheNewestWhenTheTargetIsNear() throws {
        try fill(100)
        let all = try allItems()
        let window = try #require(try db.window(peer: alice, around: all[60].id, boundedBeyond: 50, margin: 10))
        #expect(window.start == all[50].cursor)
        #expect(window.end == nil)
    }

    @Test func windowAroundIsBoundedWhenTheTargetIsFar() throws {
        try fill(300)
        let all = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 1000) }
        let window = try #require(try db.window(peer: alice, around: all[50].id, boundedBeyond: 100, boundedMargin: 20))
        #expect(window.start == all[30].cursor)
        #expect(window.end == all[70].cursor)
        // Near the very start there's less margin to give.
        let first = try #require(try db.window(peer: alice, around: all[5].id, boundedBeyond: 100, boundedMargin: 20))
        #expect(first.start == all[0].cursor)
        #expect(first.end == all[25].cursor)
        #expect(try db.window(peer: JID("bob@example.org")!, around: all[5].id, boundedBeyond: 100) == nil)
    }

    @Test func unreadMessageCountIgnoresTheWindow() throws {
        try fill(30)
        // Two in three are incoming, all unread.
        #expect(try db.unreadMessageCount(peer: alice) == 20)
        #expect(try db.unreadMessageCount(peer: JID("bob@example.org")!) == 0)
    }

    private func allItems() throws -> [ConversationItem] {
        try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
    }

    @Test func observationFollowsChangesInsideTheWindow() async throws {
        try fill(20)
        let all = try allItems()
        var iterator = db.observeConversation(peer: alice, me: me, since: all[10].cursor)
            .values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.count == 10)
        try db.setReactions(["🎉"], from: alice, conversationId: all[0].message.conversationId, messageRef: "m15")
        let second = try #require(try await iterator.next())
        #expect(second.first { $0.message.remoteId == "m15" }?.reactions.map(\.emoji) == ["🎉"])
    }

    /// What a full fetch of the window costs, joins included. An observation
    /// rebuilds only the messages that changed (`ConversationItemCache`), so this is
    /// the worst case.
    @Test func fetchingTwoThousandItemsIsCheap() throws {
        try fill(2000)
        let clock = ContinuousClock()
        var items: [ConversationItem] = []
        let elapsed = try clock.measure {
            items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: 2000) }
        }
        let small = try clock.measure {
            _ = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        }
        print("PERF fetch of 2000 items: \(elapsed), of 500: \(small)")
        #expect(items.count == 2000)
        #expect(elapsed < .seconds(2))
    }
}
