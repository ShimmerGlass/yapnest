import Combine
import Foundation
import GRDB
import Synchronization
@preconcurrency import Martin
@testable import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let bob = YapnestKit.JID("bob@example.org")!
private let carol = YapnestKit.JID("carol@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// A new device is invisible to members who don't have us as a contact, so
/// the first time it is in an encrypted private group it writes there: a
/// message of keys and nothing to show, to each member until the room has
/// echoed one back.
final class IntroductionHarness: @unchecked Sendable {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let bobsPhone: OtherDevice
    let carolsPhone: OtherDevice
    let events = Mutex<[XMPPSession.Event]>([])
    /// The members whose server lists their phone.
    let listed: Mutex<Set<YapnestKit.JID>>
    private var subscription: AnyCancellable?
    private let listsMembers: Bool
    private let members: [YapnestKit.JID]

    /// - Parameters:
    ///   - members: the members besides us.
    ///   - listed: those of them whose server lists a device (their phone).
    init(
        mode: XMPPSession.Mode = .app, isMembersOnly: Bool = true, isNonAnonymous: Bool = true,
        isEncrypted: Bool = true, members: [YapnestKit.JID] = [bob], withDevices listed: Set<YapnestKit.JID> = [bob],
    ) async throws {
        listsMembers = isNonAnonymous
        self.members = members
        self.listed = Mutex(listed)
        database = try AppDatabase.inMemory()
        bobsPhone = try OtherDevice(account: bob)
        carolsPhone = try OtherDevice(account: carol)
        session = try makeSession(me, database: database, mode: mode)
        subscription = session.events.sink { [weak self] event in self?.events.withLock { $0.append(event) } }
        session.connectForTesting(wire)
        let phones = [bob.description: bobsPhone.device, carol.description: carolsPhone.device]
        wire.answer { [weak self] iq in
            guard let node = iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") else {
                // Publishing our own keys and any other request.
                return FakeWire.result(to: iq)
            }
            if node == OMEMOModule.DEVICES_LIST_NODE, let to = iq.to?.bareJid.stringValue, let phone = phones[to],
               self?.listed.withLock({ $0.contains { $0.description == to } }) == true {
                return OMEMODeviceListTests.list([phone], to: iq)
            }
            return FakeWire.error(to: iq)
        }
        session.omemoModuleForTesting.isPepAvailable = true
        // An extension's session doesn't publish keys, so it never gets ready.
        if mode == .app { await eventually("our device to be ready") { self.session.omemoModuleForTesting.isReady } }

        try database.joinGroupChat(room, nickname: "me")
        try database.setRoomInfo(room, name: nil, isMembersOnly: isMembersOnly, isNonAnonymous: isNonAnonymous)
        if !isEncrypted { try database.setEncrypted(false, with: room) }
        session.reloadKnownRooms()
        setUpRoom()
        try establishSession(with: bobsPhone, named: bob)
        try establishSession(with: carolsPhone, named: carol)
    }

    func setUpRoom() {
        session.updateRoom(room) { status in
            var joined = RoomStatus(phase: .joined, nickname: "me")
            for member in members { joined.setAffiliation(.member, of: member) }
            status = joined
        }
    }

    func addMember(_ member: YapnestKit.JID) {
        session.updateRoom(room) { $0?.setAffiliation(.member, of: member) }
    }

    /// A trusted session with the device, as one made from its published bundle.
    @discardableResult
    func establishSession(with device: OtherDevice, named name: YapnestKit.JID) throws -> SignalAddress {
        let address = try startSession(from: session.omemo, to: device.omemo, named: name.description, keyId: 77)
        #expect(session.omemoStoreForTesting.setStatus(.trustedActive, forIdentity: address))
        return address
    }

    /// The room joined again, with its catch-up and member lists, as every
    /// reconnect does. The introduction is asked for again once the members
    /// are listed, as a join is only sure to have one after that; without
    /// `nudge` the join has to do it alone. The room echoes back what was
    /// written, unless `echo` is off.
    func join(nudge: Bool = true, echo: Bool = true) async {
        session.updateRoom(room) {
            $0?.phase = .joined
            $0?.isSyncing = true
            $0?.membersListed = false
            $0?.joinedAt = Date()
        }
        session.didJoin(room)
        // An anonymous room has no member lists to wait for.
        if listsMembers { await eventually("the members to be listed") { self.session.roomStatus(room)?.membersListed == true } }
        if nudge {
            session.introduceDevice(to: room)
        } else {
            await eventually("the introduction") { !self.introductions.isEmpty }
        }
        session.drainSendQueue(room)
        if echo { reflectPending() }
    }

    /// What the room does with the introduction waiting for it.
    func reflectPending() {
        guard session.lock.withLock({ $0.pendingIntroductions[room] != nil }), let sent = introductions.last else { return }
        let reflected: Martin.Message = parseStanza(sent.element.stringValue)
        reflected.from = Martin.JID("\(room)/me")
        session.handleRoomStanza(reflected, source: .live)
    }

    /// What was written to the room that has an `<encrypted>` element.
    var introductions: [Martin.Message] {
        wire.messages.filter { $0.to?.bareJid.stringValue == room.description && $0.firstChild(name: "encrypted", xmlns: NS.omemoLegacy) != nil }
    }

    var introduced: Set<YapnestKit.JID> { database.introducedMembers(in: room, device: session.omemoDeviceId) }

    /// The devices a message holds keys for.
    func keyIds(of message: Martin.Message?) -> [String] {
        message?.firstChild(name: "encrypted", xmlns: NS.omemoLegacy)?.firstChild(name: "header")?.filterChildren(name: "key", xmlns: nil).compactMap { $0.getAttribute("rid") } ?? []
    }

    /// Whether nothing was stored and nobody was told.
    var showsNothing: Bool { storedMessages == 0 && events.withLock { $0.isEmpty } }

    var storedMessages: Int { (try? database.reader.read { try YapnestKit.Message.fetchCount($0) }) ?? -1 }
}

