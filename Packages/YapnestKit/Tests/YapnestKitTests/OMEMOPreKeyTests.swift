import Foundation
import GRDB
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// A server that keeps the bundle published to it and hands it back, as a real
/// one does, so a republish happens only if the bundle really changed.
private final class BundleServer: PacketWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var bundle: Element?
    private var count = 0

    var bundlePublishes: Int { lock.withLock { count } }
    var published: Element? { lock.withLock { bundle.map(Self.copy) } }
    var publishedPreKeyIds: [UInt32] {
        published?.firstChild(name: "prekeys")?.children.compactMap { $0.attribute("preKeyId").flatMap(UInt32.init) } ?? []
    }
    var publishedSignedPreKeyId: UInt32? {
        published?.firstChild(name: "signedPreKeyPublic")?.attribute("signedPreKeyId").flatMap(UInt32.init)
    }

    static func copy(_ element: Element) -> Element {
        let clone = Element(name: element.name, cdata: element.value, attributes: element.attributes)
        if let xmlns = element.xmlns { clone.xmlns = xmlns }
        element.children.forEach { clone.addChild(copy($0)) }
        return clone
    }

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {
        let pubsub = iq.firstChild(name: "pubsub")
        let publish = pubsub?.firstChild(name: "publish")
        let node = (publish ?? pubsub?.firstChild(name: "items"))?.attribute("node") ?? ""
        let reply = Iq()
        reply.type = .result
        if let publish {
            if node.contains(".bundles:") {
                lock.withLock {
                    count += 1
                    bundle = publish.firstChild(name: "item")?.firstChild(name: "bundle").map(Self.copy)
                }
            }
        } else if node.contains(".bundles:"), let stored = published {
            let item = Element(name: "item", attributes: ["id": "current"])
            item.addChild(stored)
            let items = Element(name: "items", attributes: ["node": node])
            items.addChild(item)
            reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [items]))
        } else {
            reply.type = .error
            let error = Element(name: "error", attributes: ["type": "cancel"])
            error.addChild(Element(name: "item-not-found", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
            reply.addChild(error)
            completionHandler?(.failure(errorDecoder(reply) as! Failure))
            return
        }
        completionHandler?(.success(reply))
    }

    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { date } }
    func advance(days: Double) { lock.withLock { date = date.addingTimeInterval(days * 86_400) } }
}

/// One-time and signed prekeys: a used one is gone at once, the bundle is
/// republished without it however the catch-up ends, and the signed one rotates.
struct OMEMOPreKeyTests {
    let me = JID("me@example.org")!
    let alice = "alice@example.org"
    let carol = "carol@example.org"

    private struct Sender {
        let cipher: SignalSessionCipher
        let deviceId: Int32
        let preKeyId: UInt32
    }

    private func setUp(clock: Clock = Clock()) async throws -> (OMEMOEncryption, BundleServer, XMPPClient, AppDatabase) {
        let database = try AppDatabase.inMemory()
        let encryption = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore(), now: { clock.now })
        encryption.module.registrationRetryDelays = [3600]
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        let server = BundleServer()
        client.writer = server
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        encryption.module.isPepAvailable = true
        await wait { encryption.module.isReady }
        #expect(encryption.module.isReady)
        return (encryption, server, client, database)
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Registers again, as a new connection does.
    private func register(_ encryption: OMEMOEncryption) async {
        encryption.module.reset(scopes: [.session])
        encryption.module.resumeRegistrationIfNeeded()
        await wait { encryption.module.isReady }
    }

