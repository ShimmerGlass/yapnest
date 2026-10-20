import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing

/// A module that only offers a feature, to change what the client advertises.
private final class FeatureModule: XmppModuleBase, XmppModule {
    static let ID = "test-feature"
    let criteria = Criteria.empty()
    let features: [String]
    init(_ feature: String) { features = [feature] }
    func process(stanza: Stanza) throws {}
}

struct CapabilitiesTests {
    private let client = XMPPClient()
    private let wire = FakeWire()
    private let disco = DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test"))
    private let caps = CapabilitiesModule()

    init() {
        client.writer = wire
        client.connectionConfiguration.userJid = BareJID("me@example.org")
        _ = client.modulesManager.register(disco)
        _ = client.modulesManager.register(PresenceModule())
        _ = client.modulesManager.register(caps)
    }

    /// The hash our presence carries.
    private func advertised() throws -> String {
        let presence = Presence()
        caps.onBeforePresenceSend(event: PresenceModule.BeforePresenceSendEvent(context: client, presence: presence))
        return try #require(presence.firstChild(name: "c", xmlns: "http://jabber.org/protocol/caps")?.getAttribute("ver"))
    }

    /// Whether we answer a disco#info query for the node of `ver`.
    private func answers(_ ver: String) throws -> Bool {
        let before = wire.written.count
        let iq = Iq()
        iq.type = .get
        iq.id = UUID().uuidString
        iq.from = JID("peer@example.org/x")
        iq.to = JID("me@example.org/y")
        let query = Element(name: "query", xmlns: DiscoveryModule.INFO_XMLNS)
        query.setAttribute("node", value: caps.nodeName + "#" + ver)
        iq.addChild(query)
        try disco.process(stanza: iq)
        return wire.written.count > before
    }

    @Test func aChangeOfFeaturesLeavesOnlyTheCurrentHashAnswering() throws {
        let first = try advertised()
        #expect(try answers(first))

        let extra = FeatureModule("urn:example:extra")
        _ = client.modulesManager.register(extra)
        caps.invalidateVerificationString()
        let second = try advertised()
        #expect(second != first)

        _ = client.modulesManager.unregister(extra)
        caps.invalidateVerificationString()
        #expect(try advertised() == first)

        #expect(try answers(first))
        #expect(try !answers(second), "a hash we no longer advertise still answers")
    }

    @Test func invalidatingTwiceBeforeAPresenceStillForgetsTheOldHash() throws {
        let first = try advertised()
        _ = client.modulesManager.register(FeatureModule("urn:example:extra"))
        caps.invalidateVerificationString()
        caps.invalidateVerificationString()
        let second = try advertised()
        #expect(second != first)
        #expect(try !answers(first))
        #expect(try answers(second))
    }

    @Test func invalidatingWhilePresencesAreSentIsSafe() async throws {
        _ = try advertised()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    for _ in 0..<500 {
                        if index.isMultiple(of: 2) {
                            caps.invalidateVerificationString()
                        } else {
                            _ = try? advertised()
                        }
                    }
                }
            }
        }
        #expect(try answers(advertised()))
    }
}
