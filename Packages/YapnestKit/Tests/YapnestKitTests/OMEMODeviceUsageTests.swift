import Foundation
import GRDB
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(days: Double) { lock.withLock { current = current.addingTimeInterval(days * 86400) } }
}

struct OMEMODeviceUsageTests {
    let me = JID("me@example.org")!
    let bob = "bob@example.org"
    let clock = TestClock()

    private func key(_ byte: UInt8) -> Data { Data([0x05] + Array(repeating: byte, count: 32)) }

    private func store(_ database: AppDatabase? = nil) throws -> OMEMOStore {
        let clock = clock
        return OMEMOStore(database: try database ?? AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore(), now: { clock.now })
    }

    /// Adds devices `ids` of `name` the way a first message does, with a session.
    private func add(_ ids: [Int32], of name: String? = nil, to store: OMEMOStore) {
        for id in ids {
            let address = SignalAddress(name: name ?? bob, deviceId: id)
            #expect(store.save(identity: address, publicKeyData: key(UInt8(id))))
            #expect(store.storeSessionRecord(Data([UInt8(id)]), forAddress: address))
        }
    }

    // MARK: Recording

    @Test func aDeviceIsFirstSeenWhenItsIdentityIsSaved() throws {
        let store = try store()
        add([1], to: store)
        #expect(store.usage(forName: bob)[1] == .init(firstSeen: clock.now, lastUsed: nil))
        clock.advance(days: 3)
        add([2], to: store)
        #expect(store.usage(forName: bob)[2]?.firstSeen == clock.now)
        #expect(store.usage(forName: bob)[1]?.firstSeen == clock.now.addingTimeInterval(-3 * 86400), "saving again doesn't move it")
    }

    @Test func lastUseOnlyMovesForwardAndNeverIntoTheFuture() throws {
        let store = try store()
        add([1], to: store)
        let day = clock.now.addingTimeInterval(-10 * 86400)
        store.noteUsed(name: bob, deviceId: 1, at: day)
        #expect(store.usage(forName: bob)[1]?.lastUsed == day)

        // Paging through older history.
        store.noteUsed(name: bob, deviceId: 1, at: day.addingTimeInterval(-86400))
        #expect(store.usage(forName: bob)[1]?.lastUsed == day)

        store.noteUsed(name: bob, deviceId: 1, at: clock.now.addingTimeInterval(86400 * 365))
        #expect(store.usage(forName: bob)[1]?.lastUsed == clock.now, "a date from the future is today")
    }

    @Test func aDeviceWithoutIdentityIsNotRecorded() throws {
        let store = try store()
        store.noteUsed(name: bob, deviceId: 9, at: clock.now)
        #expect(store.usage(forName: bob).isEmpty)
    }

    // MARK: The inactive rule

    @Test func aNewDeviceIsNotInactive() throws {
        let store = try store()
        add([1, 2], to: store)
        clock.advance(days: 89)
        #expect(store.excludingInactive([1, 2], of: bob) == [1, 2])
    }

    @Test func aDeviceThatNeverSentGoesInactiveAfterTheThreshold() throws {
        let store = try store()
        add([1, 2], to: store)
        clock.advance(days: 30)
        store.noteUsed(name: bob, deviceId: 1, at: clock.now)
        clock.advance(days: 61)
        // 1 wrote 61 days ago; 2 was first seen 91 days ago and never wrote.
        #expect(store.excludingInactive([1, 2], of: bob) == [1])
    }

    @Test func aDeviceWhoseLastMessageIsOldIsInactiveEvenIfItIsOldNews() throws {
        let store = try store()
        add([1, 2], to: store)
        store.noteUsed(name: bob, deviceId: 2, at: clock.now)
        clock.advance(days: 91)
        store.noteUsed(name: bob, deviceId: 1, at: clock.now)
        #expect(store.excludingInactive([1, 2], of: bob) == [1])
    }

    @Test func neverAllOfAContactsDevicesAreLeftOut() throws {
        let store = try store()
        add([1, 2], to: store)
        store.noteUsed(name: bob, deviceId: 1, at: clock.now)
        clock.advance(days: 200)
        #expect(store.excludingInactive([1, 2], of: bob) == [1, 2])
    }

