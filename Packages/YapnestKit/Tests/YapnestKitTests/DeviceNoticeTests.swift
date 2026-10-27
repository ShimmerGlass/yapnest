import Foundation
import GRDB
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

/// Under blind trust a device that appears later is trusted silently, so the
/// user is told: a notice is recorded where the identity is stored.
struct DeviceNoticeTests {
    let me = JID("me@example.org")!
    let bob = JID("bob@example.org")!
    let clock = TestClock()

    private func key(_ byte: UInt8) -> Data { Data([0x05] + Array(repeating: byte, count: 32)) }

    private func store(_ database: AppDatabase) -> OMEMOStore {
        let clock = clock
        return OMEMOStore(database: database, account: me, identityKeys: MemoryIdentityKeyStore(), now: { clock.now })
    }

    private func save(_ id: Int32, of jid: JID, to store: OMEMOStore) {
        #expect(store.save(identity: SignalAddress(name: jid.description, deviceId: id), publicKeyData: key(UInt8(id))))
    }

    @Test func aNewDeviceOfOursAfterTheFirstListRaisesANotice() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        try database.noteDeviceList(of: me.description, ids: [1, 2])
        save(2, of: me, to: store)
        #expect(try database.deviceNotices().isEmpty, "a device of the first list is not new")
        save(3, of: me, to: store)
        let notices = try database.deviceNotices()
        #expect(notices.map(\.deviceId) == [3])
        #expect(notices.first?.fingerprint == OMEMOStore.fingerprint(of: key(3)))
    }

    @Test func nothingIsNewBeforeTheFirstListIsHeard() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        save(2, of: me, to: store)
        save(3, of: me, to: store)
        #expect(try database.deviceNotices().isEmpty)
    }

    @Test func aLaterListDoesNotMakeItsDevicesPartOfTheFirst() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        try database.noteDeviceList(of: me.description, ids: [1])
        try database.noteDeviceList(of: me.description, ids: [1, 3])
        save(3, of: me, to: store)
        #expect(try database.deviceNotices().map(\.deviceId) == [3])
    }

    @Test func thisInstallsOwnDeviceNeverRaisesANotice() throws {
        let database = try AppDatabase.inMemory()
        let encryption = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        try database.noteDeviceList(of: me.description, ids: [1])
        let own = Int32(bitPattern: encryption.deviceId)
        #expect(encryption.store.save(identity: SignalAddress(name: me.description, deviceId: own), publicKeyData: key(9)))
        #expect(try database.deviceNotices().isEmpty)
    }

    private func events(_ database: AppDatabase, in jid: JID) throws -> [Message] {
        try database.reader.read { db in
            try Message.filter(Column("event") != nil).order(Column("id")).fetchAll(db).filter { message in
                try Conversation.fetchOne(db, key: message.conversationId)?.peer == jid
            }
        }
    }

    private func chat(_ database: AppDatabase, with jid: JID) throws -> Conversation { try database.conversation(with: jid) }

    @Test func aContactsFirstDevicesAreNotNews() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        _ = try chat(database, with: bob)
        try database.noteDeviceList(of: bob.description, ids: [])
        save(1, of: bob, to: store)
        #expect(try events(database, in: bob).isEmpty)
    }

    @Test func aContactsLaterDeviceWritesOneEventInTheirChatAtTheMomentItIsStored() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        let conversation = try chat(database, with: bob)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(1, of: bob, to: store)
        clock.advance(days: 3)
        save(2, of: bob, to: store)
        save(2, of: bob, to: store)
        let found = try events(database, in: bob)
        #expect(found.count == 1)
        let event = try #require(found.first)
        #expect(event.event == .newDevice(deviceId: 2, fingerprint: OMEMOStore.fingerprint(of: key(2))))
        #expect(event.conversationId == conversation.id)
        #expect(event.timestamp == clock.now)
        #expect(event.isRead && event.body.isEmpty)
        #expect(event.direction == .event)
        #expect(try events(database, in: me).isEmpty, "nothing in a chat with ourselves")
    }

    @Test func aChatWithOnlyAnEventHasNoMessagesToRestore() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        let conversation = try chat(database, with: bob)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(1, of: bob, to: store)
        save(2, of: bob, to: store)
        #expect(try events(database, in: bob).count == 1)
        #expect(try database.peersWithMessages().isEmpty, "an event is not a message, so the archive is still restored")
        _ = try database.insert(Message(conversationId: try #require(conversation.id), direction: .incoming, sender: bob, body: "Hi", remoteId: "m"))
        #expect(try database.peersWithMessages() == [bob])
    }

    @Test func noChatIsMadeForAContactWeNeverTalkedTo() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(1, of: bob, to: store)
        save(2, of: bob, to: store)
        #expect(try database.reader.read { try Conversation.fetchCount($0) } == 0)
    }

    @Test func ourOwnDeviceWritesNoEventInAContactsChat() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        _ = try chat(database, with: bob)
        try database.noteDeviceList(of: me.description, ids: [1])
        save(5, of: me, to: store)
        #expect(try events(database, in: bob).isEmpty)
        #expect(try database.deviceNotices().map(\.deviceId) == [5])
    }

    @Test func aContactWithoutAStoredDeviceGetsNoEventForTheirFirst() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        _ = try chat(database, with: bob)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(2, of: bob, to: store)
        #expect(try events(database, in: bob).isEmpty)
    }

    @Test func aContactWhoVerifiedAKeyStillGetsTheEventForANewUndecidedDevice() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        _ = try chat(database, with: bob)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(1, of: bob, to: store)
        #expect(store.setStatus(.verifiedActive, forIdentity: SignalAddress(name: bob.description, deviceId: 1)))
        save(2, of: bob, to: store)
        #expect(try events(database, in: bob).count == 1)
        #expect(store.identities(forName: bob.description).first { $0.address.deviceId == 2 }?.status == .undecidedActive)
    }

    @Test func aDeviceComingBackAfterBeingInactiveWritesNoSecondEvent() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        _ = try chat(database, with: bob)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(1, of: bob, to: store)
        save(2, of: bob, to: store)
        clock.advance(days: 200)
        #expect(store.setStatus(active: false, forIdentity: SignalAddress(name: bob.description, deviceId: 2)))
        #expect(store.setStatus(active: true, forIdentity: SignalAddress(name: bob.description, deviceId: 2)))
        save(2, of: bob, to: store)
        #expect(try events(database, in: bob).count == 1)
    }

    @Test func eventsAreNotUnreadNotThePreviewAndNotTheReadPoint() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        let conversation = try chat(database, with: bob)
        let id = try #require(conversation.id)
        try database.noteDeviceList(of: bob.description, ids: [1])
        save(1, of: bob, to: store)
        let hello = try database.insert(Message(conversationId: id, direction: .incoming, sender: bob, body: "Hello nest", timestamp: clock.now, isRead: true, remoteId: "m1"))
        clock.advance(days: 1)
        save(2, of: bob, to: store)
        #expect(try events(database, in: bob).count == 1)
        let item = try #require(try database.chatList().first)
        #expect(item.unreadCount == 0)
        #expect(item.lastMessage?.id == hello.id, "the preview is the last real message")
        #expect(try database.unreadCount() == 0)
        #expect(try database.lastIncoming(conversationId: id)?.id == hello.id)
        #expect(try database.oldestMessage(peer: bob)?.id == hello.id)
        try database.markUnread(conversationId: id)
        #expect(try database.unreadCount() == 1, "marking unread takes the last message, not the event")
        #expect(try database.reader.read { try Message.filter(Column("event") != nil && Column("isRead") == false).fetchCount($0) } == 0)
    }

    @Test func dismissingAnOwnDeviceHidesOnlyThatOneAndLeavesTrustAlone() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        try database.noteDeviceList(of: me.description, ids: [1])
        save(3, of: me, to: store)
        save(4, of: me, to: store)
        try database.dismissDeviceNotice(deviceId: 3)
        #expect(try database.deviceNotices().map(\.deviceId) == [4])
        #expect(store.identities(forName: me.description).first { $0.address.deviceId == 3 }?.status == .trustedActive)
        save(3, of: me, to: store)
        #expect(try database.deviceNotices().map(\.deviceId) == [4], "a dismissed device is not announced again")
    }

    @Test func removingAnOwnDeviceTakesItsNoticeAway() throws {
        let database = try AppDatabase.inMemory(), store = store(database)
        try database.noteDeviceList(of: me.description, ids: [1])
        save(3, of: me, to: store)
        store.forget(deviceIds: [3], of: me.description)
        #expect(try database.deviceNotices().isEmpty)
    }
}

struct DeviceNoticeSessionTests {
    let me = JID("me@example.org")!

    @Test func aNewDeviceOfOursIsWarnedOfUntilDismissed() async throws {
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database)
        session.deviceListHeard(of: me.description, ids: [1])
        await eventually("the first list recorded") { ((try? database.reader.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM deviceListSeen)") }) ?? false) == true }
        #expect(session.warnings.current.isEmpty)
        let key = Data([0x05] + Array(repeating: 7, count: 32))
        #expect(session.omemoStoreForTesting.save(identity: SignalAddress(name: me.description, deviceId: 7), publicKeyData: key))
        await eventually("the warning") { session.warnings.current.map(\.key) == ["new-device:7"] }
        let warning = try #require(session.warnings.current.first)
        #expect(warning.title == "New device on your account")
        #expect(warning.detail.contains(OMEMOStore.fingerprint(of: key).prefix(8)))
        #expect(warning.action == .openDevices)
        session.warnings.dismiss("new-device:7")
        await eventually("the warning gone") { session.warnings.current.isEmpty }
        #expect(try database.deviceNotices().isEmpty)
        #expect(session.devices(of: me).first { $0.id == 7 }?.trust == .trusted, "dismissing leaves trust alone")
    }
}
