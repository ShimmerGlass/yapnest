import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// A correction or retraction of a message already sent stays pending until
/// the server acknowledges its stanza, and a new session sends it again.
struct PendingActionTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let message: YapnestKit.Message

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        session.enableAcknowledgementsForTesting()
        try session.setEncrypted(false, with: alice)
        let id = try #require(try database.conversation(with: alice).id)
        message = try database.insert(YapnestKit.Message(
            conversationId: id, direction: .outgoing, sender: me, body: "hello", status: .sent, remoteId: "m1",
        ))
    }

    private func stored(_ message: YapnestKit.Message? = nil) throws -> YapnestKit.Message {
        let id = (message ?? self.message).id!
        return try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: id) })
    }

    private func corrections(_ wire: FakeWire? = nil) -> [Martin.Message] {
        (wire ?? self.wire).messages.filter { $0.firstChild(name: "replace", xmlns: NS.correction) != nil }
    }

    private func retractions() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "retract", xmlns: NS.retraction) != nil }
    }

    private func startNewSession() {
        session.lock.withLock {
            $0.sends.reset()
            $0.writtenActions = []
        }
    }

    @Test func aRetractionLostWithTheConnectionIsSentAgainWithTheSameId() throws {
        wire.failsWrites = true
        try session.retract(message)
        session.drainSendQueue(alice)
        #expect(retractions().count == 1)
        let id = try #require(retractions().first?.id)
        #expect(try stored().actionPendingId == id)
        #expect(try stored().isRetracted)

        wire.failsWrites = false
        startNewSession()
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(retractions().map(\.id) == [id, id])
        #expect(retractions().last?.firstChild(name: "retract", xmlns: NS.retraction)?.attribute("id") == "m1")
    }

    @Test func aCorrectionLostWithTheConnectionIsSentAgainWithTheCurrentBody() throws {
        wire.failsWrites = true
        try session.edit(message, to: "hello there")
        session.drainSendQueue(alice)
        let id = try #require(corrections().first?.id)
        #expect(try stored().actionPendingId == id)

        wire.failsWrites = false
        startNewSession()
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        let sent = try #require(corrections().last)
        #expect(corrections().count == 2)
        #expect(sent.id == id)
        #expect(sent.body == "hello there")
        #expect(sent.firstChild(name: "replace", xmlns: NS.correction)?.attribute("id") == "m1")
    }

    @Test func aLaterCorrectionReplacesTheEarlierOnesId() throws {
        wire.failsWrites = true
        try session.edit(message, to: "one")
        try session.edit(try stored(), to: "two")
        session.drainSendQueue(alice)
        let ids = corrections().compactMap(\.id)
        #expect(try stored().actionPendingId != nil)
        #expect(try stored().actionPendingId == ids.last)

        wire.failsWrites = false
        startNewSession()
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        let pendingId = try stored().actionPendingId
        #expect(corrections().last?.id == pendingId)
        #expect(corrections().last?.body == "two")
    }

    @Test func aRetractionAfterACorrectionIsTheOnlyOneSentAgain() throws {
        wire.failsWrites = true
        try session.edit(message, to: "hello there")
        try session.retract(try stored())
        session.drainSendQueue(alice)
        let id = try #require(retractions().first?.id)
        #expect(try stored().actionPendingId == id)
        let correctionsBefore = corrections().count

        wire.failsWrites = false
        startNewSession()
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(retractions().map(\.id) == [id, id])
        #expect(corrections().count == correctionsBefore)
    }

    @Test func anAcknowledgementClearsItAndNothingIsSentAgain() throws {
        try session.edit(message, to: "hello there")
        session.drainSendQueue(alice)
        let stanza = try #require(corrections().first)
        #expect(try stored().actionPendingId == stanza.id)

        session.acknowledged(stanza)
        #expect(try stored().actionPendingId == nil)

        startNewSession()
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(corrections().count == 1)
    }

    @Test func aStanzaStillUnacknowledgedIsNotWrittenAgainThisSession() throws {
        try session.retract(message)
        session.drainSendQueue(alice)
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(retractions().count == 1)
        #expect(try stored().actionPendingId != nil)
    }

    @Test func correctingWhileOfflineAppliesHereAndSendsOnConnect() throws {
        let connected = FakeWire()
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database)
        let id = try #require(try database.conversation(with: alice).id)
        let sent = try database.insert(YapnestKit.Message(conversationId: id, direction: .outgoing, sender: me, body: "hello", status: .sent, remoteId: "m1"))

        try session.edit(sent, to: "fixed")
        let pending = try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: sent.id!) })
        #expect(pending.body == "fixed")
        #expect(pending.actionPendingId != nil)

        session.connectForTesting(connected)
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        let stanza = try #require(corrections(connected).first)
        #expect(stanza.id == pending.actionPendingId)
        #expect(stanza.body == "fixed")
    }

    @Test func aCorrectionInARoomThatIsntReadyWaitsForIt() throws {
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        let id = try #require(try database.conversation(with: room).id)
        let mine = try database.insert(YapnestKit.Message(
            conversationId: id, direction: .outgoing, sender: me, body: "hi", status: .sent, remoteId: "g1", serverId: "s1",
        ))
        session.updateRoom(room) {
            var status = RoomStatus(phase: .joined, nickname: "me")
            status.isSyncing = true
            $0 = status
        }

        try session.edit(mine, to: "hi all")
        session.drainSendQueue(room)
        #expect(corrections().isEmpty)
        #expect(try stored(mine).actionPendingId != nil)

        session.updateRoom(room) { $0?.isSyncing = false }
        session.sendDeferred(in: room)
        session.drainSendQueue(room)
        #expect(corrections().count == 1)
        #expect(corrections().first?.body == "hi all")
    }
}
