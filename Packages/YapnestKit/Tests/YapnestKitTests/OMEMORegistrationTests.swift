import Foundation
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// A server that answers every pubsub request itself: nothing is published
/// yet, and the first `failingBundlePublishes` bundle publishes are refused.
private final class ScriptedServer: PacketWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var bundlePublishCount = 0
    private var listPublishCount = 0
    private var failures: Int
    /// A device list to hand out when it's read, if the server has one.
    var storedList: Element?

    init(failingBundlePublishes: Int) { failures = failingBundlePublishes }

    var bundlePublishes: Int { lock.withLock { bundlePublishCount } }
    var listPublishes: Int { lock.withLock { listPublishCount } }

    private func errorIq(_ condition: String) -> Iq {
        let iq = Iq()
        iq.type = .error
        let error = Element(name: "error", attributes: ["type": "cancel"])
        error.addChild(Element(name: condition, xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
        iq.addChild(error)
        return iq
    }

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {
        let pubsub = iq.firstChild(name: "pubsub")
        let node = (pubsub?.firstChild(name: "publish") ?? pubsub?.firstChild(name: "items"))?.attribute("node") ?? ""
        let isPublish = pubsub?.firstChild(name: "publish") != nil
        let refuse: Bool = lock.withLock {
            guard isPublish else { return false }
            if node.contains(".bundles:") {
                bundlePublishCount += 1
                if failures > 0 { failures -= 1; return true }
            } else {
                listPublishCount += 1
            }
            return false
        }
        let reply: Iq
        if refuse {
            reply = errorIq("service-unavailable")
        } else if isPublish {
            reply = Iq()
            reply.type = .result
        } else if node == OMEMOModule.DEVICES_LIST_NODE, let list = storedList {
            reply = Iq()
            reply.type = .result
            let item = Element(name: "item", attributes: ["id": "current"])
            item.addChild(list)
            let items = Element(name: "items", attributes: ["node": node])
            items.addChild(item)
            reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [items]))
        } else {
            reply = errorIq("item-not-found")
        }
        if reply.type == .result {
            completionHandler?(.success(reply))
        } else {
            completionHandler?(.failure(errorDecoder(reply) as! Failure))
        }
    }

    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

struct OMEMORegistrationTests {
    let me = JID("me@example.org")!

    private func setUp(failingBundlePublishes: Int, retryDelays: [TimeInterval] = [0.05]) throws -> (OMEMOEncryption, ScriptedServer, XMPPClient) {
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me)
        encryption.module.registrationRetryDelays = retryDelays
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        let server = ScriptedServer(failingBundlePublishes: failingBundlePublishes)
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

    @Test func aRefusedBundlePublishIsRetried() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 1)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        await wait { encryption.module.isReady }
        #expect(encryption.module.isReady)
        #expect(server.bundlePublishes >= 2, "refused once, then published")
        #expect(server.listPublishes == 1, "the device id goes out once the bundle is there")
    }

    @Test func retriesKeepGoingUntilItWorks() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 3)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        await wait { encryption.module.isReady }
        #expect(encryption.module.isReady)
        #expect(server.bundlePublishes >= 4)
        #expect(server.listPublishes == 1, "waiting registrations don't pile up")
    }

    @Test func noDeviceIdGoesOutWithoutABundle() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 100, retryDelays: [3600])
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        await wait { server.bundlePublishes >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!encryption.module.isReady)
        #expect(server.listPublishes == 0)
    }

    @Test func aResumedStreamRetriesWhenNotReady() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 1, retryDelays: [3600])
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        await wait { server.bundlePublishes >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!encryption.module.isReady)

        encryption.module.reset(scopes: [.stream])
        encryption.module.resumeRegistrationIfNeeded()
        await wait { encryption.module.isReady }
        #expect(encryption.module.isReady)
        #expect(server.bundlePublishes >= 2)
    }

    @Test func aResumedStreamDoesNothingWhenReady() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 0)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        await wait { encryption.module.isReady }
        // The device list step republishes the bundle, which this server
        // doesn't remember; let that settle before counting.
        try await Task.sleep(for: .milliseconds(100))
        let before = server.bundlePublishes
        encryption.module.resumeRegistrationIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.bundlePublishes == before)
    }

    @Test func retriesStopWhenTheSessionEnds() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 100)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        await wait { server.bundlePublishes >= 3 }
        encryption.module.reset(scopes: [.session])
        encryption.module.isPepAvailable = false
        try await Task.sleep(for: .milliseconds(100))
        let count = server.bundlePublishes
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.bundlePublishes == count)
    }

    @Test func listedWithoutABundleIsNotReady() async throws {
        let (encryption, server, client) = try setUp(failingBundlePublishes: 100, retryDelays: [3600])
        defer { withExtendedLifetime(client) {} }
        let list = Element(name: "list", xmlns: OMEMOModule.XMLNS)
        list.addChild(Element(name: "device", attributes: ["id": String(encryption.deviceId)]))
        server.storedList = list
        // The list already names us, as after an earlier session, while the
        // bundle can't be published.
        encryption.module.isPepAvailable = true
        encryption.module.publishDeviceIdIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!encryption.module.isReady)
    }
}
