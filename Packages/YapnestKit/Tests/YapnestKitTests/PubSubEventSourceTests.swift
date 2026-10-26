import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// Whose PubSub event notifications are believed.
struct PubSubEventSourceTests {
    private func event(from sender: String?, type: StanzaType = .headline) -> Message {
        let message = Message()
        message.type = type
        if let sender { message.from = JID(sender) }
        let item = Element(name: "item", attributes: ["id": "abc"])
        item.addChild(Element(name: "metadata", xmlns: "urn:xmpp:avatar:metadata"))
        let items = Element(name: "items", attributes: ["node": "urn:xmpp:avatar:metadata"])
        items.addChild(item)
        message.addChild(Element(name: "event", xmlns: PubSubModule.PUBSUB_EVENT_XMLNS, children: [items]))
        return message
    }

    private func delivered(_ message: Message) throws -> Bool {
        let module = PubSubModule()
        var seen = false
        let subscription = module.itemsEvents.sink { _ in seen = true }
        defer { subscription.cancel() }
        try module.process(message: message)
        return seen
    }

    @Test func anAccountsOwnServerIsBelieved() throws {
        #expect(try delivered(event(from: "alice@example.org")))
        #expect(try delivered(event(from: "pubsub.example.org")))
        // Our own server, for our own account.
        #expect(try delivered(event(from: nil)))
    }

    /// A member's group message carrying an empty avatar cleared the group's
    /// picture for everyone, as the bare address of room/nick is the room's.
    @Test func aGroupMemberCantPublishInTheRoomsName() throws {
        #expect(try !delivered(event(from: "club@groups.example.org/mallory", type: .groupchat)))
        #expect(try !delivered(event(from: "club@groups.example.org", type: .groupchat)))
        // A private message through the room.
        #expect(try !delivered(event(from: "club@groups.example.org/mallory", type: .chat)))
    }

    @Test func aFullAddressIsntAService() throws {
        #expect(try !delivered(event(from: "alice@example.org/phone")))
    }
}
