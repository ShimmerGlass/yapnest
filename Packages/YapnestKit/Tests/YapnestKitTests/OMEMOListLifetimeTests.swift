import Foundation
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// How long a contact's device list is trusted before a send reads it again:
/// a minute for one we fetched, and for a notified one only while we're
/// subscribed, as the server sends no notifications after that.
struct OMEMOListLifetimeTests {
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!
    let clock = TestClock()

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int32] = [7]
        private var fetched = 0
        var listed: [Int32] { get { lock.withLock { ids } } set { lock.withLock { ids = newValue } } }
        var fetches: Int { lock.withLock { fetched } }
        func counted() -> [Int32] { lock.withLock { fetched += 1; return ids } }
    }

    private struct Fixture {
        let encryption: OMEMOEncryption
        let client: XMPPClient
        let server: Server
        let roster: DatabaseRosterStore
        let database: AppDatabase
    }

    private func setUp() throws -> Fixture {
        let clock = clock, alice = alice
        let server = Server()
        let wire = FakeWire()
        wire.answer { iq in
            guard iq.to?.bareJid.stringValue == alice.description,
                  iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE
            else { return FakeWire.error(to: iq) }
            return OMEMODeviceListTests.list(server.counted(), to: iq)
        }
        let database = try AppDatabase.inMemory()
        let encryption = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        encryption.module.now = { clock.now }
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = wire
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        let module = encryption.module
        let roster = DatabaseRosterStore(database: database, subscriptionEnded: { module.listNoLongerNotified(for: BareJID($0.description)) })
        return Fixture(encryption: encryption, client: client, server: server, roster: roster, database: database)
    }

    private func send(_ f: Fixture) async -> [Int32] {
        let module = f.encryption.module, jid = BareJID(alice.description)
        let ids: [Int32] = await Task.detached {
            await withCheckedContinuation { c in
                module.addresses(for: [jid]) { c.resume(returning: ((try? $0.get()) ?? []).map(\.deviceId).sorted()) }
            }
        }.value
        // The fake has no bundles, so each device is noted as failing and skipped
        // on the next send; that is not what these tests are about.
        module.forgetFetchFailures(for: jid)
        return ids
    }

    /// The server tells us of the list, as it does while we're subscribed.
    private func notify(_ ids: [Int32], _ f: Fixture) async {
        let element = Element(name: "list", xmlns: OMEMOModule.XMLNS)
        for id in ids { element.addChild(Element(name: "device", attributes: ["id": String(UInt32(bitPattern: id))])) }
        let message = Martin.Message()
        message.from = Martin.JID(alice.description)
        f.encryption.module.onItemNotification(notification: .init(
            message: message, node: OMEMOModule.DEVICES_LIST_NODE, timestamp: clock.now,
            action: .published(.init(id: "current", payload: element))))
        let module = f.encryption.module, jid = BareJID(alice.description)
        await eventually("the notified list to be kept") { module.devices(for: jid) == ids }
    }

    private func roster(_ f: Fixture, _ subscription: RosterItemSubscription) {
        f.roster.updateItem(for: f.client, jid: Martin.JID(alice.description), name: nil, subscription: subscription, groups: [], ask: false, annotations: [])
    }

    @Test func aFetchedListIsReusedWithinItsLifetimeAndReadAgainAfter() async throws {
        let f = try setUp()
        defer { withExtendedLifetime(f.client) {} }
        #expect(await send(f) == [7])
        #expect(f.server.fetches == 1)
        clock.advance(days: (OMEMOModule.fetchedListLifetime - 1) / 86400)
        #expect(await send(f) == [7])
        #expect(f.server.fetches == 1, "within the lifetime")
        f.server.listed = [7, 8]
        clock.advance(days: 2 / 86400)
        #expect(await send(f) == [7, 8])
        #expect(f.server.fetches == 2, "after the lifetime")
    }

    @Test func aNotifiedListStaysWhileWeAreSubscribed() async throws {
        let f = try setUp()
        defer { withExtendedLifetime(f.client) {} }
        await notify([7], f)
        clock.advance(days: 1)
        #expect(await send(f) == [7])
        #expect(f.server.fetches == 0)
    }

    @Test(arguments: [RosterItemSubscription.from, .none]) func aNotifiedListExpiresOnceTheSubscriptionEnds(subscription: RosterItemSubscription) async throws {
        let f = try setUp()
        defer { withExtendedLifetime(f.client) {} }
        await notify([7], f)
        roster(f, subscription)
        f.server.listed = [7, 8]
        clock.advance(days: 61 / 86400)
        #expect(await send(f) == [7, 8], "the phone they added since")
        #expect(f.server.fetches == 1)
    }

    @Test func aNotifiedListExpiresWhenTheContactIsRemoved() async throws {
        let f = try setUp()
        defer { withExtendedLifetime(f.client) {} }
        await notify([7], f)
        f.roster.deleteItem(for: f.client, jid: Martin.JID(alice.description))
        f.server.listed = [7, 8]
        clock.advance(days: 61 / 86400)
        #expect(await send(f) == [7, 8])
    }

    @Test(arguments: [RosterItemSubscription.to, .both]) func aRosterChangeThatKeepsUsSubscribedLeavesTheListAlone(subscription: RosterItemSubscription) async throws {
        let f = try setUp()
        defer { withExtendedLifetime(f.client) {} }
        await notify([7], f)
        roster(f, subscription)
        f.server.listed = [7, 8]
        clock.advance(days: 1)
        #expect(await send(f) == [7])
        #expect(f.server.fetches == 0)
    }
}
