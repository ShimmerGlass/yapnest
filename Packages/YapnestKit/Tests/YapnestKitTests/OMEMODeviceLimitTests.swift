import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

/// A device list is cut to 64 devices before anything is built from it, and
/// the cut keeps the devices in use.
struct OMEMODeviceLimitTests {
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!
    let clock = TestClock()

    private func key(_ id: Int32) -> Data { Data([0x05] + Array(repeating: UInt8(truncatingIfNeeded: id), count: 32)) }

    private func store() throws -> OMEMOStore {
        let clock = clock
        return OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore(), now: { clock.now })
    }

    /// Knows devices `ids` of alice, each last used `daysAgo` days ago.
    private func know(_ ids: [Int32], usedDaysAgo daysAgo: Double, in store: OMEMOStore) {
        for id in ids {
            #expect(store.save(identity: SignalAddress(name: alice.description, deviceId: id), publicKeyData: key(id)))
            store.noteUsed(name: alice.description, deviceId: id, at: clock.now.addingTimeInterval(-daysAgo * 86400))
        }
    }

    @Test func aShortListIsLeftAlone() throws {
        let store = try store()
        #expect(store.limited(Array(1...64), of: alice.description) == Array(1...64))
    }

    @Test func aFloodOfNewIdsNeverPushesOutADeviceInUse() throws {
        let store = try store()
        know([5000], usedDaysAgo: 1, in: store)
        know([5001], usedDaysAgo: 2, in: store)
        let flood = Array(1...1000).map(Int32.init)
        let kept = store.limited(flood + [5000, 5001], of: alice.description)
        #expect(kept.count == 64)
        #expect(Array(kept.prefix(2)) == [5000, 5001], "the devices in use come first")
    }

    @Test func aNewDeviceTakesThePlaceOfAStaleOne() throws {
        let store = try store()
        know([900], usedDaysAgo: 200, in: store)
        let kept = store.limited(Array(1...200).map(Int32.init) + [900], of: alice.description)
        #expect(kept.count == 64)
        #expect(!kept.contains(900), "a stale device is cut before new ones")
        #expect(kept.contains(1) && kept.contains(64))
    }

    @Test func knownDevicesComeMostRecentlyUsedFirst() throws {
        let store = try store()
        know([10], usedDaysAgo: 5, in: store)
        know([11], usedDaysAgo: 1, in: store)
        know([12], usedDaysAgo: 3, in: store)
        let kept = store.limited(Array(100...300).map(Int32.init) + [10, 11, 12], of: alice.description)
        #expect(Array(kept.prefix(3)) == [11, 12, 10])
    }

    @Test func staleDevicesFillTheRestAfterTheNewOnes() throws {
        let store = try store()
        know([900, 901], usedDaysAgo: 200, in: store)
        let kept = store.limited(Array(1...40).map(Int32.init) + [900, 901], of: alice.description)
        #expect(kept == Array(1...40).map(Int32.init) + [900, 901], "under the limit nothing is cut")
        let more = store.limited(Array(1...63).map(Int32.init) + [900, 901], of: alice.description)
        #expect(more.count == 64)
        #expect(Set(more).intersection([900, 901]).count == 1, "one stale device fits after the 63 new ones")
    }

    @Test func thisInstallsDeviceIsNeverCut() throws {
        let database = try AppDatabase.inMemory()
        let encryption = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let own = Int32(bitPattern: encryption.deviceId)
        let ids = Array(1...200).map(Int32.init).filter { $0 != own } + [own]
        #expect(encryption.store.limited(ids, of: me.description).contains(own))
    }

    @Test(.timeLimit(.minutes(1))) func aThousandListedDevicesStartAtMost64Sessions() async throws {
        let wire = FakeWire()
        let ids = Array(1...1000).map(Int32.init)
        wire.answer { [alice] iq in
            if iq.to?.bareJid.stringValue == alice.description,
               iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE {
                return OMEMODeviceListTests.list(ids, to: iq)
            }
            return FakeWire.error(to: iq)
        }
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = wire
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        let module = encryption.module, jid = BareJID(alice.description)
        await withCheckedContinuation { continuation in module.addresses(for: [jid]) { _ in continuation.resume() } }
        withExtendedLifetime(client) {}
        let bundleRequests = wire.written.compactMap { $0 as? Iq }.filter {
            ($0.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") ?? "").hasPrefix("eu.siacs.conversations.axolotl.bundles")
        }
        #expect(bundleRequests.count == 64, "\(bundleRequests.count) bundles asked for")
    }
}
