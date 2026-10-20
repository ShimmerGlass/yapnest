import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// The rows the conversation draws: where days change, which bubbles join,
/// where the unread divider sits, and how corrections and deletions show.
@MainActor
struct ConversationRowsTests {
    private func text(_ row: MessageRow) -> String {
        row.content.text?.segments.map { String($0.text.characters) }.joined(separator: "\n") ?? ""
    }

    @Test func aLongMessageIsCutShortUntilItsReaderOpensIt() async throws {
        let f = try ConversationFixture()
        let long = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let stored = try f.add(long, read: true).id!
        let short = try f.add("short", read: true).id!
        await f.start()

        func row(_ id: Int64) -> MessageRow { f.model.rows.first { $0.id == id }! }
        #expect(row(stored).content.text?.isCollapsed == true)
        #expect(!text(row(stored)).contains("line 60"))
        #expect(row(short).content.text?.isCollapsed == false)

        let revision = row(short).revision
        f.model.showWholeBody(of: stored)
        #expect(row(stored).content.text?.isCollapsed == false)
        #expect(text(row(stored)).contains("line 60"))
        // The other rows are not built again.
        #expect(row(short).revision == revision)
    }

    @Test func dayHeadersAndJoinedBubblesFollowTimeDirectionAndDay() async throws {
        let f = try ConversationFixture()
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 10, month: 3, day: 5, year: 2024)
        let beforeMidnight = cal.date(bySettingHour: 23, month: 3, day: 5, year: 2024).addingTimeInterval(59 * 60 + 30)
        try f.add("a", at: morning, read: true)
        try f.add("b", at: morning.addingTimeInterval(30), read: true)
        try f.add("c", at: morning.addingTimeInterval(600), read: true)
        try f.add("d", .outgoing, at: morning.addingTimeInterval(630))
        try f.add("late", at: beforeMidnight, read: true)
        // Ten seconds after the last, but on the next day.
        try f.add("early", at: beforeMidnight.addingTimeInterval(40), read: true)
        await f.start()

        let layouts = f.model.rows.map(\.content.layout)
        #expect(layouts.map { $0.dayHeader != nil } == [true, false, false, false, false, true])
        // "b" follows "a" within two minutes. "c" is too late, "d" is ours, and
        // "early" is on another day.
        #expect(layouts.map(\.joinsPrevious) == [false, true, false, false, false, false])
        #expect(layouts.map(\.joinsNext) == [true, false, false, false, false, false])
    }

    @Test func theUnreadDividerSitsAboveTheFirstUnreadAndStaysWhenTheyAreRead() async throws {
        let f = try ConversationFixture()
        try f.addMany(6, read: true)
        let unread = [try f.add("new 1"), try f.add("new 2"), try f.add("new 3")]
        await f.start()

        #expect(f.model.unreadDividerId == unread[0].id)
        #expect(f.model.unreadCount == 3)
        #expect(f.model.rows.filter(\.content.layout.showsUnreadDivider).map(\.id) == [unread[0].id])

        try f.database.markRead(conversationId: f.conversation.id!)
        await eventually("the count never dropped") { f.model.unreadCount == 0 }
        #expect(f.model.unreadDividerId == unread[0].id)
        #expect(f.model.rows.filter(\.content.layout.showsUnreadDivider).map(\.id) == [unread[0].id])
    }

    @Test func aMessageThatArrivesWhileOpenDoesNotMoveTheDivider() async throws {
        let f = try ConversationFixture()
        try f.addMany(3, read: true)
        let first = try f.add("unread")
        await f.start()
        let arrived = try f.add("arrived later")
        await eventually("the new message never showed") { f.model.rows.last?.id == arrived.id }
        #expect(f.model.unreadDividerId == first.id)
        #expect(f.model.unreadCount == 2)
    }

    @Test func withNothingUnreadThereIsNoDivider() async throws {
        let f = try ConversationFixture()
        try f.addMany(4, read: true)
        try f.add("mine", .outgoing)
        await f.start()
        #expect(f.model.unreadDividerId == nil)
        #expect(f.model.rows.allSatisfy { !$0.content.layout.showsUnreadDivider })
    }

    @Test func aCorrectionReplacesTheTextInPlaceAndMarksItEdited() async throws {
        let f = try ConversationFixture()
        let sent = try f.add("origial", .outgoing)
        try f.add("reply", read: true)
        await f.start()
        #expect(f.model.rows.first.map(text) == "origial")
        let before = f.model.rows[0].revision

        _ = try f.database.applyEdit("original", to: sent.id!)
        await eventually("the correction never showed") { f.model.rows.first.map(text) == "original" }
        #expect(f.model.rows.count == 2)
        #expect(f.model.rows[0].message.editedAt != nil)
        #expect(f.model.rows[0].revision > before)
        #expect(f.model.rows[0].content.accessibilityLabel.contains(String(localized: "Edited")))
    }

    @Test func aDeletedMessageShowsNoTraceOfItsText() async throws {
        let f = try ConversationFixture()
        let theirs = try f.add("secret words", read: true)
        let mine = try f.add("my secret words", .outgoing)
        await f.start()

        _ = try f.database.applyRetraction(of: theirs.id!)
        _ = try f.database.applyRetraction(of: mine.id!)
        await eventually("the deletions never showed") { f.model.rows.allSatisfy { $0.message.isRetracted } }

        let shown = f.model.rows.map(text)
        #expect(shown.allSatisfy { !$0.contains("secret") && !$0.isEmpty })
        // Who deleted it is said differently.
        #expect(shown[0] != shown[1])
        #expect(f.model.rows.count == 2)
    }
}

/// Which messages are drawn as emoji alone, without a bubble.
struct BareEmojiTests {
    private func bare(
        _ body: String = "🥚", retracted: Bool = false, action: Bool = false, undecryptable: Bool = false,
        quote: Bool = false, attachment: Bool = false, location: Bool = false, preview: PreviewDisplay = .none,
    ) -> Bool {
        MessageRow.drawsWithoutBubble(
            isEmojiOnly: MessageText.render(body, kind: .normal).isEmojiOnly, isRetracted: retracted, isAction: action, isUndecryptable: undecryptable,
            hasQuote: quote, hasAttachment: attachment, hasLocation: location, preview: preview,
        )
    }

    @Test func plainEmojiAreDrawnWithoutABubble() {
        #expect(bare())
        #expect(bare("🥚🐣🪺"))
        #expect(bare("🥚🐣🪺🐦🌿🍃"))
        #expect(bare("\n🥚\n"))
    }

    @Test func anythingElseKeepsTheBubble() {
        #expect(!bare(quote: true))
        #expect(!bare(attachment: true))
        #expect(!bare(location: true))
        #expect(!bare(preview: .ask))
        #expect(!bare(retracted: true))
        #expect(!bare(action: true))
        #expect(!bare(undecryptable: true))
        #expect(!bare("🥚🐣🪺🐦🌿🍃🌸"))
        #expect(!bare("🥚 ok"))
        #expect(!bare("ok"))
        #expect(!bare(""))
    }

    @MainActor
    @Test func theRowCarriesTheDecision() async throws {
        let f = try ConversationFixture()
        let emoji = try f.add("🥚", read: true).id!
        let words = try f.add("hello", read: true).id!
        await f.start()
        #expect(f.model.rows.first { $0.id == emoji }!.content.isBare)
        #expect(!f.model.rows.first { $0.id == words }!.content.isBare)
    }
}
