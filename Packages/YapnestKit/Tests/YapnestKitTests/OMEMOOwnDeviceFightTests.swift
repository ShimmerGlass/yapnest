import Foundation
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// A server holding our device list and which bundles exist. Another of our
/// devices, the rival, acts on it: what it does after each publish of ours is
/// set by `afterPublish`.
private final class FightServer: PacketWriter, @unchecked Sendable {
    private let lock = NSLock()
    /// Kept as ids: the module edits the lists it is handed, which must not
    /// change what the server holds.
    private var list: [Int32]?
    private var log: [String] = []
    /// Called after each device list publish of ours, off the lock.
    var afterPublish: (@Sendable (FightServer) -> Void)?

    var events: [String] { lock.withLock { log } }
    var listPublishes: Int { events.filter { $0 == "list" }.count }
    var deletions: [String] { events.filter { $0.hasPrefix("delete") } }
    var ids: [Int32] { lock.withLock { list } ?? [] }

    /// The last bundle published to us, to serve as another device's.
    var publishedBundle: Element? { lock.withLock { bundlePayload } }
    private var bundlePayload: Element?
    /// What the rival's bundle node answers with; nothing at first.
    private var rivalBundle: Element?
    private var rivalBundleFetches = 0
    var rivalBundleRequests: Int { lock.withLock { rivalBundleFetches } }

    func setList(_ ids: [Int32]) { lock.withLock { list = ids } }
    func publishRivalBundle(_ bundle: Element) { lock.withLock { rivalBundle = bundle } }

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {
        let pubsub = iq.firstChild(name: "pubsub")
        var reply = Iq()
        reply.type = .result
        var published = false
        if let delete = iq.firstChild(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")?.firstChild(name: "delete"),
           let node = delete.attribute("node") {
            lock.withLock { log.append("delete \(node)") }
        } else if let publish = pubsub?.firstChild(name: "publish"), let node = publish.attribute("node") {
            if node == OMEMOModule.DEVICES_LIST_NODE {
                if let payload = publish.firstChild(name: "item")?.firstChild(name: "list") {
                    let ids = payload.mapChildren(transform: { $0.getAttribute("id") }).compactMap { Int32($0) }
                    lock.withLock { list = ids; log.append("list") }
                    published = true
                }
            } else if let id = node.split(separator: ":").last {
                lock.withLock {
                    log.append("bundle \(id)")
                    bundlePayload = publish.firstChild(name: "item")?.firstChild(name: "bundle")
                }
            }
        } else if let items = pubsub?.firstChild(name: "items"), let node = items.attribute("node") {
            if node == OMEMOModule.DEVICES_LIST_NODE, let list = lock.withLock({ list }) {
                let element = Element(name: "list", xmlns: OMEMOModule.XMLNS)
                for id in list { element.addChild(Element(name: "device", attributes: ["id": String(id)])) }
                let item = Element(name: "item", attributes: ["id": "current"])
                item.addChild(element)
                let node = Element(name: "items", attributes: ["node": node])
                node.addChild(item)
                reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [node]))
            } else if node.hasSuffix(":11"), let bundle = lock.withLock({ rivalBundleFetches += 1; return rivalBundle }) {
                let item = Element(name: "item", attributes: ["id": "current"])
                item.addChild(bundle)
                let node = Element(name: "items", attributes: ["node": node])
                node.addChild(item)
                reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [node]))
            } else {
                // No bundle is readable: ours gets published afresh each
                // time, and the other device never published one.
                reply = FakeWire.error(to: iq)
            }
        }
        if reply.type == .result {
            completionHandler?(.success(reply))
        } else {
            completionHandler?(.failure(errorDecoder(reply) as! Failure))
        }
        if published, let afterPublish {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { afterPublish(self) }
        }
    }

    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

struct OMEMOOwnDeviceFightTests {
    let me = JID("me@example.org")!
    let rival: Int32 = 11

