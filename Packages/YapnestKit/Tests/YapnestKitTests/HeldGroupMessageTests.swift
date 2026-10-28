import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

struct HeldGroupMessageTests {
    let db: AppDatabase
    let room = YapnestKit.JID("cake@rooms.example.org")!
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws { db = try AppDatabase.inMemory() }

    private func xml(_ id: String, body: String, extra: String = "") -> String {
        "<message from='cake@rooms.example.org/alice' type='groupchat' id='\(id)'><body>\(body)</body>\(extra)</message>"
    }

    private func inbound(_ id: String, body: String, extra: String = "", source: InboundMessage.Source = .live) throws -> InboundMessage {
        let element = try #require(Element.from(string: xml(id, body: body, extra: extra)))
        let stanza = try #require(Stanza.from(element: element) as? Martin.Message)
        let context = RoomContext(jid: room, nickname: "me")
        var message = try #require(InboundMessage(groupchat: stanza, room: context, account: me, source: source))
        message.encryption = .omemo
        message.omemoDevice = 7
        message.omemoTrust = .trusted
        return message
    }

    private func placeholder(_ id: String, isRead: Bool = false, serverId: String? = nil, presenceSession: Int64? = nil) throws -> YapnestKit.Message {
        let conversation = try db.joinGroupChat(room, nickname: "me").conversationId
        var message = YapnestKit.Message(
            conversationId: conversation, direction: .incoming, sender: room, nick: "alice", body: "🔒", timestamp: at,
            isRead: isRead, encryption: .omemoUndecryptable, remoteId: id, serverId: serverId,
        )
        message.presenceSession = presenceSession
        return try db.insert(message)
    }

    @discardableResult
    private func hold(_ message: YapnestKit.Message, device: Int32 = 7, source: InboundMessage.Source = .live) throws -> HeldGroupMessage {
        try db.hold(messageId: message.id!, sender: alice, deviceId: device, stanza: "<message/>", source: source, isHistory: false, at: at)
        return try #require(db.heldGroupMessages().last)
    }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    @Test func holdsAreListedInArrivalOrder() throws {
        let first = try placeholder("a")
        let second = try placeholder("b")
        let third = try placeholder("c")
        try hold(first, device: 7)
        try hold(second, device: 8)
        try hold(third, device: 7)
        #expect(try db.heldGroupMessages().map(\.messageId) == [first.id, second.id, third.id])
    }

    @Test func aSecondHoldForTheSameMessageIsIgnored() throws {
        let message = try placeholder("a")
        try hold(message, device: 7)
        try hold(message, device: 9)
        let held = try db.heldGroupMessages()
        #expect(held.count == 1)
        #expect(held[0].deviceId == 7)
    }

    @Test func replaceTurnsThePlaceholderIntoTheMessage() throws {
        let message = try placeholder("a")
        let held = try hold(message)
        let result = try #require(try db.replace(held, with: inbound("a", body: "hello")))
        #expect(result.newMessage?.body == "hello")
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(stored[0].body == "hello")
        #expect(stored[0].conversationId == message.conversationId)
        #expect(stored[0].timestamp == at)
        #expect(stored[0].nick == "alice")
        #expect(stored[0].encryption == .omemo)
        #expect(stored[0].omemoDevice == 7)
        #expect(stored[0].omemoTrust == .trusted)
        #expect(try db.heldGroupMessages().isEmpty)
    }

    @Test func replaceDoesNotTreatThePlaceholderAsADuplicate() throws {
        let message = try placeholder("a", serverId: "s1")
        let held = try hold(message)
        let result = try db.replace(held, with: inbound("a", body: "hello", source: .archive(serverId: "s1", timestamp: nil)))
        #expect(result?.newMessage != nil)
        #expect(try messages().map(\.body) == ["hello"])
    }

    @Test func aReadPlaceholderStaysReadAndAnUnreadOneStaysUnread() throws {
        let read = try placeholder("a", isRead: true)
        let unread = try placeholder("b", isRead: false)
        let readResult = try #require(try db.replace(hold(read), with: inbound("a", body: "one")))
        let unreadResult = try #require(try db.replace(hold(unread), with: inbound("b", body: "two")))
        #expect(readResult.newMessage?.isRead == true)
        #expect(unreadResult.newMessage?.isRead == false)
        #expect(try messages().map(\.isRead) == [true, false])
    }

    @Test func replaceKeepsThePlaceholdersPresenceSession() throws {
        let message = try placeholder("a", presenceSession: 42)
        let result = try #require(try db.replace(hold(message), with: inbound("a", body: "hello")))
        #expect(result.newMessage?.presenceSession == 42)
        #expect(try messages().map(\.presenceSession) == [42])
    }

    @Test func replaceKeepsAnAttachmentAndAReply() throws {
        let message = try placeholder("a")
        let held = try hold(message)
        let link = "aesgcm://files.example.org/up/cat.jpg#" + String(repeating: "ab", count: 44)
        let reply = "<reply xmlns='urn:xmpp:reply:0' to='cake@rooms.example.org/bob' id='orig'/>"
        let result = try #require(try db.replace(held, with: inbound("a", body: link, extra: reply)))
        #expect(result.newAttachment != nil)
        let stored = try #require(try messages().first)
        #expect(stored.replyToId == "orig")
        let attachments = try db.reader.read { try Attachment.fetchAll($0) }
        #expect(attachments.count == 1)
        #expect(attachments[0].messageId == stored.id)
    }