    @Test func aMessageMakesADeviceActiveAgain() throws {
        let store = try store()
        add([1, 2], to: store)
        clock.advance(days: 50)
        store.noteUsed(name: bob, deviceId: 1, at: clock.now)
        clock.advance(days: 50)
        #expect(store.excludingInactive([1, 2], of: bob) == [1])
        store.noteUsed(name: bob, deviceId: 2, at: clock.now)
        #expect(store.excludingInactive([1, 2], of: bob) == [1, 2])
    }

    @Test func theThresholdIsExactlyNinetyDays() {
        let seen = Date(timeIntervalSince1970: 0)
        let ninety = seen.addingTimeInterval(90 * 86400)
        #expect(OMEMODevice.inactivityThreshold == 90 * 86400)
        #expect(!OMEMODevice.isInactive(firstSeen: seen, lastUsed: nil, now: ninety))
        #expect(OMEMODevice.isInactive(firstSeen: seen, lastUsed: nil, now: ninety.addingTimeInterval(1)))
    }

    @Test func aDeviceNeverSeenSendingIsInactiveOnlyAfterItsGracePeriod() {
        let now = clock.now
        func device(first: Double, used: Double?) -> OMEMODevice {
            OMEMODevice(jid: JID("me@example.org")!, id: 1, fingerprint: "", trust: .trusted, isActive: true,
                        firstSeen: now.addingTimeInterval(-first * 86400), lastUsed: used.map { now.addingTimeInterval(-$0 * 86400) })
        }
        #expect(!device(first: 2, used: nil).isInactive(now: now), "new, so \"Remove unused\" leaves it and its trust alone")
        #expect(device(first: 200, used: nil).isInactive(now: now))
        #expect(device(first: 200, used: 91).isInactive(now: now))
        #expect(!device(first: 200, used: 89).isInactive(now: now))
    }

    // MARK: Our own devices

    @Test func ourOwnQuietDevicesAreLeftOutEvenIfAllAre() throws {
        let store = try store()
        add([1, 2], of: me.description, to: store)
        #expect(Set(store.ownDevicesToEncryptTo()) == [1, 2])
        store.noteUsed(name: me.description, deviceId: 1, at: clock.now)
        clock.advance(days: 100)
        #expect(store.ownDevicesToEncryptTo().isEmpty, "we have the plaintext ourselves, so no fallback")
        store.noteUsed(name: me.description, deviceId: 2, at: clock.now)
        #expect(store.ownDevicesToEncryptTo() == [2])
    }

    @Test func ourOwnDevicesStayUntrustedOrRemovedWhenFresh() throws {
        let store = try store()
        add([1, 2, 3], of: me.description, to: store)
        #expect(store.setStatus(.undecidedActive, forIdentity: SignalAddress(name: me.description, deviceId: 2)))
        #expect(store.setStatus(active: false, forIdentity: SignalAddress(name: me.description, deviceId: 3)))
        #expect(store.ownDevicesToEncryptTo() == [1])
    }

    @Test func forgettingDevicesDropsTheirSessionsAndIdentities() throws {
        let store = try store()
        add([1, 2], of: me.description, to: store)
        store.forget(deviceIds: [1], of: me.description)
        #expect(store.identities(forName: me.description).map(\.address.deviceId) == [2])
        #expect(store.allDevices(for: me.description, activeAndTrusted: false) == [2])
    }

    // MARK: Migration