    private func setUp(interval: TimeInterval) throws -> (OMEMOEncryption, FightServer, XMPPClient) {
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me)
        encryption.module.listPublishInterval = interval
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        let server = FightServer()
        client.writer = server
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        return (encryption, server, client)
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aDeviceWithoutABundleThatReAddsItselfIsDroppedOnceAndLeftBe() async throws {
        let (encryption, server, client) = try setUp(interval: 0.01)
        defer { withExtendedLifetime(client) {} }
        let own = Int32(bitPattern: encryption.deviceId)
        let module = encryption.module
        server.setList([own, rival])
        // Each time our list goes out, the other device is back in it and
        // its notification reaches us.
        let rounds = Rounds(limit: 15)
        server.afterPublish = { [rival] server in
            server.setList(Array(Set(server.ids + [rival])))
            if rounds.next() { module.publishDeviceIdIfNeeded() }
        }
        module.isPepAvailable = true
        await wait { module.isReady }
        for _ in 0..<10 { module.publishDeviceIdIfNeeded(); try await Task.sleep(for: .milliseconds(60)) }
        try await Task.sleep(for: .milliseconds(300))

        #expect(server.listPublishes == 1, "dropped more than once: \(server.events)")
        #expect(server.deletions.isEmpty, "a bundle was deleted: \(server.deletions)")
        #expect(server.ids.contains(rival), "left alone in the list")
    }

    @Test func aDropHeldBackByARecentPublishIsMadeWhenTheIntervalIsUp() async throws {
        let (encryption, server, client) = try setUp(interval: 0.4)
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module
        server.setList([])
        // Our list goes out at once, as we're missing from it. Right after,
        // the other device lists itself, with no bundle, and we hear of it.
        let once = Rounds(limit: 1)
        server.afterPublish = { [rival] server in
            if once.next() {
                server.setList(Array(Set(server.ids + [rival])))
                module.publishDeviceIdIfNeeded()
            }
        }
        module.isPepAvailable = true
        await wait({ server.listPublishes >= 2 }, seconds: 10)
        #expect(server.listPublishes == 2, "the drop was never made: \(server.events)")
        #expect(!server.ids.contains(rival))
        #expect(server.deletions.isEmpty)
    }

