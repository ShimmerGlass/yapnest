import Foundation
import GRDB
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// A room's service could add someone who then receives everything we
/// encrypt there, so the chat says who joined and left, from the room's
/// presences and its affiliation notices.
struct RoomRosterTests {
    let database: AppDatabase
    let session: XMPPSession
    let conversationId: Int64

    /// A group we are joining, `isPrivate` or not, whose room shows addresses
    /// unless `showsAddresses` is off.
    init(isPrivate: Bool = true, showsAddresses: Bool = true, grace: TimeInterval = 120) throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        conversationId = try database.joinGroupChat(room, nickname: "me").conversationId
        try database.updateGroupChat(room) {
            $0.isMembersOnly = isPrivate
            $0.isNonAnonymous = showsAddresses
        }
        session.reloadKnownRooms()
        session.rosterGrace = grace
        self.showsAddresses = showsAddresses
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me") }
    }

    private let showsAddresses: Bool

    private func presence(_ nick: String, jid: String? = nil, type: String? = nil, show: String? = nil, statuses: [Int] = [], renamedTo: String? = nil) -> Martin.Presence {
        let address = showsAddresses ? " jid='\(jid ?? "\(nick.lowercased())@example.org")/phone'" : ""
        let type = type.map { " type='\($0)'" } ?? ""
        let show = show.map { "<show>\($0)</show>" } ?? ""
        let codes = statuses.map { "<status code='\($0)'/>" }.joined()
        return parseStanza("<presence from='\(room)/\(nick)'\(type)>\(show)<x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='participant'\(address)\(renamedTo.map { " nick='\($0)'" } ?? "")/>\(codes)</x></presence>")
    }

    private func arrive(_ nicks: String...) {
        for nick in nicks { session.roomPresence(presence(nick), room: room) }
        session.settleRoster()
    }

    private func leave(_ nick: String, statuses: [Int] = []) {
        session.roomPresence(presence(nick, type: "unavailable", statuses: statuses), room: room)
        session.settleRoster()
    }

    /// Our own presence, which ends the join.
    private func finishJoin() {
        session.roomPresence(parseStanza("<presence from='\(room)/me'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='participant'/><status code='110'/></x></presence>"), room: room)
        session.settleRoster()
    }

    private func join(_ nicks: String...) { join(all: nicks) }

    private func join(all nicks: [String]) {
        for nick in nicks { session.roomPresence(presence(nick), room: room) }
        finishJoin()
    }

    private func rejoin(_ nicks: String...) {
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me") }
        session.rosterJoinStarted(room)
        for nick in nicks { session.roomPresence(presence(nick), room: room) }
        finishJoin()
    }

    private struct Line: Equatable {
        func withoutNick() -> Line { Line(event: event, nick: nil, sender: sender) }
        let event: MessageEvent
        let nick: String?
        let sender: YapnestKit.JID
    }

    private func lines() throws -> [Line] {
        try database.reader.read { db in
            try YapnestKit.Message.filter(Column("event") != nil).order(Column("id")).fetchAll(db).map {
                #expect($0.direction == .event && $0.isRead && $0.body.isEmpty && $0.conversationId == conversationId)
                return Line(event: $0.event!, nick: $0.nick, sender: $0.sender)
            }
        }
    }

    private func joined(_ nick: String, _ jid: String? = nil) -> Line {
        Line(event: .joinedGroup, nick: nick, sender: YapnestKit.JID(jid ?? "\(nick.lowercased())@example.org")!)
    }

    private func left(_ nick: String, _ jid: String? = nil) -> Line {
        Line(event: .leftGroup, nick: nick, sender: YapnestKit.JID(jid ?? "\(nick.lowercased())@example.org")!)
    }

    private func counted() throws -> [String: Bool] {
        try database.reader.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, isPresent FROM groupRoster WHERE conversationId = ? AND NOT hasLeft", arguments: [conversationId]).map { ($0["key"] as String, $0["isPresent"] as Bool) })
        }
    }

    private func affiliation(_ jid: String, _ affiliation: String) -> Martin.Message {
        parseStanza("<message from='\(room)' type='groupchat'><x xmlns='http://jabber.org/protocol/muc#user'><item jid='\(jid)' affiliation='\(affiliation)'/></x></message>")
    }

    // MARK: Joining and arriving

    @Test func theFirstJoinCountsEveryoneWithoutALine() throws {
        join("Alice", "Bob")
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org": true, "bob@example.org": true])
        #expect(try database.reader.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM groupRosterTaken WHERE conversationId = ?)", arguments: [conversationId]) } == true)
    }

    @Test func someoneArrivingLaterWritesOneLineOnce() throws {
        join("Alice")
        arrive("Carol")
        #expect(try lines() == [joined("Carol")])
        session.roomPresence(presence("Carol", show: "away"), room: room)
        session.roomPresence(presence("Alice"), room: room)
        session.settleRoster()
        #expect(try lines() == [joined("Carol")], "a change of show is the same stay, and Alice was counted")
    }

    @Test func aMessageFromSomeoneNotPresentWritesNoLine() throws {
        join("Alice")
        session.handleRoomStanza(parseStanza("<message from='\(room)/Dave' type='groupchat' id='old'><body>hi</body></message>"), source: .live)
        session.settleRoster()
        #expect(try lines().isEmpty)
    }

    @Test func ourOwnJoinsAndLeavesNeverWriteALine() throws {
        join("Alice")
        session.roomPresence(presence("me", jid: "me@example.org"), room: room)
        session.roomPresence(presence("Phone", jid: "me@example.org"), room: room)
        session.roomPresence(presence("Phone", jid: "me@example.org", type: "unavailable", statuses: [307]), room: room)
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org": true])
    }

    @Test func ourOwnNicknameIsNotCountedInARoomWithoutAddresses() throws {
        let test = try RoomRosterTests(showsAddresses: false)
        test.join("Alice")
        test.session.roomPresence(test.presence("me"), room: room)
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        #expect(try test.counted() == ["Alice": true])
    }

    // MARK: Leaving

    @Test func aDepartureWritesALineOnlyAfterTheGrace() async throws {
        let test = try RoomRosterTests(grace: 0.2)
        test.join("Alice", "Bob")
        test.leave("Bob")
        #expect(try test.lines().isEmpty)
        await eventually("the line") { ((try? test.lines()) ?? []) == [test.left("Bob")] }
        #expect(try test.counted() == ["alice@example.org": true])
    }

    @Test func comingBackWithinTheGraceWritesNothing() async throws {
        let test = try RoomRosterTests(grace: 0.2)
        test.join("Alice", "Bob")
        test.leave("Bob")
        test.arrive("Bob")
        try await Task.sleep(for: .milliseconds(500))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        #expect(try test.counted() == ["alice@example.org": true, "bob@example.org": true])
    }

    @Test func comingBackUnderAnotherNicknameWithinTheGraceWritesNothing() async throws {
        let test = try RoomRosterTests(grace: 0.2)
        test.join("Alice", "Bob")
        test.leave("Bob")
        test.session.roomPresence(test.presence("Bobby", jid: "bob@example.org"), room: room)
        test.session.settleRoster()
        try await Task.sleep(for: .milliseconds(500))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
    }

    @Test func aNewConnectionDropsTheWaitingDepartures() async throws {
        let test = try RoomRosterTests(grace: 0.2)
        test.join("Alice", "Bob")
        test.leave("Bob")
        test.session.rosterReset()
        try await Task.sleep(for: .milliseconds(500))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
    }

    @Test func aDepartureWaitingWhenTheStreamDropsIsStillWrittenSinceAResumeSendsNothingAgain() async throws {
        let test = try RoomRosterTests(grace: 0.2)
        test.join("Alice", "Bob")
        test.leave("Bob")
        test.session.client.update(state: .disconnected())
        await eventually("the line") { ((try? test.lines()) ?? []) == [test.left("Bob")] }
    }

    @Test func aKickOfOneNicknameLeavesSomeoneStillHereUnderAnotherCounted() throws {
        join("Alice", "Bob")
        session.roomPresence(presence("Bobby", jid: "bob@example.org"), room: room)
        session.settleRoster()
        leave("Bob", statuses: [307])
        #expect(try lines().isEmpty)
        #expect(try counted()["bob@example.org"] == true)
    }

    @Test func theDepartureStatusesAreTheRemovalsThatDoNotPass() {
        #expect(XMPPSession.departureStatuses == [301, 307, 321, 322])
    }

    @Test func aChangeOfShowCostsNoWrite() throws {
        join("Alice")
        try database.writer.write { try $0.execute(sql: "DELETE FROM groupRoster") }
        session.roomPresence(presence("Alice", show: "away"), room: room)
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted().isEmpty, "the same stay is not looked up again")
    }

    @Test func aKickAtOnceWritesALine() throws {
        join("Alice", "Bob")
        leave("Bob", statuses: [307])
        #expect(try lines() == [left("Bob")])
    }

    @Test func aBanAndARemovalAtOnceWriteALine() throws {
        join("Alice", "Bob", "Carol")
        leave("Bob", statuses: [301])
        leave("Carol", statuses: [321])
        #expect(try lines() == [left("Bob"), left("Carol")])
        #expect(try counted() == ["alice@example.org": true])
    }

    @Test func aNicknameChangeWritesNothing() async throws {
        let test = try RoomRosterTests(grace: 0.2)
        test.join("Alice", "Bob")
        test.session.roomPresence(test.presence("Bob", type: "unavailable", statuses: [303], renamedTo: "Bobby"), room: room)
        test.session.roomPresence(test.presence("Bobby", jid: "bob@example.org"), room: room)
        test.session.settleRoster()
        try await Task.sleep(for: .milliseconds(500))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        #expect(try test.counted() == ["alice@example.org": true, "bob@example.org": true])
    }

    @Test func inARoomWithoutAddressesTheNicknameIsTheKeyAndMovesWithTheChange() async throws {
        let test = try RoomRosterTests(showsAddresses: false, grace: 0.2)
        test.join("Alice", "Bob")
        #expect(try test.counted() == ["Alice": true, "Bob": true])
        test.session.roomPresence(test.presence("Bob", type: "unavailable", statuses: [303], renamedTo: "Bobby"), room: room)
        test.session.roomPresence(test.presence("Bobby"), room: room)
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        #expect(try test.counted() == ["Alice": true, "Bobby": true])
        test.leave("Bobby", statuses: [307])
        #expect(try test.lines() == [Line(event: .leftGroup, nick: "Bobby", sender: room)])
    }

    // MARK: Rejoining

    @Test func aRejoinWritesLinesForTheDifferenceOnly() throws {
        join("Alice", "Bob", "Dave")
        rejoin("Alice", "Carol", "Dave")
        #expect(try lines() == [left("Bob"), joined("Carol")])
        #expect(try counted() == ["alice@example.org": true, "carol@example.org": true, "dave@example.org": true])
        rejoin("Alice", "Carol", "Dave")
        #expect(try lines().count == 2)
    }

    @Test func membersFromTheListAreCountedQuietlyAndAreNotMissedOnARejoin() throws {
        join("Alice")
        session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!, YapnestKit.JID("alice@example.org")!, me])
        session.settleRoster()
        #expect(try counted() == ["alice@example.org": true, "erin@example.org": false])
        rejoin("Alice")
        #expect(try lines().isEmpty, "someone who was only listed was never here to leave")
        rejoin("Alice", "Erin")
        #expect(try lines().isEmpty, "and arriving, they were already counted")
        #expect(try counted()["erin@example.org"] == true)
    }

    @Test func aMemberListBeforeTheFirstJoinCountsNothing() throws {
        session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!])
        session.settleRoster()
        #expect(try counted().isEmpty)
    }

    @Test func leavingAGroupMakesTheNextJoinAFirstOne() throws {
        join("Alice")
        session.rosterForget(room)
        session.settleRoster()
        #expect(try counted().isEmpty)
        rejoin("Alice", "Bob")
        #expect(try lines().isEmpty)
    }

    // MARK: The room changing who is a member

    @Test func theRoomAddingAMemberWhoIsNotHereWritesALine() throws {
        join("Alice")
        session.affiliationChanged(in: room, affiliation("zed@example.org", "member"))
        session.settleRoster()
        #expect(try lines() == [Line(event: .joinedGroup, nick: nil, sender: YapnestKit.JID("zed@example.org")!)])
        #expect(try counted()["zed@example.org"] == false)
        session.affiliationChanged(in: room, affiliation("zed@example.org", "admin"))
        session.affiliationChanged(in: room, affiliation("alice@example.org", "admin"))
        session.settleRoster()
        #expect(try lines().count == 1, "a promotion, or someone already counted, is not news")
    }

    @Test func theRoomAddingOurselvesWritesNothing() throws {
        join("Alice")
        session.affiliationChanged(in: room, affiliation("me@example.org", "member"))
        session.settleRoster()
        #expect(try lines().isEmpty)
    }

    @Test func theRoomRemovingAnAbsentMembersAffiliationWritesALine() throws {
        join("Alice")
        session.affiliationChanged(in: room, affiliation("zed@example.org", "member"))
        session.affiliationChanged(in: room, affiliation("zed@example.org", "none"))
        session.settleRoster()
        #expect(try lines().map(\.event) == [.joinedGroup, .leftGroup])
        #expect(try counted() == ["alice@example.org": true])
    }

    @Test func theRoomRemovingAPresentMembersAffiliationLeavesTheirLeavingToThePresence() throws {
        join("Alice", "Bob")
        session.affiliationChanged(in: room, affiliation("bob@example.org", "outcast"))
        session.settleRoster()
        #expect(try lines().isEmpty)
        leave("Bob", statuses: [301])
        #expect(try lines() == [left("Bob")])
    }

    @Test func aModeratorsViewOfAddressesInARoomThatHidesThemChangesNoOne() throws {
        let test = try RoomRosterTests(showsAddresses: false)
        // As a moderator, we see Alice's address; after a rejoin as a participant, we don't.
        test.session.roomPresence(parseStanza("""
            <presence from='\(room)/Alice'><x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' jid='alice@example.org/phone'/></x></presence>
            """), room: room)
        test.finishJoin()
        test.rejoin("Alice")
        #expect(try test.lines().isEmpty)
        #expect(try test.counted() == ["Alice": true])
    }

    @Test func aRoomThatHidesAddressesCantAddSomeoneByAddress() throws {
        let test = try RoomRosterTests(showsAddresses: false)
        test.join("Alice")
        test.session.affiliationChanged(in: room, test.affiliation("bob@example.org", "member"))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        test.arrive("Bob")
        #expect(try test.lines().count == 1)
    }

    @Test func aMemberAddedWhileWeWereAwayIsAnnouncedByTheNextListing() throws {
        join("Alice")
        session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!])
        session.rosterListingDone(room)
        session.settleRoster()
        #expect(try lines().isEmpty, "the members listed after the first join were there")
        rejoin("Alice")
        session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!, YapnestKit.JID("zed@example.org")!, me])
        session.settleRoster()
        #expect(try lines() == [Line(event: .joinedGroup, nick: nil, sender: YapnestKit.JID("zed@example.org")!)])
        session.rosterListed(room, members: [YapnestKit.JID("zed@example.org")!])
        session.settleRoster()
        #expect(try lines().count == 1)
    }

    @Test func aMemberWhoLeftAndIsListedAgainGetsNoLine() async throws {
        let test = try RoomRosterTests(grace: 0.1)
        test.join("Alice", "Bob")
        test.session.rosterListingDone(room)
        test.leave("Bob")
        await eventually("the line") { ((try? test.lines()) ?? []).count == 1 }
        test.session.rosterListed(room, members: [YapnestKit.JID("bob@example.org")!, YapnestKit.JID("alice@example.org")!])
        test.session.settleRoster()
        #expect(try test.lines() == [test.left("Bob")])
        #expect(try test.counted() == ["alice@example.org": true])
    }

    @Test func aMemberWhoLeftAndComesBackIsAnnouncedOnceAgain() throws {
        join("Alice", "Bob")
        leave("Bob", statuses: [307])
        arrive("Bob")
        #expect(try lines() == [left("Bob"), joined("Bob")])
        arrive("Bob")
        #expect(try lines().count == 2)
        leave("Bob", statuses: [307])
        rejoin("Alice", "Bob")
        #expect(try lines() == [left("Bob"), joined("Bob"), left("Bob"), joined("Bob")], "found back by the end of a join")
    }

    @Test func aBannedMemberTheServerAddsAgainIsAnnounced() throws {
        join("Alice", "Bob")
        session.rosterListingDone(room)
        leave("Bob", statuses: [301])
        session.rosterListed(room, members: [YapnestKit.JID("bob@example.org")!])
        session.settleRoster()
        #expect(try lines() == [left("Bob"), joined("Bob", nil).withoutNick()])
    }

    @Test func membersListedBeforeTheFirstListingIsDoneAreQuiet() throws {
        join("Alice")
        session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!])
        session.rosterListed(room, members: [YapnestKit.JID("zed@example.org")!])
        session.settleRoster()
        #expect(try lines().isEmpty)
    }

    @Test func listsAndAffiliationsCountNothingInAGroupThatIsNotMembersOnly() throws {
        let test = try RoomRosterTests(isPrivate: false)
        test.join("Alice")
        test.session.rosterListingDone(room)
        test.session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!])
        test.session.affiliationChanged(in: room, test.affiliation("zed@example.org", "member"))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        #expect(try test.counted() == ["alice@example.org": true])
    }

    @Test func someoneCountedFromTheListIsNamedByTheNicknameTheyArriveWith() throws {
        join("Alice")
        session.rosterListed(room, members: [YapnestKit.JID("erin@example.org")!])
        session.settleRoster()
        arrive("Erin")
        leave("Erin", statuses: [307])
        #expect(try lines() == [left("Erin")])
    }

    @Test func aRoomThatStartsHidingAddressesIsCountedAfreshWithoutLines() throws {
        join("Alice", "Bob")
        try database.updateGroupChat(room) { $0.isNonAnonymous = false }
        session.rosterKeysChanged(room, isJoined: true)
        session.settleRoster()
        #expect(try counted() == ["Alice": true, "Bob": true])
        #expect(try lines().isEmpty)
        rejoin("Alice", "Bob")
        #expect(try lines().isEmpty, "the next join is compared with the new keys")
        try database.updateGroupChat(room) { $0.isNonAnonymous = true }
        session.rosterKeysChanged(room, isJoined: true)
        session.settleRoster()
        #expect(try counted() == ["alice@example.org": true, "bob@example.org": true])
    }

    // MARK: Which groups say

    @Test func aBigGroupThatIsNotPrivateWritesNoLinesButIsStillCounted() throws {
        let test = try RoomRosterTests(isPrivate: false)
        test.join(all: (0..<50).map { "User\($0)" })
        test.arrive("Late")
        #expect(try test.lines().isEmpty)
        #expect(try test.counted()["late@example.org"] == true)
        for index in 0..<10 { test.leave("User\(index)", statuses: [307]) }
        #expect(try test.counted().count == 41, "the baseline followed the group down")
        #expect(try test.lines().first == test.left("User1"), "the kick that left it above the limit said nothing")
        test.arrive("Later")
        #expect(try test.lines().last == test.joined("Later"), "the group shrank to a size that says")
    }

    @Test func aBigPrivateGroupAlwaysWritesLines() throws {
        join(all: (0..<60).map { "User\($0)" })
        arrive("Late")
        #expect(try lines() == [joined("Late")])
    }

    @Test func aSmallGroupThatIsNotPrivateWritesLines() throws {
        let test = try RoomRosterTests(isPrivate: false)
        test.join("Alice")
        test.arrive("Bob")
        #expect(try test.lines() == [test.joined("Bob")])
    }

    // MARK: The lines are not messages

    @Test func theLinesAreNotUnreadNotThePreviewAndNotTheReadPoint() throws {
        join("Alice")
        let hello = try database.insert(YapnestKit.Message(conversationId: conversationId, direction: .incoming, sender: YapnestKit.JID("alice@example.org")!, body: "Hello nest", timestamp: Date().addingTimeInterval(-60), isRead: true, remoteId: "m1"))
        arrive("Bob")
        leave("Bob", statuses: [307])
        #expect(try lines().count == 2)
        let item = try #require(try database.chatList().first)
        #expect(item.unreadCount == 0)
        #expect(item.lastMessage?.id == hello.id, "the preview is the last real message")
        #expect(try database.unreadCount() == 0)
        #expect(try database.lastIncoming(conversationId: conversationId)?.id == hello.id)
        try database.markUnread(conversationId: conversationId)
        #expect(try database.unreadCount() == 1)
        #expect(try database.reader.read { try YapnestKit.Message.filter(Column("event") != nil && Column("isRead") == false).fetchCount($0) } == 0)
    }
}