    @Test func existingDevicesStartTheirGracePeriodAndKeepWhatMessagesShow() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v20-added-by-user")
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES (?, 'chat', 0)", arguments: [bob])
            for (device, date) in [(1, last.addingTimeInterval(-500)), (1, last), (2, last.addingTimeInterval(-9))] as [(Int, Date)] {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, omemoDevice)
                    VALUES (1, 'incoming', ?, 'hi', ?, 'received', 0, 'omemo', ?)
                    """, arguments: [bob, date, device])
            }
            // A message of ours, with no sending device.
            try db.execute(sql: """
                INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption)
                VALUES (1, 'outgoing', 'me@example.org', 'yo', ?, 'sent', 1, 'omemo')
                """, arguments: [last.addingTimeInterval(5000)])
            for device in 1...3 {
                try db.execute(sql: "INSERT INTO omemoIdentity (name, deviceId, key, status) VALUES (?, ?, ?, 1)", arguments: [bob, device, Data([UInt8(device)])])
            }
        }
        let before = Date()
        try AppDatabase.migrator.migrate(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT deviceId, firstSeen, lastUsed FROM omemoIdentity ORDER BY deviceId")
        }
        #expect(rows.map { $0["deviceId"] as Int } == [1, 2, 3])
        #expect(rows.map { $0["lastUsed"] as Date? } == [last, last.addingTimeInterval(-9), nil])
        for row in rows {
            let first = try #require(row["firstSeen"] as Date?)
            #expect(first >= before.addingTimeInterval(-1) && first <= Date().addingTimeInterval(1))
        }
    }

    // MARK: Decrypting

    private func setUp() throws -> (OMEMOEncryption, XMPPClient) {
        let clock = clock
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore(), now: { clock.now })
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = SilentWriter()
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        return (encryption, client)
    }

    /// A message from `device` that can't be decrypted, for lack of a session.
    private func undecryptable(from device: Int32, to encryption: OMEMOEncryption) -> Martin.Message {
        let message = Message()
        message.type = .chat
        message.from = Martin.JID(bob)
        let encrypted = Element(name: "encrypted", xmlns: OMEMOModule.XMLNS)
        let header = Element(name: "header")
        header.attribute("sid", newValue: String(device))
        let key = Element(name: "key", cdata: OMEMOHealingTests.whisperMessage.base64EncodedString())
        key.attribute("rid", newValue: String(encryption.deviceId))
        header.addChild(key)
        header.addChild(Element(name: "iv", cdata: Data(repeating: 2, count: 12).base64EncodedString()))
        encrypted.addChild(header)
        encrypted.addChild(Element(name: "payload", cdata: Data(repeating: 3, count: 8).base64EncodedString()))
        message.addChild(encrypted)
        return message
    }

    @Test func aMessageWeCouldntReadStillCountsAsTheDeviceBeingUsed() throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        add([7], to: encryption.store)
        clock.advance(days: 2)
        guard case .failed = encryption.decrypt(undecryptable(from: 7, to: encryption), from: JID(bob)!, ownCopy: false, sentAt: clock.now) else {
            Issue.record("expected the message to fail to decrypt")
            return
        }
        #expect(encryption.store.usage(forName: bob)[7]?.lastUsed == clock.now)
    }

    @Test func aDeviceMarkedCompromisedIsStillSeenSending() throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        add([7], to: encryption.store)
        let status = try #require(encryption.store.identities(forName: bob).first?.status)
        _ = encryption.store.setStatus(status.toTrust(.compromised), forIdentity: SignalAddress(name: bob, deviceId: 7))
        _ = encryption.decrypt(undecryptable(from: 7, to: encryption), from: JID(bob)!, ownCopy: false, sentAt: clock.now)
        #expect(encryption.store.usage(forName: bob)[7]?.lastUsed == clock.now)
    }

    @Test func anArchivedMessageIsFromItsOwnDay() throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        add([7], to: encryption.store)
        let sent = clock.now.addingTimeInterval(-120 * 86400)
        _ = encryption.decrypt(undecryptable(from: 7, to: encryption), from: JID(bob)!, ownCopy: false, isHistory: true, sentAt: sent)
        #expect(encryption.store.usage(forName: bob)[7]?.lastUsed == sent)
        #expect(encryption.store.excludingInactive([7], of: bob) == [7], "the only device is kept")
    }

    @Test func archiveTimesComeFromTheArchiveAndOthersAreNow() {
        let day = Date(timeIntervalSince1970: 5)
        #expect(InboundMessage.Source.archive(serverId: "s", timestamp: day).archivedAt == day)
        #expect(InboundMessage.Source.archive(serverId: "s", timestamp: nil).archivedAt == nil)
        #expect(InboundMessage.Source.live.archivedAt == nil)
        #expect(InboundMessage.Source.carbon(sent: false).archivedAt == nil)
    }

    // MARK: Removing our own devices

    @Test func removingDevicesRepublishesTheListWithoutThemAndKeepsOurs() async throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        let server = ListServer()
        client.writer = server
        let own = Int32(bitPattern: encryption.deviceId)
        server.storedList = ListServer.list([own, 11, 12, 13])
        encryption.module.isPepAvailable = true
        await server.waitUntil { encryption.module.isReady }

        let result = await remove([11, 13], with: encryption)
        guard case .success = result else { Issue.record("removal failed: \(result)"); return }
        #expect(Set(server.publishedList) == [own, 12], "\(server.publishedList) \(server.deletedBundles)")
        #expect(Set(server.deletedBundles) == [11, 13])
    }

    @Test func ourOwnDeviceIsNeverRemoved() async throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        let server = ListServer()
        client.writer = server
        let own = Int32(bitPattern: encryption.deviceId)
        server.storedList = ListServer.list([own, 11])
        encryption.module.isPepAvailable = true
        await server.waitUntil { encryption.module.isReady }

        let result = await remove([own, 11], with: encryption)
        guard case .success = result else { Issue.record("removal failed: \(result)"); return }
        #expect(Set(server.publishedList) == [own])
        #expect(server.deletedBundles == [11], "our own bundle stays")
    }

    @Test func aRefusedPublishIsReported() async throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        let server = ListServer()
        client.writer = server
        server.storedList = ListServer.list([Int32(bitPattern: encryption.deviceId), 11])
        encryption.module.isPepAvailable = true
        await server.waitUntil { encryption.module.isReady }

        server.refuseListPublishes = true
        let result = await remove([11], with: encryption)
        guard case .failure = result else { Issue.record("expected the refusal to be reported"); return }
    }

    @Test func aListThatCantBeReadIsReported() async throws {
        let (encryption, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        let server = ListServer()
        client.writer = server
        server.storedList = ListServer.list([Int32(bitPattern: encryption.deviceId), 11])
        encryption.module.isPepAvailable = true
        await server.waitUntil { encryption.module.isReady }

        server.refuseListReads = true
        let result = await remove([11], with: encryption)
        guard case .failure = result else { Issue.record("expected the failed read to be reported"); return }
    }

    private func remove(_ ids: [Int32], with encryption: OMEMOEncryption) async -> Result<Void, PubSubError> {
        await withCheckedContinuation { continuation in
            encryption.module.removeDevices(withIds: ids) { continuation.resume(returning: $0) }
        }
    }
}

private final class SilentWriter: PacketWriter, @unchecked Sendable {
    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

/// A server with our device list on it, which remembers what is published.
private final class ListServer: PacketWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var list: Element?
    private var deleted: [Int32] = []
    private var refusePublish = false
    private var refuseRead = false

    var storedList: Element? {
        get { lock.withLock { list } }
        set { lock.withLock { list = newValue } }
    }
    var refuseListPublishes: Bool {
        get { lock.withLock { refusePublish } }
        set { lock.withLock { refusePublish = newValue } }
    }
    var refuseListReads: Bool {
        get { lock.withLock { refuseRead } }
        set { lock.withLock { refuseRead = newValue } }
    }
    var deletedBundles: [Int32] { lock.withLock { deleted } }
    var publishedList: [Int32] {
        lock.withLock { list }?.mapChildren(transform: { $0.getAttribute("id") }).compactMap { Int32($0) } ?? []
    }

    static func list(_ ids: [Int32]) -> Element {
        let list = Element(name: "list", xmlns: OMEMOModule.XMLNS)
        for id in ids { list.addChild(Element(name: "device", attributes: ["id": String(id)])) }
        return list
    }

    func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

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
        let publish = pubsub?.firstChild(name: "publish")
        let items = pubsub?.firstChild(name: "items")
        let reply: Iq
        if let delete = iq.firstChild(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")?.firstChild(name: "delete"),
           let node = delete.attribute("node"), let id = node.split(separator: ":").last.flatMap({ Int32($0) }) {
            lock.withLock { deleted.append(id) }
            reply = Iq()
            reply.type = .result
        } else if let publish {
            let isList = publish.attribute("node") == OMEMOModule.DEVICES_LIST_NODE
            let refuse = lock.withLock { isList && refusePublish }
            if refuse {
                reply = errorIq("service-unavailable")
            } else {
                if isList, let payload = publish.firstChild(name: "item")?.firstChild(name: "list") {
                    lock.withLock { list = payload }
                }
                reply = Iq()
                reply.type = .result
            }
        } else if let items, items.attribute("node") == OMEMOModule.DEVICES_LIST_NODE, let list = storedList, !lock.withLock({ refuseRead }) {
            reply = Iq()
            reply.type = .result
            let item = Element(name: "item", attributes: ["id": "current"])
            item.addChild(list)
            let node = Element(name: "items", attributes: ["node": OMEMOModule.DEVICES_LIST_NODE])
            node.addChild(item)
            reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [node]))
        } else if lock.withLock({ refuseRead }) && items != nil || items?.attribute("node")?.contains(".bundles:") == true {
            // Other devices' bundles can't be had; a missing one would have
            // them dropped from the list as broken, which isn't what's tested.
            reply = errorIq("service-unavailable")
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