    @Test func aDeviceThatPublishedItsBundleDuringTheWaitIsNotDropped() async throws {
        // Another device's bundle, for the rival to publish.
        let (peer, peerServer, peerClient) = try setUp(interval: 0.01)
        defer { withExtendedLifetime(peerClient) {} }
        peerServer.setList([])
        peer.module.isPepAvailable = true
        await wait { peerServer.publishedBundle != nil }
        let bundle = try #require(peerServer.publishedBundle)

        let (encryption, server, client) = try setUp(interval: 0.6)
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module
        server.setList([])
        let once = Rounds(limit: 1)
        server.afterPublish = { [rival] server in
            if once.next() {
                server.setList(Array(Set(server.ids + [rival])))
                module.publishDeviceIdIfNeeded()
            }
        }
        module.isPepAvailable = true
        // The rival is found without a bundle and its drop is held back.
        await wait { server.listPublishes >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        server.publishRivalBundle(bundle)
        // Past the interval: the drop would have been made by now.
        try await Task.sleep(for: .milliseconds(1200))

        #expect(server.listPublishes == 1, "the device was dropped: \(server.events)")
        #expect(server.ids.contains(rival))
        #expect(server.rivalBundleRequests >= 1, "the bundle was never looked for again")
    }

    @Test func aDeviceWithASessionMadeDuringTheWaitIsNotRebuiltOrDropped() async throws {
        let (peer, peerServer, peerClient) = try setUp(interval: 0.01)
        defer { withExtendedLifetime(peerClient) {} }
        peerServer.setList([])
        peer.module.isPepAvailable = true
        await wait { peerServer.publishedBundle != nil }
        let bundle = try #require(peerServer.publishedBundle)

        let (encryption, server, client) = try setUp(interval: 0.6)
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module
        server.setList([])
        let once = Rounds(limit: 1)
        server.afterPublish = { [rival] server in
            if once.next() {
                server.setList(Array(Set(server.ids + [rival])))
                module.publishDeviceIdIfNeeded()
            }
        }
        module.isPepAvailable = true
        await wait { server.listPublishes >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        // The device's bundle is readable, but a session exists already, as
        // from its first message to us: building another would replace it
        // and use up a one-time prekey.
        let address = SignalAddress(name: me.description, deviceId: rival)
        _ = encryption.store.storeSessionRecord(Data([1]), forAddress: address)
        server.publishRivalBundle(bundle)
        let requestsBefore = server.rivalBundleRequests
        try await Task.sleep(for: .milliseconds(1200))

        #expect(server.rivalBundleRequests == requestsBefore, "the session was built again")
        #expect(server.listPublishes == 1, "the device was dropped: \(server.events)")
        #expect(server.ids.contains(rival))
    }

    @Test func aDeviceRemovedOnPurposeIsNotRemovedAgainWhenItComesBack() async throws {
        let (encryption, server, client) = try setUp(interval: 0.01)
        defer { withExtendedLifetime(client) {} }
        let own = Int32(bitPattern: encryption.deviceId)
        let module = encryption.module
        server.setList([own, rival])
        module.isPepAvailable = true
        await wait { module.isReady }

        let result: Result<Void, PubSubError> = await withCheckedContinuation { continuation in
            module.removeDevices(withIds: [rival]) { continuation.resume(returning: $0) }
        }
        guard case .success = result else { Issue.record("removal failed: \(result)"); return }
        #expect(!server.ids.contains(rival))
        #expect(server.deletions.count == 1, "the user's removal still deletes the bundle")

        // It is in use after all: back in the list, with no bundle.
        server.setList([own, rival])
        let before = server.listPublishes
        for _ in 0..<5 { module.publishDeviceIdIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
        #expect(server.listPublishes == before, "removed again: \(server.events)")
        #expect(server.ids.contains(rival))
        #expect(server.deletions.count == 1)
    }

    @Test func aMissingSelfRepublishesTheBundleBeforeListingItself() async throws {
        let (encryption, server, client) = try setUp(interval: 0.01)
        defer { withExtendedLifetime(client) {} }
        let own = Int32(bitPattern: encryption.deviceId)
        let module = encryption.module
        server.setList([own])
        module.isPepAvailable = true
        await wait { module.isReady }
        try await Task.sleep(for: .milliseconds(100))

        // Another client dropped us and deleted our bundle. The server here
        // never has a bundle to read, so only a fresh look can find it gone.
        server.setList([rival])
        let before = server.events.count
        module.publishDeviceIdIfNeeded()
        await wait { server.events.count >= before + 2 }
        let after = Array(server.events.dropFirst(before))
        #expect(after.first == "bundle \(encryption.deviceId)", "the bundle must be there first: \(after)")
        #expect(after.dropFirst().first == "list")
        #expect(server.ids.contains(own))
    }

    @Test func twoClientsFightingOverTheListCantRewriteItAtNetworkSpeed() async throws {
        let (encryption, server, client) = try setUp(interval: 0.3)
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module
        server.setList([])
        // The other client takes us out of the list after each publish.
        server.afterPublish = { [rival] server in
            server.setList([rival])
            module.publishDeviceIdIfNeeded()
        }
        let start = Date()
        module.isPepAvailable = true
        // Waits for the count rather than sleeping a fixed time: under a
        // loaded test run the deferred publishes come late, not early.
        await wait({ server.listPublishes >= 4 }, seconds: 10)
        let elapsed = Date().timeIntervalSince(start)
        let publishes = server.listPublishes
        #expect(publishes >= 4, "it keeps trying, just slowly: \(server.events)")
        // One publish per 0.3 s at most, after the first.
        #expect(Double(publishes - 1) * 0.3 <= elapsed + 0.05, "\(publishes) publishes in \(elapsed) s")
    }
}

private final class Rounds: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(limit: Int) { left = limit }
    func next() -> Bool { lock.withLock { left -= 1; return left >= 0 } }
}