    @Test func replaceOfADeletedPlaceholderStoresNothingAndDropsTheHold() throws {
        let message = try placeholder("a")
        let held = try hold(message)
        try db.writer.write { _ = try YapnestKit.Message.deleteOne($0, key: message.id) }
        #expect(try db.heldGroupMessages().isEmpty)
        #expect(try db.replace(held, with: inbound("a", body: "hello")) == nil)
        #expect(try messages().isEmpty)
    }

    @Test func replaceOfAPlaceholderThatIsNoLongerOneDropsTheHold() throws {
        let message = try placeholder("a")
        let held = try hold(message)
        try db.writer.write { try YapnestKit.Message.filter(Column("id") == message.id).updateAll($0, Column("encryption").set(to: "omemo")) }
        #expect(try db.replace(held, with: inbound("a", body: "hello")) == nil)
        #expect(try db.heldGroupMessages().isEmpty)
        #expect(try messages().map(\.body) == ["🔒"])
    }

    @Test func aRetractedPlaceholderStaysATombstone() throws {
        let byAuthor = try placeholder("a", serverId: "s1")
        let byModerator = try placeholder("b", serverId: "s2")
        let authorHold = try hold(byAuthor)
        let moderatorHold = try hold(byModerator)
        try db.writer.write { db in
            var message = try YapnestKit.Message.fetchOne(db, key: byAuthor.id)!
            _ = try AppDatabase.retract(db, &message)
        }
        _ = try db.applyModeratedRetraction(in: room, target: "s2")
        #expect(try db.replace(authorHold, with: inbound("a", body: "hello")) == nil)
        #expect(try db.replace(moderatorHold, with: inbound("b", body: "hello")) == nil)
        #expect(try messages().map(\.isRetracted) == [true, true])
        #expect(try messages().map(\.body) == ["", ""])
        #expect(try db.heldGroupMessages().isEmpty)
    }

    @Test func aDelayedMessageKeepsItsPlaceAmongNewerOnes() throws {
        let message = try placeholder("a")
        let held = try hold(message)
        _ = try db.insert(YapnestKit.Message(conversationId: message.conversationId, direction: .incoming, sender: alice, body: "newer", timestamp: at.addingTimeInterval(600), remoteId: "n"))
        let delay = "<delay xmlns='urn:xmpp:delay' from='cake@rooms.example.org' stamp='2023-11-14T22:13:20Z'/>"
        let delayed = try inbound("a", body: "hello", extra: delay)
        #expect(delayed.isDelayed)
        _ = try #require(try db.replace(held, with: delayed))
        let stored = try messages()
        #expect(stored.first { $0.body == "hello" }?.timestamp == at)
        #expect(stored.first { $0.body == "hello" }!.timestamp < stored.first { $0.body == "newer" }!.timestamp)
    }

    @Test func reactionsOnThePlaceholderSurviveReplace() throws {
        let message = try placeholder("a")
        let held = try hold(message)
        try db.writer.write { try Reaction(messageId: message.id!, sender: alice, nick: "alice", emoji: "👍").insert($0) }
        let result = try #require(try db.replace(held, with: inbound("a", body: "hello")))
        let reactions = try db.reader.read { try Reaction.fetchAll($0) }
        #expect(reactions.map(\.emoji) == ["👍"])
        #expect(reactions.first?.messageId == result.newMessage?.id)
    }

    @Test func aHoldIsFoundForTheCopyOfItsMessage() throws {
        let message = try placeholder("a", serverId: nil)
        let held = try hold(message)
        let copy = try inbound("a", body: "hello", source: .archive(serverId: "s9", timestamp: nil))
        #expect(try db.hold(matching: copy, in: message.conversationId)?.id == held.id)
        #expect(try db.hold(matching: inbound("other", body: "hello"), in: message.conversationId) == nil)
    }

    @Test func aHoldIsFoundByServerId() throws {
        let message = try placeholder("a", serverId: "s1")
        let held = try hold(message)
        #expect(try db.hold(matching: inbound("zzz", body: "x", source: .archive(serverId: "s1", timestamp: nil)), in: message.conversationId)?.id == held.id)
    }

    @Test func aPlaceholderWithoutAHoldIsNotFound() throws {
        let message = try placeholder("a")
        #expect(try db.hold(matching: inbound("a", body: "hello"), in: message.conversationId) == nil)
    }

    @Test func releaseKeepsThePlaceholder() throws {
        let message = try placeholder("a")
        try db.release(hold(message))
        #expect(try db.heldGroupMessages().isEmpty)
        #expect(try messages().map(\.body) == ["🔒"])
    }

    @Test func aSourceSurvivesTheDatabase() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_100)
        let sources: [InboundMessage.Source] = [.live, .archive(serverId: "s9", timestamp: when), .archive(serverId: "s10", timestamp: nil), .carbon(sent: true), .carbon(sent: false)]
        for (index, source) in sources.enumerated() {
            try hold(placeholder("m\(index)"), source: source)
        }
        #expect(try db.heldGroupMessages().map(\.source) == sources)
    }

    @Test func theMigrationCreatesTheTableOnADatabaseAtV47() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v47-addresses-me")
        #expect(try queue.read { try $0.tableExists("heldGroupMessage") } == false)
        try AppDatabase.migrator.migrate(queue)
        #expect(try queue.read { try $0.tableExists("heldGroupMessage") })
    }
}
