import Foundation
@preconcurrency @testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

struct RoomCatchUpResendTests {
    private func catchUp(mode: XMPPSession.Mode) throws -> [Martin.Message] {
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database, mode: mode)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        let id = try #require(try database.conversation(with: room).id)
        _ = try database.insert(YapnestKit.Message(
            conversationId: id, direction: .outgoing, sender: me, body: "hi", status: .pending, remoteId: "g1",
        ))
        let wire = FakeWire()
        session.connectForTesting(wire)
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = true
        session.updateRoom(room) { $0 = status }
        let joinedAt = try #require(session.roomStatus(room)?.joinedAt)
        session.finishRoomCatchUp(room, .init(attempt: session.lock.withLock { $0.attempt }, joinedAt: joinedAt), reachedEnd: true)
        session.drainSendQueue(room)
        return wire.messages.filter { $0.body == "hi" }
    }

    @Test func anExtensionSendsNothingAfterARoomCatchUp() throws {
        #expect(try catchUp(mode: .notificationService).isEmpty)
    }

    @Test func theAppResendsWhatIsPendingAfterARoomCatchUp() throws {
        #expect(try catchUp(mode: .app).map(\.id) == ["g1"])
    }

    @Test func aRoomIsNotWrittenIntoBeforeItsMemberListsCame() async throws {
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database, mode: .app)
        try database.joinGroupChat(room, nickname: "me")
        try database.setRoomInfo(room, name: nil, isMembersOnly: true, isNonAnonymous: true)
        session.reloadKnownRooms()
        let id = try #require(try database.conversation(with: room).id)
        _ = try database.insert(YapnestKit.Message(
            conversationId: id, direction: .outgoing, sender: me, body: "hi", status: .pending, remoteId: "g1",
        ))
        let wire = FakeWire()
        wire.answer { iq in
            iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin") != nil ? FakeWire.result(to: iq) : FakeWire.error(to: iq)
        }
        wire.holdReplies { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin") != nil }
        session.connectForTesting(wire)
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = true
        session.updateRoom(room) { $0 = status }
        // The room keeps no archive, so the catch-up ends at once.
        session.didJoin(room)
        await eventually("the catch-up to end") { session.roomStatus(room)?.isSyncing == false }
        session.drainSendQueue(room)
        #expect(wire.messages.filter { $0.body == "hi" }.isEmpty)
        await eventually("the lists to be asked for") { wire.heldPings > 0 }
        // The lists are asked for one after another, and under load only the
        // first may be out yet: the ones still to come must not be held.
        wire.holdReplies(to: nil)
        wire.releasePings()
        await eventually("the lists") { session.roomStatus(room)?.membersListed == true }
        #expect(session.roomStatus(room)?.awaitsMemberLists == false)
        await eventually("the message to go out once the lists are in") {
            session.drainSendQueue(room)
            return wire.messages.contains { $0.body == "hi" }
        }
    }

    @Test func listsCutOffByAResumedStreamAreAskedForAgain() async throws {
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database, mode: .app)
        try database.joinGroupChat(room, nickname: "me")
        try database.setRoomInfo(room, name: nil, isMembersOnly: true, isNonAnonymous: true)
        session.reloadKnownRooms()
        let id = try #require(try database.conversation(with: room).id)
        _ = try database.insert(YapnestKit.Message(
            conversationId: id, direction: .outgoing, sender: me, body: "hi", status: .pending, remoteId: "g1",
        ))
        let wire = FakeWire()
        wire.answer { iq in
            iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin") != nil ? FakeWire.result(to: iq) : FakeWire.error(to: iq)
        }
        wire.holdReplies { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin") != nil }
        session.connectForTesting(wire)
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = true
        session.updateRoom(room) { $0 = status }
        session.didJoin(room)
        await eventually("the catch-up to end") { session.roomStatus(room)?.isSyncing == false }
        await eventually("the lists to be asked for") { wire.heldPings > 0 }
        // The stream drops with the lists on their way and resumes; the
        // answers that come on the old one count for nothing.
        session.client.update(state: .disconnected())
        wire.releasePings()
        #expect(session.roomStatus(room)?.awaitsMemberLists == true)
        session.client.update(state: .connected(resumed: true))
        await eventually("the lists to be asked for again") { wire.heldPings > 0 }
        wire.holdReplies(to: nil)
        wire.releasePings()
        await eventually("the lists") { session.roomStatus(room)?.awaitsMemberLists == false }
        await eventually("the message to go out once the lists are in") {
            session.drainSendQueue(room)
            return wire.messages.contains { $0.body == "hi" }
        }
    }

    @Test func theBanListAloneHoldsNothingUp() async throws {
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database, mode: .app)
        try database.joinGroupChat(room, nickname: "me")
        try database.setRoomInfo(room, name: nil, isMembersOnly: false, isNonAnonymous: false)
        session.reloadKnownRooms()
        let wire = FakeWire()
        wire.holdReplies { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin") != nil }
        session.connectForTesting(wire)
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = true
        status.affiliation = .admin
        session.updateRoom(room) { $0 = status }
        session.didJoin(room)
        await eventually("the catch-up to end") { session.roomStatus(room)?.isSyncing == false }
        #expect(session.roomStatus(room)?.awaitsMemberLists == false)
    }
}
