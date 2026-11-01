import Foundation
import GRDB
import Testing
import YapnestKit
@testable import Yapnest

/// The model keeps the rows, and what they were built from, across emissions
/// and builds only those whose inputs moved. Whatever the change, the rows
/// must be the ones a build from nothing makes, and the items the ones stored.
@MainActor
struct ConversationIncrementalRowsTests {
    private func open(_ count: Int = 12, direction: Message.Direction = .incoming) async throws -> (ConversationFixture, [Message]) {
        let f = try ConversationFixture()
        let messages = try f.addMany(count, direction, read: true)
        await f.start()
        #expect(f.model.rows.count == count)
        return (f, messages)
    }

    private func expectEqualToFullBuild(_ f: ConversationFixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(f.model.rows.map(\.content) == f.model.contentsBuiltOnMainForTesting(), sourceLocation: sourceLocation)
        let stored = try f.database.reader.read {
            try AppDatabase.conversationItems($0, peer: f.peer, me: f.me, limit: 5000)
        }
        #expect(f.model.rows.map(\.item) == stored, sourceLocation: sourceLocation)
    }

    private func row(_ f: ConversationFixture, _ id: Int64?) throws -> MessageRow {
        try #require(f.model.rows.first { $0.id == id })
    }

    @Test func aNewMessageChangesTheRowBeforeItAndNoOther() async throws {
        let (f, messages) = try await open()
        let others = f.model.rows.dropLast(1).map(\.revision)
        let last = try row(f, messages.last?.id)
        #expect(!last.content.layout.joinsNext)

        let new = try f.add("one more", read: true)
        await eventually("the message never showed") { f.model.rows.count == 13 }
        try expectEqualToFullBuild(f)
        // The old last row now has a message after it to join.
        #expect(try row(f, last.id).content.layout.joinsNext)
        #expect(f.model.rows.last?.id == new.id)
        // Rows before the old last one have the same neighbours as before.
        #expect(f.model.rows.dropLast(2).map(\.revision) == others)
    }

    @Test func anEditAndARetractionChangeTheirRowsOnly() async throws {
        let (f, messages) = try await open()
        let before = f.model.rows.map(\.revision)

        _ = try f.database.applyEdit("fixed", to: messages[5].id!)
        await eventually("the edit never showed") { f.model.rows[5].message.editedAt != nil }
        try expectEqualToFullBuild(f)
        #expect(f.model.rows.map(\.revision).enumerated().filter { $0.element != before[$0.offset] }.map(\.offset) == [5])

        _ = try f.database.applyRetraction(of: messages[8].id!)
        await eventually("the retraction never showed") { f.model.rows[8].message.isRetracted }
        try expectEqualToFullBuild(f)
    }

    @Test func aReactionChangesTheRowBeforeItToo() async throws {
        let f = try ConversationFixture()
        try f.add("a", read: true)
        let reacted = try f.add("b", read: true, remoteId: "b")
        try f.add("c", read: true)
        await f.start()
        let first = f.model.rows[0]
        #expect(first.content.layout.joinsNext)

        _ = try f.database.setReactions(["👍"], from: f.peer, conversationId: f.conversation.id!, messageRef: "b")
        await eventually("the reaction never showed") { !f.model.rows[1].item.reactions.isEmpty }
        try expectEqualToFullBuild(f)
        #expect(f.model.rows[0].content.layout.joinsNext != first.content.layout.joinsNext || f.model.rows[0].revision > first.revision)

        _ = try f.database.setReactions([], from: f.peer, conversationId: f.conversation.id!, messageRef: "b")
        await eventually("the reaction never went") { f.model.rows[1].item.reactions.isEmpty }
        try expectEqualToFullBuild(f)
        #expect(f.model.rows[0].content.layout.joinsNext == first.content.layout.joinsNext)
        _ = reacted
    }

    @Test func aReceiptChangesItsRow() async throws {
        let f = try ConversationFixture()
        try f.add("mine", .outgoing, read: true, status: .sent, remoteId: "r1")
        try f.add("again", .outgoing, read: true, status: .sent, remoteId: "r2")
        await f.start()

        try f.database.updateStatus(.delivered, conversationId: f.conversation.id!, remoteId: "r1")
        await eventually("the receipt never showed") { f.model.rows[0].message.status == .delivered }
        try expectEqualToFullBuild(f)
        #expect(f.model.rows[1].message.status == .sent)
    }

    @Test func aDeletionChangesBothNeighbours() async throws {
        let (f, messages) = try await open()
        _ = try await f.database.writer.write { try Message.deleteOne($0, key: messages[6].id) }
        await eventually("the deletion never showed") { f.model.rows.count == 11 }
        try expectEqualToFullBuild(f)
    }

