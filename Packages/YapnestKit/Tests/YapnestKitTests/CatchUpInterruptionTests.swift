import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

struct CatchUpOutcomeTests {
    @Test func aCatchUpOnItsOwnLiveConnectionProceeds() {
        #expect(XMPPSession.catchUpOutcome(isConnected: true, startedOn: 3, now: 3) == .proceed)
    }

    @Test func aCatchUpWhoseConnectionDroppedIsInterrupted() {
        #expect(XMPPSession.catchUpOutcome(isConnected: false, startedOn: 3, now: 3) == .interrupted)
        #expect(XMPPSession.catchUpOutcome(isConnected: false, startedOn: 3, now: 4) == .interrupted)
    }

    @Test func aLateAnswerOnANewerConnectionIsLeftToItsCatchUp() {
        #expect(XMPPSession.catchUpOutcome(isConnected: true, startedOn: 3, now: 5) == .superseded)
    }
}

struct RoomCursorTests {
    private func live(_ id: String, stanzaId: String?) throws -> InboundMessage {
        let sid = stanzaId.map { "<stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='\($0)'/>" } ?? ""
        let xml = "<message from='cake@rooms.example.org/anna' type='groupchat' id='\(id)'><body>hi</body>\(sid)</message>"
        let message = Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
        return try #require(InboundMessage(groupchat: message, room: RoomContext(jid: room, nickname: "me"), account: me, source: .live))
    }

    @Test func aLiveMessageMovesTheCursorToItsStanzaId() throws {
        let db = try AppDatabase.inMemory()
        try db.joinGroupChat(room, nickname: "me")
        try db.updateGroupChat(room) { $0.lastArchiveId = "old" }
        let group = try #require(try db.groupChat(room))

        let result = try db.ingestLive(try live("m1", stanzaId: "r2"), in: group)

        #expect(result.newMessage != nil)
        #expect(try db.groupChat(room)?.lastArchiveId == "r2")
    }

    @Test func aMessageWithoutAStanzaIdLeavesTheCursor() throws {
        let db = try AppDatabase.inMemory()
        try db.joinGroupChat(room, nickname: "me")
        try db.updateGroupChat(room) { $0.lastArchiveId = "old" }
        let group = try #require(try db.groupChat(room))

        _ = try db.ingestLive(try live("m1", stanzaId: nil), in: group)

        #expect(try db.groupChat(room)?.lastArchiveId == "old")
    }

    @Test func aPlainIngestLeavesTheCursor() throws {
        let db = try AppDatabase.inMemory()
        try db.joinGroupChat(room, nickname: "me")
        try db.updateGroupChat(room) { $0.lastArchiveId = "old" }

        _ = try db.ingest(try live("m1", stanzaId: "r2"))

        #expect(try db.groupChat(room)?.lastArchiveId == "old")
    }
}
