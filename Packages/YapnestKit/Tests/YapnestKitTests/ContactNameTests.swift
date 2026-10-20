import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// Naming a contact: the roster set that does it, and the roster push that
/// brings the name into the database, from this device or another.
struct ContactNameTests {
    private func item(of iq: Iq) throws -> Element {
        let query = try #require(iq.firstChild(name: "query", xmlns: "jabber:iq:roster"))
        return try #require(query.firstChild(name: "item"))
    }

    private func push(_ session: XMPPSession, jid: String, name: String?, subscription: String = "both", groups: [String] = []) throws {
        let item = Element(name: "item")
        item.attribute("jid", newValue: jid)
        item.attribute("subscription", newValue: subscription)
        if let name { item.attribute("name", newValue: name) }
        for group in groups { item.addChild(Element(name: "group", cdata: group)) }
        let query = Element(name: "query", xmlns: "jabber:iq:roster")
        query.addChild(item)
        let iq = Iq()
        iq.type = .set
        iq.addChild(query)
        try session.client.module(.roster).processSet(stanza: iq)
    }

    /// The roster set the session wrote for `name`, with the contact's groups
    /// as they were.
    private func renamed(to name: String?, groups: [String] = ["Friends", "Work"]) async throws -> Element {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { FakeWire.result(to: $0) }
        try push(session, jid: "alice@example.org", name: nil, groups: groups)
        try await session.setContactName(alice, name: name)
        let iq = try #require(wire.written.compactMap { $0 as? Iq }.last)
        #expect(iq.type == .set)
        return try item(of: iq)
    }

    @Test func theRosterSetKeepsGroupsAndLeavesTheSubscriptionAlone() async throws {
        let item = try await renamed(to: "Ally")
        #expect(item.attribute("jid") == "alice@example.org")
        #expect(item.attribute("name") == "Ally")
        #expect(item.attribute("subscription") == nil)
        #expect(item.attribute("ask") == nil)
        #expect(item.filterChildren(name: "group", xmlns: nil).compactMap(\.value) == ["Friends", "Work"])
    }

    @Test func noNameOmitsTheAttribute() async throws {
        #expect(try await renamed(to: nil, groups: []).attribute("name") == nil)
        #expect(try await renamed(to: "  ", groups: []).attribute("name") == nil)
    }

    @Test func aPushSetsThenChangesThenClearsTheName() throws {
        let session = try makeSession(me)
        try push(session, jid: "alice@example.org", name: "Ally", groups: ["Friends"])
        var contact = try #require(try session.database.contact(alice))
        #expect(contact.name == "Ally")
        #expect(contact.displayName == "Ally")
        #expect(contact.rosterGroups == ["Friends"])

        // Another device renames them.
        try push(session, jid: "alice@example.org", name: "Alice L.", groups: ["Friends"])
        contact = try #require(try session.database.contact(alice))
        #expect(contact.displayName == "Alice L.")

        try push(session, jid: "alice@example.org", name: nil, groups: ["Friends"])
        contact = try #require(try session.database.contact(alice))
        #expect(contact.name == nil)
        #expect(contact.displayName == "alice")
        #expect(contact.subscription == .both)
    }

    @Test func aRenameIsRefusedOffline() async throws {
        let session = try makeSession(me)
        try push(session, jid: "alice@example.org", name: nil)
        await #expect(throws: XMPPSession.ContactError.self) { try await session.setContactName(alice, name: "Ally") }
        #expect(try session.database.contact(alice)?.name == nil)
    }
}
