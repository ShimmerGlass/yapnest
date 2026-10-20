import Foundation
import Testing
@testable import Martin

/// Roster pushes a server shouldn't send. None of them may trap.
@Suite struct RosterInputTests {
    private final class NullWriter: PacketWriter {
        func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
        func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
    }

    private func push(_ items: [(jid: String, subscription: String?)]) throws -> [JID] {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.writer = NullWriter()
        _ = client.modulesManager.register(StreamFeaturesModule())
        let store = DefaultRosterStore()
        let module = client.modulesManager.register(RosterModule(rosterManager: RosterManagerBase(store: store)))
        let query = Element(name: "query", xmlns: "jabber:iq:roster")
        for (jid, subscription) in items {
            let item = Element(name: "item")
            item.attribute("jid", newValue: jid)
            if let subscription { item.attribute("subscription", newValue: subscription) }
            query.addChild(item)
        }
        let iq = Iq()
        iq.type = .set
        iq.addChild(query)
        try module.processSet(stanza: iq)
        return store.items(for: client).map(\.jid)
    }

    @Test func unknownSubscriptionSkipsTheItem() throws {
        let jids = try push([("bob@localhost", "frobnicate"), ("carol@localhost", "both"), ("dave@localhost", nil)])
        #expect(Set(jids) == [JID("carol@localhost"), JID("dave@localhost")])
    }
}
