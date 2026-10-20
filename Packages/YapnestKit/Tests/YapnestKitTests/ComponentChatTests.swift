import Foundation
import Martin
import Testing
@testable import YapnestKit

/// Chats with a component such as a gateway, whose address is a bare domain.
struct ComponentChatTests {
    let me = YapnestKit.JID("me@example.org")!
    let gateway = YapnestKit.JID("whatsapp.xmpp.example.org")!
    let alice = YapnestKit.JID("alice@example.org")!

    private func parse(_ from: String, id: String = "m1") throws -> InboundMessage {
        let xml = "<message from='\(from)' to='me@example.org/yapnest' type='chat' id='\(id)'><body>Scan this</body></message>"
        let stanza = Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
        return try #require(InboundMessage(stanza, account: me, source: .live))
    }

    @Test(arguments: ["whatsapp.xmpp.example.org", "whatsapp.xmpp.example.org/slidge"])
    func aMessageFromTheDomainIsAChatWithIt(_ from: String) throws {
        let inbound = try parse(from)
        #expect(inbound.peer == gateway)
        #expect(!inbound.isOutgoing)
    }

    @Test func aMessageFromTheDomainLandsInOneConversation() throws {
        let db = try AppDatabase.inMemory()
        let first = try db.ingest(try parse("whatsapp.xmpp.example.org", id: "m1"))
        let second = try db.ingest(try parse("whatsapp.xmpp.example.org/slidge", id: "m2"))
        #expect(first.newMessage != nil && second.newMessage != nil)
        #expect(first.conversationId == second.conversationId)
        let list = try db.chatList()
        #expect(list.count == 1)
        #expect(list[0].conversation.peer == gateway)
        #expect(list[0].title == "whatsapp.xmpp.example.org")
    }

    @Test func aChatWithTheDomainIsNotEncryptedUnlessChosen() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.isEncrypted(with: gateway) == false)
        #expect(try db.isEncrypted(with: alice))
        #expect(try db.conversation(with: gateway).isEncrypted == false)
        #expect(try db.conversation(with: alice).isEncrypted)
        try db.setEncrypted(true, with: gateway)
        #expect(try db.isEncrypted(with: gateway))
    }

    @Test func aPersonBehindAKnownGatewayIsNotEncryptedByDefault() throws {
        let db = try AppDatabase.inMemory()
        let puppet = YapnestKit.JID("33612345678@whatsapp.xmpp.example.org")!
        #expect(try db.isEncrypted(with: puppet))
        try db.conversation(with: gateway)
        #expect(try db.isEncrypted(with: puppet) == false)
        #expect(try db.conversation(with: puppet).isEncrypted == false)
        #expect(try db.conversation(with: alice).isEncrypted)
    }

    @Test func messagesToTheDomainAreStagedPlain() throws {
        let db = try AppDatabase.inMemory()
        let outgoing = OutgoingMessages(database: db, attachments: AttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "component-\(UUID().uuidString)")), account: me)
        let toGateway = try outgoing.stage([.text("register", reply: nil)], to: gateway)
        let toAlice = try outgoing.stage([.text("hi", reply: nil)], to: alice)
        #expect(toGateway[0].encryption == .none)
        #expect(toAlice[0].encryption == .omemo)
    }
}
