import Foundation
@preconcurrency import Martin
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
}
