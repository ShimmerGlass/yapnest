import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct NotificationIntervalTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let room = JID("cake@conference.example.org")!
    let other = JID("tea@conference.example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func group(_ jid: JID, interval: Int? = 15, notify: GroupChat.Notify = .always) throws -> Conversation {
        let created = try db.joinGroupChat(jid, nickname: "Me", name: jid.shortName)
        let chat = try #require(try db.conversation(id: created.conversationId))
        try db.updateGroupChat(jid) { $0.notify = notify }
        try db.setNotificationInterval(interval, peer: jid)
        return chat
    }

    @discardableResult
    private func incoming(_ body: String, in chat: Conversation, mentionsMe: Bool = false, at date: Date = Date()) throws -> Message {
        var message = Message(conversationId: chat.id!, direction: .incoming, sender: chat.peer, nick: "ally", body: body,
                              remoteId: UUID().uuidString)
        message.timestamp = date
        message.mentionsMe = mentionsMe
        return try db.insert(message)
    }

    private func quiet(_ notifications: [MessageNotification]) -> [Bool] { notifications.map(\.isQuiet) }

    private func lastLoud(_ chat: Conversation) throws -> Date? {
        try db.reader.read { try Conversation.fetchOne($0, key: chat.id!)?.lastLoudNotificationAt }
    }

    @Test func aMessageWithinTheIntervalIsQuietAndOneAfterItIsLoud() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        try incoming("one", in: chat)
        #expect(try quiet(db.claimNotifications(now: start)) == [false])
        try incoming("two", in: chat)
        #expect(try quiet(db.claimNotifications(now: start.addingTimeInterval(14 * 60))) == [true])
        try incoming("three", in: chat, at: start.addingTimeInterval(15 * 60))
        #expect(try quiet(db.claimNotifications(now: start.addingTimeInterval(15 * 60))) == [false])
    }

    @Test func aQuietMessageDoesNotMoveTheIntervalOn() throws {
        let chat = try group(room, interval: 5)
        _ = try db.claimNotifications()
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        try incoming("one", in: chat)
        _ = try db.claimNotifications(now: start)
        try incoming("two", in: chat)
        #expect(try quiet(db.claimNotifications(now: start.addingTimeInterval(4 * 60))) == [true])
        #expect(try lastLoud(chat) == start)
        try incoming("three", in: chat, at: start.addingTimeInterval(5 * 60))
        #expect(try quiet(db.claimNotifications(now: start.addingTimeInterval(5 * 60))) == [false])
    }

    @Test func aMentionInsideTheIntervalIsLoudAndStartsItAgain() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        try incoming("one", in: chat)
        _ = try db.claimNotifications(now: start)
        try incoming("hi", in: chat, mentionsMe: true)
        try incoming("Me, are you there?", in: chat)
        try incoming("nothing", in: chat)
        let later = start.addingTimeInterval(60)
        #expect(try quiet(db.claimNotifications(now: later)) == [false, false, true])
        #expect(try lastLoud(chat) == later)
    }

    @Test func onlyTheFirstOfABatchIsLoud() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        for body in ["one", "two", "three"] { try incoming(body, in: chat) }
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["one", "two", "three"])
        #expect(quiet(claimed) == [false, true, true])
    }

    @Test func withoutAnIntervalNothingIsThrottled() throws {
        let chat = try group(room, interval: nil)
        _ = try db.claimNotifications()
        try incoming("one", in: chat)
        try incoming("two", in: chat)
        #expect(try quiet(db.claimNotifications()) == [false, false])
        #expect(try lastLoud(chat) == nil)
    }

    @Test func theOtherNotifyModesBehaveAsBefore() throws {
        let mentions = try group(room, notify: .onMention)
        let never = try group(other, notify: .never)
        _ = try db.claimNotifications()
        try incoming("one", in: mentions, mentionsMe: true)
        try incoming("two", in: mentions, mentionsMe: true)
        try incoming("three", in: mentions)
        try incoming("four", in: never)
        try incoming("five", in: never, mentionsMe: true)
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["one", "two", "three", "four", "five"])
        #expect(quiet(claimed) == [false, false, true, true, true])
        #expect(try lastLoud(mentions) == nil && lastLoud(never) == nil)
    }

    @Test func anEditIsNotThrottled() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let first = try incoming("one", in: chat)
        _ = try db.claimNotifications(now: start)
        try db.writer.write { db in
            var edited = try #require(try Message.fetchOne(db, key: first.id))
            edited.setBody("one, edited")
            edited.editedAt = start
            try edited.update(db)
        }
        let claimed = try db.claimNotificationsAndEdits(now: start.addingTimeInterval(60))
        #expect(claimed.new.isEmpty)
        #expect(claimed.edited.map(\.body) == ["one, edited"])
        #expect(try lastLoud(chat) == start)
    }

    @Test func oneGroupsIntervalDoesNotAffectAnotherGroupOrAChat() throws {
        let throttled = try group(room)
        let plain = try group(other, interval: nil)
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        try incoming("one", in: throttled)
        try incoming("two", in: throttled)
        try incoming("three", in: plain)
        try incoming("four", in: plain)
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "five", remoteId: "r5"))
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "six", remoteId: "r6"))
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["one", "two", "three", "four", "five", "six"])
        #expect(quiet(claimed) == [false, true, false, false, false, false])
    }

    @Test func theIntervalSyncsButTheLastLoudTimeDoesNot() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        try incoming("one", in: chat)
        _ = try db.claimNotifications()
        #expect(try db.notificationInterval(peer: room) == 15)
        let entries = try db.reader.read { try AppDatabase.syncedEntries($0, item: AppDatabase.chatItem(room)) }
        #expect(entries.first { $0.key == "notificationInterval" }?.value == "15")
        #expect(!entries.contains { $0.key.lowercased().contains("lastloud") })
        #expect(AppDatabase.syncedChatKeys["lastLoudNotificationAt"] == nil)

        try db.setNotificationInterval(nil, peer: room)
        #expect(try db.notificationInterval(peer: room) == nil)
        let cleared = try db.reader.read { try AppDatabase.syncedEntries($0, item: AppDatabase.chatItem(room)) }
        let entry = try #require(cleared.first { $0.key == "notificationInterval" })
        #expect(entry.value == nil)
    }

    @Test func aClaimThatShowsNothingDoesNotStartTheInterval() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        try incoming("seen in the app", in: chat)
        _ = try db.claimNotifications(now: start, notifies: false)
        #expect(try lastLoud(chat) == nil)
        try incoming("after leaving", in: chat)
        #expect(try quiet(db.claimNotifications(now: start.addingTimeInterval(60))) == [false])
    }

    @Test func aClockSetBackDoesNotHoldTheGroupSilent() throws {
        let chat = try group(room)
        _ = try db.claimNotifications()
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        try incoming("one", in: chat)
        _ = try db.claimNotifications(now: start.addingTimeInterval(24 * 3600))
        // Sent by the server's clock, which was right.
        try incoming("two", in: chat, at: start.addingTimeInterval(24 * 3600))
        #expect(try quiet(db.claimNotifications(now: start)) == [false])
    }

    @Test func aSyncedIntervalOutOfRangeIsIgnored() throws {
        _ = try group(room, interval: nil)
        let key = try #require(AppDatabase.syncedChatKeys["notificationInterval"])
        for value in ["200000000000000000", "0", "-5", "soon"] {
            try db.writer.write { try key.apply($0, room, value) }
            #expect(try db.notificationInterval(peer: room) == nil)
        }
        try db.writer.write { try key.apply($0, room, "30") }
        #expect(try db.notificationInterval(peer: room) == 30)
    }
}
