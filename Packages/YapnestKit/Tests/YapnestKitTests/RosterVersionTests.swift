import Foundation
import Testing
@testable import Martin

/// RFC 6121 roster versioning, which a SASL 2 sign-in never announces in the
/// stream features: the stored version is sent anyway.
@Suite struct RosterVersionTests {
    private let wire = FakeWire()
    private let store = DefaultRosterStore()
    private let client = XMPPClient()
    private let module: RosterModule

    init() {
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.writer = wire
        _ = client.modulesManager.register(StreamFeaturesModule())
        module = client.modulesManager.register(RosterModule(rosterManager: RosterManagerBase(store: store)))
    }

    private func fetch(answering reply: @escaping @Sendable (Iq) -> Iq) async throws {
        wire.answer(reply)
        try await module.requestRoster()
    }

    private func sentVersion() -> String?? {
        guard let iq = wire.written.compactMap({ $0 as? Iq }).last, let query = iq.firstChild(name: "query", xmlns: "jabber:iq:roster") else { return nil }
        return .some(query.attribute("ver"))
    }

    private func keep(_ jid: String) {
        store.updateItem(for: client, jid: JID(jid), name: nil, subscription: .both, groups: [], ask: false, annotations: [])
    }

    @Test func aStoredVersionIsSentWithoutTheStreamFeature() async throws {
        store.set(version: "42", for: client)
        try await fetch { FakeWire.result(to: $0) }
        #expect(sentVersion() == .some("42"))
    }

    @Test func noVersionAsksForOneWithAnEmptyAttribute() async throws {
        try await fetch { FakeWire.result(to: $0) }
        #expect(sentVersion() == .some(""))
    }

    @Test func anAnswerWithoutItemsToAVersionedRequestRemovesNothing() async throws {
        keep("bob@localhost")
        store.set(version: "42", for: client)
        try await fetch { FakeWire.result(to: $0, Element(name: "query", xmlns: "jabber:iq:roster")) }
        #expect(store.items(for: client).map(\.jid) == [JID("bob@localhost")])
    }

    @Test func aFullRosterWithoutVersionStillRemovesWhatIsGone() async throws {
        keep("bob@localhost")
        try await fetch { FakeWire.result(to: $0, Element(name: "query", xmlns: "jabber:iq:roster")) }
        #expect(store.items(for: client).isEmpty)
    }
}