    /// Someone who starts a session from the first prekey of `bundle`.
    private func sender(from bundle: Element, to bob: OMEMOEncryption, name: String) throws -> Sender {
        let parsed = try #require(OMEMOModule.OMEMOBundle(from: bundle))
        let other = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: JID(name)!, identityKeys: MemoryIdentityKeyStore())
        let context = other.module.signalContext
        let bobAddress = SignalAddress(name: me.description, deviceId: Int32(bitPattern: bob.deviceId))
        let preKey = try #require(parsed.preKeys.first)
        let signalBundle = try #require(SignalPreKeyBundle(registrationId: bob.deviceId, deviceId: bobAddress.deviceId, preKey: preKey, bundle: parsed))
        let builder = try #require(SignalSessionBuilder(withAddress: bobAddress, andContext: context))
        #expect(builder.processPreKeyBundle(bundle: signalBundle))
        let cipher = try #require(SignalSessionCipher(withAddress: bobAddress, andContext: context))
        return Sender(cipher: cipher, deviceId: Int32(bitPattern: other.deviceId), preKeyId: preKey.preKeyId)
    }

    /// The next message of `sender`'s session, which is a prekey message until Bob replies.
    private func nextKey(_ sender: Sender) throws -> SignalSessionCipher.Key {
        guard case .success(let key) = sender.cipher.encrypt(data: Data(repeating: 1, count: 32)) else { throw OMEMOError.keyGenerationFailed }
        #expect(key.prekey)
        return key
    }

    private func stanza(_ key: SignalSessionCipher.Key, device: Int32, to bob: OMEMOEncryption, from name: String) -> Martin.Message {
        let message = Message()
        message.type = .chat
        message.from = Martin.JID(name)
        let encrypted = Element(name: "encrypted", xmlns: OMEMOModule.XMLNS)
        let header = Element(name: "header")
        header.attribute("sid", newValue: String(device))
        let keyElement = Element(name: "key", cdata: key.key.base64EncodedString())
        keyElement.attribute("rid", newValue: String(bob.deviceId))
        keyElement.attribute("prekey", newValue: "true")
        header.addChild(keyElement)
        header.addChild(Element(name: "iv", cdata: Data(repeating: 2, count: 12).base64EncodedString()))
        encrypted.addChild(header)
        encrypted.addChild(Element(name: "payload", cdata: Data(repeating: 3, count: 8).base64EncodedString()))
        message.addChild(encrypted)
        return message
    }

    private func markedDeleted(_ database: AppDatabase) throws -> Int {
        try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM omemoPreKey WHERE isDeleted = 1") ?? 0 }
    }

    @Test func aUsedPreKeyCannotStartAnotherSessionButItsOwnSessionContinues() async throws {
        let (bob, server, client, _) = try await setUp()
        defer { withExtendedLifetime(client) {} }
        let bundle = try #require(server.published)
        let first = try sender(from: bundle, to: bob, name: alice)
        let stranger = try sender(from: bundle, to: bob, name: carol)
        #expect(first.preKeyId == stranger.preKeyId)

        // Two messages built from the same prekey, before any reply.
        let firstKey = try nextKey(first)
        let secondKey = try nextKey(first)
        bob.module.mamSyncStarted(for: nil)
        _ = bob.decrypt(stanza(firstKey, device: first.deviceId, to: bob, from: alice), from: JID(alice)!, ownCopy: false)
        #expect(!bob.store.containsPreKey(withId: first.preKeyId))
        #expect(bob.store.loadPreKey(withId: first.preKeyId) == nil, "gone while the flush still waits for the catch-up")

        let sameSession = try #require(SignalSessionCipher(withAddress: SignalAddress(name: alice, deviceId: first.deviceId), andContext: bob.module.signalContext))
        #expect((try? sameSession.decrypt(key: secondKey).get()) != nil, "the sender's next message, built from the same prekey, still decrypts")

        let strangerCipher = try #require(SignalSessionCipher(withAddress: SignalAddress(name: carol, deviceId: stranger.deviceId), andContext: bob.module.signalContext))
        #expect((try? strangerCipher.decrypt(key: try nextKey(stranger)).get()) == nil, "another sender can't use a prekey that was used")
        bob.module.mamSyncFinished(for: nil)
    }

    @Test func aResetStillTakesTheUsedPreKeyOutOfTheBundle() async throws {
        let (bob, server, client, database) = try await setUp()
        defer { withExtendedLifetime(client) {} }
        let first = try sender(from: try #require(server.published), to: bob, name: alice)
        #expect(server.publishedPreKeyIds.contains(first.preKeyId))
        let before = server.bundlePublishes

        bob.module.mamSyncStarted(for: nil)
        _ = bob.decrypt(stanza(try nextKey(first), device: first.deviceId, to: bob, from: alice), from: JID(alice)!, ownCopy: false)
        #expect(server.bundlePublishes == before, "the republish waits for the catch-up")
        #expect(try markedDeleted(database) == 1)

        bob.module.reset(scopes: [.stream])
        await wait { server.bundlePublishes > before }
        #expect(server.bundlePublishes == before + 1)
        #expect(!server.publishedPreKeyIds.contains(first.preKeyId))
        #expect(server.publishedPreKeyIds.count == 100)
        #expect(try markedDeleted(database) == 0)
    }

    @Test func aPreKeyLeftMarkedByAnExtensionIsRepublishedAtTheNextStart() async throws {
        let (bob, server, client, database) = try await setUp()
        defer { withExtendedLifetime(client) {} }
        let used = try #require(server.publishedPreKeyIds.first)
        #expect(bob.store.deletePreKey(withId: used))
        let before = server.bundlePublishes

        await register(bob)
        #expect(server.bundlePublishes == before + 1)
        #expect(!server.publishedPreKeyIds.contains(used))
        #expect(try markedDeleted(database) == 0)
    }

    @Test func theSignedPreKeyRotatesAndTheOldOneStaysForAGracePeriod() async throws {
        let clock = Clock()
        let (bob, server, client, _) = try await setUp(clock: clock)
        defer { withExtendedLifetime(client) {} }
        #expect(server.publishedSignedPreKeyId == 1)

        clock.advance(days: 6)
        await register(bob)
        #expect(server.publishedSignedPreKeyId == 1, "not before its week is out")

        clock.advance(days: 2)
        await register(bob)
        #expect(server.publishedSignedPreKeyId == 2)
        #expect(bob.store.loadSignedPreKey(withId: 1) != nil, "sessions started from the old bundle still work")
        #expect(bob.store.loadSignedPreKey(withId: 2) != nil)

        clock.advance(days: 20)
        await register(bob)
        #expect(bob.store.loadSignedPreKey(withId: 1) != nil, "20 days after it was replaced")

        clock.advance(days: 9)
        await register(bob)
        #expect(bob.store.loadSignedPreKey(withId: 1) == nil, "29 days after it was replaced")
        #expect(server.publishedSignedPreKeyId == 4, "ids don't repeat once old keys are deleted")
        #expect(bob.store.loadSignedPreKey(withId: 2) != nil, "replaced 9 days ago")
        #expect(bob.store.loadSignedPreKey(withId: 4) != nil)
    }
}
