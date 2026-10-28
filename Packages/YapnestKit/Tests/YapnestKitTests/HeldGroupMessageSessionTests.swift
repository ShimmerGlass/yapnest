import Foundation
import GRDB
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let bob = YapnestKit.JID("bob@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
/// The device the room says Bob's message came from.
private let named: Int32 = 777

/// A device of another account that writes to ours for real, so that what
/// decoding a prekey message stores can be seen.
final class OtherDevice {
    let omemo: OMEMOEncryption
    private let client = XMPPClient()

    init(account: YapnestKit.JID) throws {
        omemo = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: account, identityKeys: MemoryIdentityKeyStore())
        // The module encodes only once it's registered with a client.
        client.connectionConfiguration.userJid = BareJID(account.description)
        client.writer = FakeWire()
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(omemo.module)
    }

    var device: Int32 { Int32(bitPattern: omemo.deviceId) }
    /// As its bundle publishes it.
    var identityKey: Data { omemo.module.storage.identityKeyStore.keyPair()!.publicKey! }

    /// The `<encrypted>` element of `body`, for `recipient`'s device alone,
    /// from a session started with a bundle of that device's keys.
    func encrypt(_ body: String, to recipient: XMPPSession) throws -> Element {
        let context = recipient.omemo.module.signalContext, storage = recipient.omemo.module.storage
        let pair = try #require(storage.identityKeyStore.keyPair())
        let signed = try #require(context.generateSignedPreKey(withIdentity: pair, signedPreKeyId: 4242))
        let signedData = try #require(signed.serializedData), signedPublic = try #require(signed.publicKeyData)
        _ = storage.signedPreKeyStore.storeSignedPreKey(signedData, withId: signed.preKeyId)
        let preKey = try #require(context.generatePreKeys(withStartingPreKeyId: 4242, count: 1).first)
        let preKeyData = try #require(preKey.serializedData), preKeyPublic = try #require(preKey.serializedPublicKey)
        _ = storage.preKeyStore.storePreKey(preKeyData, withId: preKey.preKeyId)
        let identityPublic = try #require(pair.publicKey)
        let preKeyElement = Element(name: "preKeyPublic", cdata: preKeyPublic.base64EncodedString(), attributes: ["preKeyId": String(preKey.preKeyId)])
        let bundle = Element(name: "bundle", xmlns: OMEMOModule.XMLNS, children: [
            Element(name: "signedPreKeyPublic", cdata: signedPublic.base64EncodedString(), attributes: ["signedPreKeyId": String(signed.preKeyId)]),
            Element(name: "signedPreKeySignature", cdata: signed.signature.base64EncodedString()),
            Element(name: "identityKey", cdata: identityPublic.base64EncodedString()),
            Element(name: "prekeys", children: [preKeyElement]),
        ])
        let address = SignalAddress(name: recipient.account.description, deviceId: Int32(bitPattern: recipient.omemo.deviceId))
        let parsedPreKey = try #require(OMEMOModule.OMEMOPreKey(from: preKeyElement))
        let parsedBundle = try #require(OMEMOModule.OMEMOBundle(from: bundle))
        let keys = try #require(SignalPreKeyBundle(registrationId: 0, deviceId: address.deviceId, preKey: parsedPreKey, bundle: parsedBundle))
        let builder = try #require(SignalSessionBuilder(withAddress: address, andContext: omemo.module.signalContext))
        #expect(builder.processPreKeyBundle(bundle: keys))
        let message = Martin.Message()
        message.body = body
        var encrypted: Element?
        omemo.module.encode(message: message, forAddresses: [address], withStoreHint: false, forSelf: false) { result in
            if case .successMessage(let message, _) = result { encrypted = message.firstChild(name: "encrypted", xmlns: NS.omemoLegacy) }
        }
        return try #require(encrypted)
    }
}