    @Test func aMessageOnANewDayGetsItsHeaderAndItsNeighbourKeepsItsOwn() async throws {
        let (f, messages) = try await open()
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: messages.last!.timestamp)!
        let new = try f.add("tomorrow", at: next, read: true)
        await eventually("the message never showed") { f.model.rows.count == 13 }
        try expectEqualToFullBuild(f)
        #expect(try row(f, new.id).content.layout.dayHeader != nil)
        #expect(try row(f, messages.last?.id).content.layout.dayHeader == nil)
        #expect(try !row(f, new.id).content.layout.joinsPrevious)
    }

    @Test func aTextRenderedForAnItemThatNeverBecameARowIsDroppedWhenTheWindowChanges() async throws {
        let f = try ConversationFixture()
        let texts = try f.addMany(3)
        for _ in 0..<3 {
            let file = try f.add("", read: true)
            try f.attach("a.png", to: file)
        }
        await f.start()
        #expect(f.model.rows.count == 6)
        let stale: Int64 = 9_999_999
        f.model.cacheTextForTesting(id: stale)
        #expect(f.model.textCacheIDsForTesting.contains(stale))

        _ = try await f.database.writer.write { try Message.deleteOne($0, key: texts[1].id) }
        await eventually("the deletion never showed") { f.model.rows.count == 5 }
        #expect(f.model.textCacheIDsForTesting == Set([texts[0].id!, texts[2].id!]))
    }

    @Test func pagingOlderGivesTheOldFirstRowItsNeighbour() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(700)
        await f.start()
        #expect(f.model.rows.count == 500)
        let oldFirst = try row(f, all[200].id)
        #expect(oldFirst.content.layout.dayHeader != nil)
        #expect(!oldFirst.content.layout.joinsPrevious)

        f.model.nearTopChanged(true)
        await eventually("older messages never loaded") { f.model.rows.count == 700 }
        try expectEqualToFullBuild(f)
        let now = try row(f, all[200].id)
        #expect(now.content.layout.dayHeader == nil)
        #expect(now.content.layout.joinsPrevious)
        #expect(f.model.rows.first?.content.layout.dayHeader != nil)
    }

    @Test func cuttingTheWindowBackGivesTheNewFirstRowItsHeader() async throws {
        let f = try ConversationFixture()
        let all = try f.addMany(1700)
        await f.start()
        await eventually("history never grew to 1700") {
            f.model.nearTopChanged(true)
            return f.model.rows.count == 1700
        }
        let newFirst = try row(f, all[1200].id)
        #expect(newFirst.content.layout.joinsPrevious)

        await eventually("the window was never cut back") {
            f.model.scrollSettled()
            return f.model.rows.count == 500
        }
        #expect(f.model.rows.map(\.content) == f.model.contentsBuiltOnMainForTesting())
        let first = try row(f, all[1200].id)
        #expect(first.content.layout.dayHeader != nil)
        #expect(!first.content.layout.joinsPrevious)
    }

    @Test func aMessageArrivingBesideAnEditLeavesTheRowsAroundThemAlone() async throws {
        let (f, messages) = try await open()
        let before = f.model.rows.map(\.revision)
        let editedID = try #require(messages[3].id)
        _ = try f.database.applyEdit("fixed", to: editedID)
        let newID = try #require(try f.add("both at once", read: true).id)
        await eventually("the message never showed") { f.model.rows.last?.id == newID }
        try expectEqualToFullBuild(f)
        let after = f.model.rows.map(\.revision)
        let changed = Set(after.indices.filter { $0 >= before.count || after[$0] != before[$0] })
        #expect(changed == [3, 11, 12])
    }

    @Test func aNewMessageWhileTheDividerShowsKeepsTheDividerAndTheRowsAboveIt() async throws {
        let f = try ConversationFixture()
        try f.addMany(5, read: true)
        let first = try f.add("unread")
        try f.add("unread 2")
        await f.start()
        let before = f.model.rows.map(\.revision)
        let arrived = try f.add("arrived later")
        await eventually("the message never showed") { f.model.rows.last?.id == arrived.id }
        try expectEqualToFullBuild(f)
        #expect(f.model.rows.filter(\.content.layout.showsUnreadDivider).map(\.id) == [first.id])
        #expect(Array(f.model.rows.map(\.revision).prefix(6)) == Array(before.prefix(6)))
    }

    @Test func aBodyOpenedInFullStaysOpenWhenAMessageArrives() async throws {
        let f = try ConversationFixture()
        let long = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let stored = try f.add(long, read: true).id!
        try f.add("short", read: true)
        await f.start()
        f.model.showWholeBody(of: stored)
        let arrived = try f.add("later", read: true)
        await eventually("the message never showed") { f.model.rows.last?.id == arrived.id }
        try expectEqualToFullBuild(f)
        #expect(try row(f, stored).content.text?.isCollapsed == false)
    }

    @Test func aChangeOfDayRebuildsEveryRowAndTheNextMessageStillBuildsRight() async throws {
        let (f, _) = try await open()
        let before = f.model.rows.map(\.revision)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        let arrived = try f.add("after midnight", read: true)
        await eventually("the message never showed") { f.model.rows.last?.id == arrived.id }
        try expectEqualToFullBuild(f)
        // Rows of the day before keep their content, so a rebuild finds them equal.
        #expect(Array(f.model.rows.map(\.revision).prefix(before.count - 1)) == Array(before.dropLast()))
    }

    @Test func aMessageDeletedAtTheEndAndOneAddedAfterItBuildRight() async throws {
        let (f, messages) = try await open()
        _ = try await f.database.writer.write { try Message.deleteOne($0, key: messages.last?.id) }
        await eventually("the deletion never showed") { f.model.rows.count == 11 }
        try expectEqualToFullBuild(f)
        #expect(try !row(f, messages[10].id).content.layout.joinsNext)
        let arrived = try f.add("again", read: true)
        await eventually("the message never showed") { f.model.rows.last?.id == arrived.id }
        try expectEqualToFullBuild(f)
    }
}
