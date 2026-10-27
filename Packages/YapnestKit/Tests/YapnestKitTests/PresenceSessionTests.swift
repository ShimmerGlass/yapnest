import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// Whether a nickname's earlier holder's messages can be edited by whoever
/// takes it later, through the room's real presences and messages.
struct PresenceSessionTests {
    let database: AppDatabase
    let session: XMPPSession

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = false
        status.catchUpReachedEnd = true
        session.updateRoom(room) { $0 = status }
    }

    private func presence(_ nick: String, type: String? = nil, show: String? = nil, extra: String = "", renamedTo: String? = nil) -> Martin.Presence {
        let type = type.map { " type='\($0)'" } ?? ""
        let show = show.map { "<show>\($0)</show>" } ?? ""
        return parseStanza("<presence from='\(room)/\(nick)' to='me@example.org/t'\(type)>\(show)<x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='participant'\(renamedTo.map { " nick='\($0)'" } ?? "")/>\(extra)</x></presence>")
    }

    private func say(_ id: String, as nick: String = "Alice", _ payload: String = "<body>hi all</body>") {
        session.handleRoomStanza(
            parseStanza("<message from='\(room)/\(nick)' type='groupchat' id='\(id)'>\(payload)</message>"),
            source: .live,
        )
    }

    private func stored(_ id: String) throws -> YapnestKit.Message {
        try #require(try database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == id).fetchOne($0) })
    }

    private let correction = "<body>pwned</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/>"
    private let retraction = "<retract id='g1' xmlns='urn:xmpp:message-retract:1'/>"

    @Test func someoneWhoTakesALeftNicknameCannotEditItsEarlierMessages() throws {
        session.roomPresence(presence("Alice"), room: room)
        say("g1")
        session.roomPresence(presence("Alice", type: "unavailable"), room: room)
        session.roomPresence(presence("Alice"), room: room)
        say("g2", correction)
        say("g3", retraction)
        let original = try stored("g1")
        #expect(original.body == "hi all")
        #expect(!original.isRetracted)
        #expect(try database.reader.read { try YapnestKit.Message.fetchCount($0) } == 1)
    }

    @Test func aPresenceUpdateIsTheSameStay() throws {
        session.roomPresence(presence("Alice"), room: room)
        say("g1")
        session.roomPresence(presence("Alice", show: "away"), room: room)
        say("g2", correction)
        #expect(try stored("g1").body == "pwned")
    }

    @Test func aNicknameChangeEndsTheStayUnderTheOldNickname() throws {
        session.roomPresence(presence("Alice"), room: room)
        say("g1")
        session.roomPresence(presence("Alice", type: "unavailable", extra: "<status code='303'/>", renamedTo: "Alicia"), room: room)
        session.roomPresence(presence("Alicia"), room: room)
        session.roomPresence(presence("Alice"), room: room)
        say("g2", correction)
        #expect(try stored("g1").body == "hi all")
    }

    @Test func aMessageFromSomeoneNotInTheRoomIsNotPlacedInAStay() throws {
        say("g1")
        #expect(try stored("g1").presenceSession == nil)
    }

    @Test func aReplayedMessageIsNotPlacedInAStay() throws {
        session.roomPresence(presence("Alice"), room: room)
        session.handleRoomStanza(
            parseStanza("<message from='\(room)/Alice' type='groupchat' id='g1'><body>old</body><delay xmlns='urn:xmpp:delay' stamp='2020-01-01T00:00:00Z'/></message>"),
            source: .live,
        )
        #expect(try stored("g1").presenceSession == nil)
        say("g2", correction)
        #expect(try stored("g1").body == "old")
    }
}