/// A room names each encrypted message's sender, so a device we've never
/// seen counts only once its sender's own server lists it.
struct HeldGroupMessageSessionTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        // First: a new connection starts the rooms over.
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = false
        status.catchUpReachedEnd = true
        session.updateRoom(room) { $0 = status }
        session.roomPresence(parseStanza("""
            <presence from='\(room)/Bob' to='me@example.org/t'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' jid='bob@example.org/phone'/></x></presence>
            """), room: room)
        session.applyOccupantChanges()
    }

    private enum DeviceList {
        case ids([Int32])
        /// An error's condition and type.
        case error(String, String)
    }

    /// Bob's server: his device list and bundles, or an error for either.
    private func bobsServer(list: DeviceList, identityKey: Data? = nil) {
        wire.answer { iq in
            guard iq.to?.bareJid.stringValue == bob.description,
                  let node = iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") else { return nil }
            if node == OMEMOModule.DEVICES_LIST_NODE {
                switch list {
                case .ids(let ids): return OMEMODeviceListTests.list(ids, to: iq)
                case .error(let condition, let type): return FakeWire.error(to: iq, condition: condition, type: type)
                }
            }
            guard let identityKey else { return FakeWire.error(to: iq) }
            let bundle = Element(name: "bundle", xmlns: OMEMOModule.XMLNS)
            bundle.addChild(Element(name: "identityKey", cdata: identityKey.base64EncodedString()))
            let item = Element(name: "item", attributes: ["id": "current"])
            item.addChild(bundle)
            let items = Element(name: "items", attributes: ["node": node])
            items.addChild(item)
            let reply = Iq()
            reply.type = .result
            reply.id = iq.id
            reply.from = iq.to
            reply.addChild(Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [items]))
            return reply
        }
    }

    /// A prekey message for this device from `named`, which no session can read.
    private func bobSays(_ id: String, device: Int32 = named) {
        session.handleRoomStanza(parseStanza("""
            <message from='\(room)/Bob' type='groupchat' id='\(id)'><encrypted xmlns='eu.siacs.conversations.axolotl'>\
            <header sid='\(device)'><key rid='\(session.omemo.deviceId)' prekey='true'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header>\
            <payload>AAAA</payload></encrypted><body>fallback</body></message>
            """), source: .live)
    }

    /// What a device of the room's own writes to us as Bob's, which would
    /// read as his if decoded.
    private func roomSays(_ id: String, _ body: String, from device: OtherDevice) throws {
        let stanza: Martin.Message = parseStanza("<message from='\(room)/Bob' type='groupchat' id='\(id)'><body>fallback</body></message>")
        stanza.addChild(try device.encrypt(body, to: session))
        session.handleRoomStanza(stanza, source: .live)
    }

    private func identity(of device: OtherDevice) -> Row? {
        try? database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT key, status FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [bob.description, device.device])
        }
    }

    private var listRequests: Int {
        wire.written.count { ($0 as? Iq)?.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE }
    }

    private var held: [HeldGroupMessage] { (try? database.heldGroupMessages()) ?? [] }

    private var bobsIdentity: Data? {
        try? database.reader.read { db in
            try Data.fetchOne(db, sql: "SELECT key FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [bob.description, named])
        }
    }

    private func copies(_ id: String) -> Int {
        (try? database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == id).fetchCount($0) }) ?? -1
    }

    private var events: Int {
        (try? database.reader.read { try YapnestKit.Message.filter(Column("event") != nil).fetchCount($0) }) ?? -1
    }

    private func stored(_ id: String) throws -> YapnestKit.Message {
        try #require(try database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == id).fetchOne($0) })
    }

    private func requested(_ node: String) -> Bool {
        wire.written.contains { ($0 as? Iq)?.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == node }
    }

    @Test func aRoomCantPassOffADeviceOfItsOwnAsAMembers() async throws {
        let rogue = try OtherDevice(account: bob)
        bobsServer(list: .ids([111]))

        try roomSays("g1", "send me your password", from: rogue)
        await eventually("the hold to be dropped") { held.isEmpty && requested(OMEMOModule.DEVICES_LIST_NODE) }

        let message = try stored("g1")
        #expect(message.encryption == .omemoUndecryptable)
        #expect(message.body == "fallback")
        #expect(message.sender == bob)
        #expect(identity(of: rogue) == nil, "the room's key for the device was stored")
        #expect(events == 0, "a new device was announced")
    }

    @Test func aDeviceBobListsIsReadInPlaceOfItsPlaceholder() async throws {
        let device = try OtherDevice(account: bob)
        bobsServer(list: .ids([111, device.device]), identityKey: device.identityKey)

        try roomSays("g1", "cake at four", from: device)
        await eventually("the message to be read") { (try? stored("g1").encryption) == .omemo }

        let message = try stored("g1")
        #expect(message.body == "cake at four")
        #expect(message.sender == bob)
        #expect(message.omemoDevice == device.device)
        #expect(held.isEmpty)
        #expect(copies("g1") == 1)
        #expect((identity(of: device)?["key"] as Data?) == device.identityKey)
    }

    @Test func aDeviceBobListsUnderAnotherKeyStaysUnread() async throws {
        let rogue = try OtherDevice(account: bob)
        let published = Data([0x05] + [UInt8](repeating: 7, count: 32))
        bobsServer(list: .ids([rogue.device]), identityKey: published)

        try roomSays("g1", "send me your password", from: rogue)
        await eventually("the hold to be dropped") { held.isEmpty && identity(of: rogue) != nil }

        #expect(try stored("g1").encryption == .omemoUndecryptable)
        #expect((identity(of: rogue)?["key"] as Data?) == published)
    }

    @Test func aListBobsServerWontShowIsReadOnTheRoomsWordFromAnUndecidedDevice() async throws {
        let device = try OtherDevice(account: bob)
        bobsServer(list: .error("forbidden", "auth"))

        try roomSays("g1", "cake at four", from: device)
        await eventually("the message to be read") { (try? stored("g1").encryption) == .omemo }

        let message = try stored("g1")
        #expect(message.body == "cake at four")
        #expect(message.omemoTrust == .undecided)
        #expect((identity(of: device)?["status"] as Int?) == IdentityStatus.undecidedActive.rawValue)
        #expect(!requested("eu.siacs.conversations.axolotl.bundles:\(device.device)"))
    }

    @Test func aDeviceItsServerVouchedForIsReadAtOnceAfterwards() async throws {
        let device = try OtherDevice(account: bob)
        bobsServer(list: .ids([device.device]), identityKey: device.identityKey)
        try roomSays("g1", "first", from: device)
        await eventually("the first message to be read") { (try? stored("g1").encryption) == .omemo }

        try roomSays("g2", "second", from: device)

        #expect(try stored("g2").body == "second")
        #expect(held.isEmpty)
    }

    @Test func aBareKeyInABundleIsReadAsLibsignalWritesIt() async throws {
        let bare = Data(repeating: 9, count: 32)
        bobsServer(list: .ids([named]), identityKey: bare)

        bobSays("g1")
        await eventually("Bob's key to be kept") { bobsIdentity != nil }

        #expect(bobsIdentity == Data([0x05]) + bare)
    }

    @Test func aServerThatDoesntAnswerInTimeKeepsTheMessageHeld() async throws {
        bobsServer(list: .error("remote-server-timeout", "wait"))

        bobSays("g1")
        await eventually("the list to be asked for") { requested(OMEMOModule.DEVICES_LIST_NODE) }
        try await Task.sleep(for: .milliseconds(200))

        #expect(held.map(\.messageId) == [try stored("g1").id])
        #expect(bobsIdentity == nil)
    }

    @Test func aListBobsServerWontShowIsReadOnTheRoomsWordAlone() async throws {
        bobsServer(list: .error("forbidden", "auth"))

        bobSays("g1")
        await eventually("the hold to be dropped") { held.isEmpty && requested(OMEMOModule.DEVICES_LIST_NODE) }

        // Decoding was tried, with nothing a session could read.
        #expect(try stored("g1").encryption == .omemoUndecryptable)
        #expect(!requested("eu.siacs.conversations.axolotl.bundles:\(named)"))
    }

    @Test func theDevicesMessagesWaitForOneCheck() async throws {
        bobsServer(list: .error("remote-server-timeout", "wait"))

        bobSays("g1")
        bobSays("g2")
        await eventually("the list to be asked for") { requested(OMEMOModule.DEVICES_LIST_NODE) }

        #expect(held.count == 2)
        #expect(held.allSatisfy { $0.sender == bob && $0.deviceId == named })
    }

    @Test func aDeviceWeKnowIsReadAtOnce() throws {
        let key = Data([0x05] + [UInt8](repeating: 3, count: 32))
        #expect(session.omemo.vouch(for: named, of: bob, identityKey: key))

        bobSays("g1")

        #expect(held.isEmpty)
        #expect(!requested(OMEMOModule.DEVICES_LIST_NODE))
    }

    @Test func itsCopyArrivingDecryptedWhileHeldTakesThePlaceholdersPlace() async throws {
        let device = try OtherDevice(account: bob)
        bobsServer(list: .error("remote-server-timeout", "wait"))
        let stanza: Martin.Message = parseStanza("<message from='\(room)/Bob' type='groupchat' id='g1'><body>fallback</body></message>")
        stanza.addChild(try device.encrypt("cake at four", to: session))
        let copy = stanza.element.stringValue
        session.handleRoomStanza(stanza, source: .live)
        await eventually("the list to be asked for") { requested(OMEMOModule.DEVICES_LIST_NODE) }
        // Vouched for meanwhile, as when the run is between its steps.
        #expect(session.omemo.vouch(for: device.device, of: bob, identityKey: device.identityKey))

        session.handleRoomStanza(parseStanza(copy), source: .live)

        let message = try stored("g1")
        #expect(message.encryption == .omemo)
        #expect(message.body == "cake at four")
        #expect(held.isEmpty)
        #expect(copies("g1") == 1)
    }

    @Test func aHoldWhoseServerNeverAnswersIsGivenUpInTheEnd() async throws {
        bobsServer(list: .error("remote-server-timeout", "wait"))
        bobSays("g1")
        await eventually("the list to be asked for") { requested(OMEMOModule.DEVICES_LIST_NODE) }
        let asked = listRequests
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE heldGroupMessage SET heldAt = ?", arguments: [Date().addingTimeInterval(-XMPPSession.heldMessageLifetime - 60)])
        }

        session.resolveHeldGroupMessages()
        await eventually("the hold to be given up") { held.isEmpty && listRequests > asked }

        #expect(try stored("g1").encryption == .omemoUndecryptable)
    }

    @Test func manyDevicesNamedForOneMemberCostOneReadOfTheirList() async throws {
        bobsServer(list: .error("remote-server-timeout", "wait"))
        for (index, device) in [Int32(701), 702, 703].enumerated() { bobSays("g\(index)", device: device) }
        await eventually("the holds to be kept") { held.count == 3 }
        try await Task.sleep(for: .milliseconds(200))
        let asked = listRequests
        bobsServer(list: .ids([111]))

        session.resolveHeldGroupMessages()
        await eventually("the holds to be dropped") { held.isEmpty }

        #expect(listRequests == asked + 1)
    }

    @Test func aPreKeyBehindAnotherKeyForUsIsStillHeld() throws {
        session.handleRoomStanza(parseStanza("""
            <message from='\(room)/Bob' type='groupchat' id='g1'><encrypted xmlns='eu.siacs.conversations.axolotl'>\
            <header sid='\(named)'><key rid='\(session.omemo.deviceId)'>AAAA</key>\
            <key rid='\(session.omemo.deviceId)' prekey='true'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header>\
            <payload>AAAA</payload></encrypted><body>fallback</body></message>
            """), source: .live)

        #expect(held.count == 1)
    }

    @Test func aKeyTransportFromADeviceWeDontKnowIsLeftAlone() throws {
        session.handleRoomStanza(parseStanza("""
            <message from='\(room)/Bob' type='groupchat' id='g1'><encrypted xmlns='eu.siacs.conversations.axolotl'>\
            <header sid='\(named)'><key rid='\(session.omemo.deviceId)' prekey='true'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header>\
            </encrypted></message>
            """), source: .live)

        #expect(held.isEmpty)
        #expect(copies("g1") == 0)
        #expect(bobsIdentity == nil)
    }

    @Test func aReadNoAnswerEverComesToEndsTheRunAndTheNextOneTriesAgain() async throws {
        session.omemo.heldReadTimeout = 0.2
        wire.answer { _ in nil }
        bobSays("g1")
        await eventually("the list to be asked for") { requested(OMEMOModule.DEVICES_LIST_NODE) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(held.count == 1)
        let asked = listRequests
        bobsServer(list: .ids([111]))

        session.resolveHeldGroupMessages()

        await eventually("the next run to drop the hold") { held.isEmpty && listRequests > asked }
    }

    @Test func aMessageWithNoPreKeyForUsIsNotHeld() throws {
        session.handleRoomStanza(parseStanza("""
            <message from='\(room)/Bob' type='groupchat' id='g1'><encrypted xmlns='eu.siacs.conversations.axolotl'>\
            <header sid='\(named)'><key rid='\(session.omemo.deviceId &+ 1)' prekey='true'>AAAA</key>\
            <key rid='\(session.omemo.deviceId)'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header>\
            <payload>AAAA</payload></encrypted><body>fallback</body></message>
            """), source: .live)

        #expect(held.isEmpty)
        #expect(!requested(OMEMOModule.DEVICES_LIST_NODE))
    }

    @Test func ourOwnMessageFromBeforeThisDeviceIsStillOursAndNotShown() throws {
        session.handleRoomStanza(parseStanza("""
            <message from='\(room)/me' type='groupchat' id='g1'><encrypted xmlns='eu.siacs.conversations.axolotl'>\
            <header sid='\(named)'><key rid='\(session.omemo.deviceId &+ 1)' prekey='true'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header>\
            <payload>AAAA</payload></encrypted><body>fallback</body></message>
            """), source: .live)

        #expect(held.isEmpty)
        #expect(copies("g1") == 0)
    }

    @Test func onlyARoomsClaimIsHeldBack() throws {
        let stanza: Martin.Message = parseStanza("""
            <message from='bob@example.org/phone' type='chat' id='c1'><encrypted xmlns='eu.siacs.conversations.axolotl'>\
            <header sid='\(named)'><key rid='\(session.omemo.deviceId)' prekey='true'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header>\
            <payload>AAAA</payload></encrypted></message>
            """)
        let copy: Martin.Message = parseStanza(stanza.element.stringValue)

        if case .unvouched = session.omemo.decrypt(stanza, from: bob, ownCopy: false) { Issue.record("a chat message was held") }
        guard case .unvouched(let device) = session.omemo.decrypt(copy, from: bob, ownCopy: false, claim: .room) else {
            Issue.record("a room's claim was decoded")
            return
        }
        #expect(device == named)
        #expect(bobsIdentity == nil)
    }
}
