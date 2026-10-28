import Foundation
import GRDB
import Testing
import YapnestKit
@testable import Yapnest

/// The lines that say who joined and left a group: words, VoiceOver, and
/// that they are lines of the history rather than messages.
@MainActor
struct GroupEventRowTests {
    @Test func theWordsNameWhoJoinedAndWhoLeft() {
        #expect(MessageEvent.joinedGroup.words(of: "Bob") == "Bob joined the group")
        #expect(MessageEvent.leftGroup.words(of: "Bob") == "Bob left the group")
    }

    @Test func aGroupsLinesCarryTheNicknameAndTheTimeForVoiceOver() async throws {
        let f = try ConversationFixture(kind: .groupchat)
        try f.makeGroup()
        let bob = JID("bob@example.com")!
        for (index, event) in [MessageEvent.joinedGroup, .leftGroup].enumerated() {
            var line = Message(
                conversationId: f.conversation.id!, direction: .event, sender: bob, nick: "Bobby", body: "",
                timestamp: Calendar.current.date(bySettingHour: 12 + index, month: 3, day: 5, year: 2024), status: .received, isRead: true,
            )
            line.event = event
            _ = try f.database.insert(line)
        }
        await f.start()

        let rows = f.model.rows
        #expect(rows.count == 2)
        guard case .event(.joinedGroup, let first) = rows[0].content.kind, case .event(.leftGroup, let second) = rows[1].content.kind else {
            Issue.record("the rows are not event rows")
            return
        }
        #expect(first == "Bobby (bob@example.com)" && second == "Bobby (bob@example.com)")
        #expect(rows[0].content.accessibilityLabel.hasPrefix("Bobby (bob@example.com) joined the group, "))
        #expect(rows[1].content.accessibilityLabel.hasPrefix("Bobby (bob@example.com) left the group, "))
    }

    @Test func aLineForSomeoneKnownOnlyByNicknameNamesThemByIt() async throws {
        let f = try ConversationFixture(kind: .groupchat)
        try f.makeGroup()
        var line = Message(
            conversationId: f.conversation.id!, direction: .event, sender: f.peer, nick: "Bobby", body: "",
            timestamp: Calendar.current.date(bySettingHour: 12, month: 3, day: 5, year: 2024), status: .received, isRead: true,
        )
        line.event = .joinedGroup
        _ = try f.database.insert(line)
        await f.start()

        guard case .event(_, let name) = f.model.rows[0].content.kind else {
            Issue.record("not an event row")
            return
        }
        #expect(name == "Bobby")
    }
}
