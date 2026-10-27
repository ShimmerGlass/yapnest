import Combine
import Foundation
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// What the module says about the device lists it reads, which the baseline
/// of new devices is taken from.
struct OMEMODeviceListTests {
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!

    private func setUp(_ wire: FakeWire) throws -> (OMEMOEncryption, XMPPClient) {
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = wire
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        return (encryption, client)
    }

    private func isListRequest(_ iq: Iq, of jid: YapnestKit.JID) -> Bool {
        iq.to?.bareJid.stringValue == jid.description
            && iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE
    }

    static func list(_ ids: [Int32], to iq: Iq) -> Iq {
        let element = Element(name: "list", xmlns: OMEMOModule.XMLNS)
        for id in ids { element.addChild(Element(name: "device", attributes: ["id": String(id)])) }
        let item = Element(name: "item", attributes: ["id": "current"])
        item.addChild(element)
        let items = Element(name: "items", attributes: ["node": OMEMOModule.DEVICES_LIST_NODE])
        items.addChild(item)
        let reply = Iq()
        reply.type = .result
        reply.id = iq.id
        reply.from = iq.to
        reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [items]))
        return reply
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [OMEMOModule.AvailabilityChanged] = []
        var all: [OMEMOModule.AvailabilityChanged] { lock.withLock { changes } }
        func add(_ change: OMEMOModule.AvailabilityChanged) { lock.withLock { changes.append(change) } }
    }

    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test(arguments: [("internal-server-error", false), ("item-not-found", true)])
    func ourOwnListIsABaselineOnlyIfTheServerAnsweredForIt(condition: String, readFromServer: Bool) async throws {
        let wire = FakeWire()
        wire.answer { iq in FakeWire.error(to: iq, condition: condition, type: condition == "item-not-found" ? "cancel" : "wait") }
        let (encryption, client) = try setUp(wire)
        let heard = Heard()
        let subscription = encryption.module.activeDevicesPublisher.sink { heard.add($0) }
        defer { subscription.cancel(); withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        encryption.module.publishDeviceIdIfNeeded()
        await wait { heard.all.contains { $0.jid.stringValue == me.description } }
        let own = try #require(heard.all.first { $0.jid.stringValue == me.description })
        #expect(own.readFromServer == readFromServer)
    }

    @Test func aContactsListFetchedForSendingIsHeardAsRead() async throws {
        let wire = FakeWire()
        // Everything else, such as the bundles, is not there.
        wire.answer { [alice] iq in self.isListRequest(iq, of: alice) ? Self.list([7, 8], to: iq) : FakeWire.error(to: iq) }
        let (encryption, client) = try setUp(wire)
        let heard = Heard()
        let subscription = encryption.module.activeDevicesPublisher.sink { heard.add($0) }
        defer { subscription.cancel(); withExtendedLifetime(client) {} }
        let module = encryption.module, jid = BareJID(alice.description)
        _ = await Task.detached { await withCheckedContinuation { c in module.addresses(for: [jid]) { _ in c.resume() } } }.value
        let change = try #require(heard.all.first { $0.jid == jid })
        #expect(change.activeDevices == [7, 8])
        #expect(change.readFromServer)
    }
}