struct DeviceIntroductionTests {
    @Test func aNewDeviceWritesOneKeyTransportToThePrivateGroup() async throws {
        let h = try await IntroductionHarness()
        await h.join(nudge: false)

        let sent = try #require(h.introductions.first)
        #expect(h.introductions.count == 1)
        #expect(sent.type == .groupchat)
        #expect(sent.to?.bareJid.stringValue == room.description)
        let encrypted = try #require(sent.firstChild(name: "encrypted", xmlns: NS.omemoLegacy))
        #expect(h.keyIds(of: sent) == [h.bobsPhone.device.omemoId])
        #expect(encrypted.firstChild(name: "payload") == nil)
        #expect(sent.body == nil)
        #expect(sent.element.filterChildren(name: "store", xmlns: NS.hints).count == 1)
        #expect(h.introduced == [bob])
    }

    @Test func aRejoinDoesNotWriteAgain() async throws {
        let h = try await IntroductionHarness()
        await h.join()
        await h.join()
        #expect(h.introductions.count == 1)
    }

    @Test func marksAreKeptPerMemberPerGroupAndForOneDeviceAtATime() throws {
        let database = try AppDatabase.inMemory()
        let other = YapnestKit.JID("tea@rooms.example.org")!
        try database.markIntroduced([bob], in: room, device: 5)
        try database.markIntroduced([carol], in: room, device: 5)
        try database.markIntroduced([bob], in: other, device: 5)
        #expect(database.introducedMembers(in: room, device: 5) == [bob, carol])
        #expect(database.introducedMembers(in: other, device: 5) == [bob])
        #expect(database.introducedMembers(in: room, device: 6).isEmpty)
        try database.markIntroduced([bob], in: room, device: 6)
        #expect(database.introducedMembers(in: room, device: 6) == [bob])
        #expect(database.introducedMembers(in: room, device: 5).isEmpty, "a new device id starts over")
    }

