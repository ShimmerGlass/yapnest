import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let mallory = YapnestKit.JID("mallory@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

/// A sender picks the `id` of what they send, so a message can be given
/// another's id. Only the stanza-id is the room's or server's own.
struct ReferenceResolutionTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
        try db.joinGroupChat(room, nickname: "me")
    }

    private func group(_ xml: String, at seconds: TimeInterval) throws {
        let context = RoomContext(jid: room, nickname: "me", occupants: ["anna": alice, "mal": mallory], trustsOccupantIds: false)
        let inbound = try #require(InboundMessage(groupchat: stanza(xml), room: context, account: me, source: .live, now: Date(timeIntervalSince1970: seconds)))
        try db.ingest(inbound)
    }

    private func chat(_ xml: String, at seconds: TimeInterval) throws {
        try db.ingest(try #require(InboundMessage(stanza(xml), account: me, source: .live, now: Date(timeIntervalSince1970: seconds))))
    }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    private func message(_ body: String) throws -> YapnestKit.Message {
        try #require(messages().first { $0.body == body })
    }

    /// Alice's message, then Mallory's, which borrows Alice's ids.
    private func collide(copying: String) throws {
        try group("<message from='cake@rooms.example.org/anna' type='groupchat' id='g1'><body>mine</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='rs1'/></message>", at: 100)
        // Mallory can't choose the stanza-id the room gives his message, only his own `id`.
        let id = copying == "stanza-id" ? "rs1" : "g1"
        try group("<message from='cake@rooms.example.org/mal' type='groupchat' id='\(id)'><body>copy</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='rs2'/></message>", at: 200)
    }

    @Test func aCopiedIdDoesNotBlockTheAuthorsRetraction() throws {
        try collide(copying: "stanza-id")
        try group("<message from='cake@rooms.example.org/anna' type='groupchat' id='r'><retract id='rs1' xmlns='urn:xmpp:message-retract:1'/></message>", at: 300)
        let stored = try messages()
        #expect(stored.count == 2)
        #expect(stored[0].isRetracted)
        #expect(!stored[1].isRetracted)
    }

    @Test func aCopiedIdDoesNotBlockTheAuthorsCorrection() throws {
        try collide(copying: "id")
        try group("<message from='cake@rooms.example.org/anna' type='groupchat' id='c1'><body>fixed</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/></message>", at: 300)
        #expect(try messages().map(\.body) == ["fixed", "copy"])
    }

    @Test func aReactionByStanzaIdLandsOnTheMessageItNames() throws {
        try collide(copying: "stanza-id")
        try group("<message from='cake@rooms.example.org/mal' type='groupchat' id='x1'><reactions xmlns='urn:xmpp:reactions:0' id='rs1'><reaction>👍</reaction></reactions></message>", at: 300)
        let mine = try message("mine"), copy = try message("copy")
        let reacted = try db.reader.read { try Reaction.fetchAll($0).map(\.messageId) }
        #expect(reacted == [mine.id])
        #expect(copy.id != mine.id)
    }

    @Test func aReplyQuotesTheMessageTheStanzaIdNames() throws {
        try collide(copying: "stanza-id")
        try group("<message from='cake@rooms.example.org/mal' type='groupchat' id='q1'><body>re</body><reply xmlns='urn:xmpp:reply:0' id='rs1' to='cake@rooms.example.org/anna'/></message>", at: 300)
        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: room, me: me) }
        let reply = try #require(items.first { $0.message.body == "re" })
        #expect(reply.quote?.messageId == (try message("mine")).id)
        // The cached observation resolves it the same way.
        let cached = try db.reader.read { try AppDatabase.referencedMessage($0, conversationId: reply.message.conversationId, id: "rs1") }
        #expect(cached?.body == "mine")
    }

    @Test func anOrdinaryReferenceStillFindsItsMessage() throws {
        try chat("<message from='alice@example.org/phone' type='chat' id='m1'><body>hello</body></message>", at: 100)
        let conversationId = try message("hello").conversationId
        let found = try db.reader.read { try AppDatabase.referencedMessage($0, conversationId: conversationId, id: "m1") }
        #expect(found?.body == "hello")
    }

    @Test func aReceiptDoesNotLandOnTheirMessageWithOurId() throws {
        try chat("<message from='alice@example.org/phone' type='chat' id='same'><body>theirs</body></message>", at: 100)
        let conversationId = try message("theirs").conversationId
        try db.updateStatus(.delivered, conversationId: conversationId, remoteId: "same")
        #expect(try message("theirs").status == .received)
    }
}
