import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

/// XEP-0490 message displayed synchronization.
struct DisplayedSyncTests {
    let db: AppDatabase
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @Test func itemRoundTrips() throws {
        let state = DisplayedState(peer: alice, stanzaId: "s1", by: me)
        let xml = state.element.stringValue
        #expect(xml.contains("urn:xmpp:mds:displayed:0"))
        #expect(xml.contains("urn:xmpp:sid:0"))
        #expect(DisplayedState(id: alice.description, payload: Element.from(string: xml)) == state)
        #expect(DisplayedState(id: alice.description, payload: Element.from(string: "<displayed xmlns='urn:xmpp:mds:displayed:0'/>")) == nil)
    }

    @Test func readStateOnlyMovesForward() throws {
        let conversation = try db.conversation(with: alice)
        for (index, serverId) in ["s1", "s2", "s3"].enumerated() {
            try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "m\(index)",
                                  timestamp: Date(timeIntervalSince1970: Double(index)), serverId: serverId))
        }
        func unread() throws -> [String] {
            try db.reader.read { try Message.filter(Column("isRead") == false).order(Column("timestamp")).fetchAll($0).map(\.body) }
        }
        #expect(try db.applyDisplayed(peer: alice, stanzaId: "s2"))
        #expect(try unread() == ["m2"])
        // An older state doesn't make anything unread again.
        #expect(try db.applyDisplayed(peer: alice, stanzaId: "s1"))
        #expect(try unread() == ["m2"])
        // A message we don't have yet is ignored.
        #expect(try !db.applyDisplayed(peer: alice, stanzaId: "unknown"))
        #expect(try unread() == ["m2"])
        #expect(try !db.applyDisplayed(peer: YapnestKit.JID("nobody@example.org")!, stanzaId: "s3"))
    }
}