    @Test func aMarkOfAnOlderShapeReadsAsNothing() throws {
        let database = try AppDatabase.inMemory()
        try database.setSetting(.introducedGroups, #"{"device":5,"rooms":["cake@rooms.example.org"]}"#)
        #expect(database.introducedMembers(in: room, device: 5).isEmpty)
    }

    @Test func aDifferentDeviceIdIntroducesItselfAgain() async throws {
        let h = try await IntroductionHarness()
        try h.database.markIntroduced([bob], in: room, device: h.session.omemoDeviceId &+ 1)
        #expect(h.introduced.isEmpty, "another device's mark is no mark of this one")
        await h.join()
        #expect(h.introductions.count == 1)
        #expect(h.introduced == [bob])
    }

    @Test func aWriteTheStreamDroppedLeavesItUnmarkedForTheNextJoin() async throws {
        let h = try await IntroductionHarness()
        h.wire.failsWrites = true
        await h.join()
        #expect(h.introduced.isEmpty)

        let dropped = h.introductions.count
        #expect(dropped > 0, "written, then dropped")
        h.wire.failsWrites = false
        await h.join()
        #expect(h.introduced == [bob])
        #expect(h.introductions.count == dropped + 1)
    }

    @Test func noConnectionByTheTimeTheQueueGetsToItLeavesItUnmarked() async throws {
        let h = try await IntroductionHarness()
        h.session.updateRoom(room) { $0?.isSyncing = false; $0?.membersListed = true }
        let gate = DispatchSemaphore(value: 0)
        h.session.sendQueue(for: room).async { gate.wait() }
        h.session.introduceDevice(to: room)
        h.session.client.update(state: .disconnected())
        gate.signal()
        h.session.drainSendQueue(room)
        #expect(h.introductions.isEmpty)
        #expect(h.introduced.isEmpty)
    }

    @Test func noMarkUntilTheRoomEchoesItBack() async throws {
        let h = try await IntroductionHarness()
        await h.join(echo: false)
        #expect(h.introductions.count == 1)
        #expect(h.introduced.isEmpty, "written to the socket is not archived by the room")

        await h.join(echo: false)
        #expect(h.introductions.count == 1, "one is out and waiting on this connection")

        h.session.clearRooms()
        h.setUpRoom()
        await h.join()
        #expect(h.introductions.count == 2, "a new connection sends it again")
        #expect(h.introduced == [bob])
    }

    @Test func twoCallsBackToBackWriteOneMessage() async throws {
        let h = try await IntroductionHarness()
        h.session.updateRoom(room) { $0?.isSyncing = false; $0?.membersListed = true }
        h.session.introduceDevice(to: room)
        h.session.introduceDevice(to: room)
        h.session.drainSendQueue(room)
        #expect(h.introductions.count == 1)
    }

    @Test func notFromAnExtension() async throws {
        let h = try await IntroductionHarness(mode: .notificationService)
        await h.join()
        #expect(h.introductions.isEmpty)
        #expect(h.introduced.isEmpty)
    }

    @Test func notToAPublicGroup() async throws {
        let h = try await IntroductionHarness(isMembersOnly: false)
        await h.join()
        #expect(h.introductions.isEmpty)
    }

    @Test func notToAnAnonymousGroup() async throws {
        let h = try await IntroductionHarness(isNonAnonymous: false)
        await h.join()
        #expect(h.introductions.isEmpty)
    }

    @Test func notToAnUnencryptedConversation() async throws {
        let h = try await IntroductionHarness(isEncrypted: false)
        await h.join()
        #expect(h.introductions.isEmpty)
        #expect(h.introduced.isEmpty)
    }

    @Test func notBeforeTheMembersAreKnown() async throws {
        let h = try await IntroductionHarness()
        h.session.updateRoom(room) { $0?.isSyncing = false; $0?.membersListed = false }
        h.session.introduceDevice(to: room)
        h.session.drainSendQueue(room)
        #expect(h.introductions.isEmpty)
    }

    @Test func aMemberWithoutADeviceDoesNotStopTheOthers() async throws {
        let h = try await IntroductionHarness(members: [bob, carol], withDevices: [bob])
        await h.join()
        #expect(h.keyIds(of: h.introductions.first) == [h.bobsPhone.device.omemoId])
        #expect(h.introduced == [bob])
    }

    @Test func nobodyReachableWritesNothingAndTriesAgainNextJoin() async throws {
        let h = try await IntroductionHarness(members: [carol], withDevices: [])
        await h.join()
        #expect(h.introductions.isEmpty)
        #expect(h.introduced.isEmpty)
    }

    @Test func aMemberWhoseFetchFailedIsLeftUnmarkedAndIntroducedAloneNextJoin() async throws {
        let h = try await IntroductionHarness(members: [bob, carol], withDevices: [bob])
        await h.join()
        #expect(h.introduced == [bob])

        h.listed.withLock { _ = $0.insert(carol) }
        h.session.omemo.forgetFetchFailures(of: [carol])
        await h.join()
        #expect(h.introductions.count == 2)
        #expect(h.keyIds(of: h.introductions.last) == [h.carolsPhone.device.omemoId], "Bob was introduced already")
        #expect(h.introduced == [bob, carol])
    }

    @Test func aMemberWhoJoinedAfterwardsGetsOneAndTheOthersNothing() async throws {
        let h = try await IntroductionHarness(members: [bob], withDevices: [bob, carol])
        await h.join()
        #expect(h.introduced == [bob])

        h.addMember(carol)
        await h.join()
        #expect(h.introductions.count == 2)
        #expect(h.keyIds(of: h.introductions.last) == [h.carolsPhone.device.omemoId])
        #expect(h.introduced == [bob, carol])

        await h.join()
        #expect(h.introductions.count == 2, "everyone has one")
    }

    @Test func aReachedMembersBrokenSessionDoesNotStopTheOthers() async throws {
        let h = try await IntroductionHarness(members: [bob, carol], withDevices: [bob, carol])
        let address = SignalAddress(name: bob.description, deviceId: h.bobsPhone.device)
        #expect(h.session.omemoStoreForTesting.storeSessionRecord(Data([1, 2, 3]), forAddress: address))
        await h.join()
        #expect(h.keyIds(of: h.introductions.first) == [h.carolsPhone.device.omemoId], "no key for Bob's device was made")
        #expect(h.introduced == [carol])
    }

    // MARK: Introducing again

    /// Bob in the room with his real address, and a message from his phone
    /// that has keys for other devices but none for this one.
    private func messageWithNoKeyForUs(from h: IntroductionHarness, id: String, history: Bool = false) {
        h.session.updateRoom(room) { $0?.isSyncing = false }
        h.session.roomPresence(parseStanza("""
            <presence from='\(room)/Bob' to='me@example.org/t'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' jid='bob@example.org/phone'/></x></presence>
            """), room: room)
        h.session.applyOccupantChanges()
        let stanza: Martin.Message = parseStanza("""
            <message from='\(room)/Bob' type='groupchat' id='\(id)'><body>🔒</body>\
            <encrypted xmlns='\(NS.omemoLegacy)'><header sid='\(h.bobsPhone.device.omemoId)'>\
            <key rid='12345'>AAAA</key><iv>AAAAAAAAAAAAAAAA</iv></header><payload>AAAA</payload></encrypted></message>
            """)
        if history { stanza.addChild(Element(name: "delay", attributes: ["xmlns": "urn:xmpp:delay", "stamp": "2026-10-01T10:00:00Z"])) }
        h.session.handleRoomStanza(stanza, source: .live)
        h.session.drainSendQueue(room)
    }

    /// Introduced and echoed, yet Bob's client never took the device in, as
    /// when he was away and his catch-up didn't reach back to it: his
    /// messages kept coming with no key for it.
    @Test func aMembersMessageWithNoKeyForThisDeviceIntroducesItAgain() async throws {
        let h = try await IntroductionHarness()
        await h.join()
        #expect(h.introductions.count == 1)

        messageWithNoKeyForUs(from: h, id: "m1")
        #expect(h.introductions.count == 2)
        #expect(h.keyIds(of: h.introductions.last) == [h.bobsPhone.device.omemoId])
        #expect(h.introduced == [], "marked again only once the room echoes it")
        h.reflectPending()
        #expect(h.introduced == [bob])
    }

    @Test func aMemberIsIntroducedAgainAtMostEveryInterval() async throws {
        let h = try await IntroductionHarness()
        await h.join()
        messageWithNoKeyForUs(from: h, id: "m1")
        h.reflectPending()
        messageWithNoKeyForUs(from: h, id: "m2")
        #expect(h.introductions.count == 2)

        // Later than the interval, he gets another.
        h.session.lock.withLock { state in
            for key in state.reintroductions.keys { state.reintroductions[key]! -= XMPPSession.reintroductionInterval + 1 }
        }
        messageWithNoKeyForUs(from: h, id: "m3")
        #expect(h.introductions.count == 3)
    }

    @Test func anOldMessageWithNoKeyForThisDeviceIntroducesNothing() async throws {
        let h = try await IntroductionHarness()
        await h.join()
        messageWithNoKeyForUs(from: h, id: "m1", history: true)
        #expect(h.introductions.count == 1, "sent before this device existed, it says nothing of now")
    }

    // MARK: Receiving

    private func transport(from sender: String, id: String, by device: OtherDevice, in h: IntroductionHarness) throws {
        let stanza: Martin.Message = parseStanza("<message from='\(room)/\(sender)' type='groupchat' id='\(id)'></message>")
        stanza.addChild(try device.encrypt(nil, to: h.session))
        stanza.addChild(Element(name: "store", xmlns: NS.hints))
        h.session.handleRoomStanza(stanza, source: .live)
    }

    @Test func aMembersKeyTransportStoresAndShowsNothing() async throws {
        let h = try await IntroductionHarness()
        h.session.updateRoom(room) { $0?.isSyncing = false }
        h.session.roomPresence(parseStanza("""
            <presence from='\(room)/Bob' to='me@example.org/t'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' jid='bob@example.org/phone'/></x></presence>
            """), room: room)
        h.session.applyOccupantChanges()
        try transport(from: "Bob", id: "kt1", by: h.bobsPhone, in: h)
        #expect(h.showsNothing)
    }

    @Test func aKeyTransportFromAMemberWhoseAddressIsUnknownStoresNoPlaceholder() async throws {
        let h = try await IntroductionHarness()
        h.session.updateRoom(room) { $0?.isSyncing = false }
        try transport(from: "Bob", id: "kt3", by: h.bobsPhone, in: h)
        #expect(h.showsNothing, "a lock placeholder for a message with nothing in it")
    }

    @Test func aKeyTransportFromAnotherDeviceOfOursStoresAndShowsNothing() async throws {
        let h = try await IntroductionHarness()
        let other = try OtherDevice(account: me)
        try transport(from: "me", id: "kt2", by: other, in: h)
        #expect(h.showsNothing)
    }

    @Test func theRoomsCopyOfOurOwnIntroductionStoresAndShowsNothing() async throws {
        let h = try await IntroductionHarness()
        await h.join(echo: false)
        h.reflectPending()
        #expect(h.showsNothing)
        #expect(h.introduced == [bob])
    }
}
