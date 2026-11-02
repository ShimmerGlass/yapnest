import Foundation
import GRDB
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// A room's service could add someone who then receives everything we
/// encrypt there, so a private group's chat says who became a member and who
/// stopped being one, from the member lists and affiliation notices. Who is
/// online says nothing about that, and other groups say nothing at all.
struct RoomRosterTests {
    let database: AppDatabase
    let session: XMPPSession
    let conversationId: Int64

    /// A group we are joining, `isPrivate` or not, whose room shows addresses
    /// unless `showsAddresses` is off.
    init(isPrivate: Bool = true, showsAddresses: Bool = true) throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        conversationId = try database.joinGroupChat(room, nickname: "me").conversationId
        try database.updateGroupChat(room) {
            $0.isMembersOnly = isPrivate
            $0.isNonAnonymous = showsAddresses
        }
        session.reloadKnownRooms()
        self.showsAddresses = showsAddresses
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me") }
    }

    private let showsAddresses: Bool

    private func presence(_ nick: String, jid: String? = nil, type: String? = nil, show: String? = nil, statuses: [Int] = [], renamedTo: String? = nil, affiliation: String = "member") -> Martin.Presence {
        let address = showsAddresses ? " jid='\(jid ?? "\(nick.lowercased())@example.org")/phone'" : ""
        let type = type.map { " type='\($0)'" } ?? ""
        let show = show.map { "<show>\($0)</show>" } ?? ""
        let codes = statuses.map { "<status code='\($0)'/>" }.joined()
        return parseStanza("<presence from='\(room)/\(nick)'\(type)>\(show)<x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='\(affiliation)' role='participant'\(address)\(renamedTo.map { " nick='\($0)'" } ?? "")/>\(codes)</x></presence>")
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

    private func join(_ nicks: String...) {
        for nick in nicks { session.roomPresence(presence(nick), room: room) }
        finishJoin()
    }

    private func rejoin(_ nicks: String...) {
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me") }
        for nick in nicks { session.roomPresence(presence(nick), room: room) }
        finishJoin()
    }

    private struct Line: Equatable {
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

    private func joined(_ name: String) -> Line { Line(event: .joinedGroup, nick: nil, sender: address(name)) }

    private func left(_ name: String) -> Line { Line(event: .leftGroup, nick: nil, sender: address(name)) }

    private func counted() throws -> Set<String> {
        try database.reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT jid FROM groupRoster WHERE conversationId = ?", arguments: [conversationId]))
        }
    }

    private func isBaselineBegun() throws -> Bool {
        try database.reader.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM groupRosterTaken WHERE conversationId = ?)", arguments: [conversationId]) } ?? false
    }

    private func address(_ name: String) -> YapnestKit.JID { YapnestKit.JID("\(name.lowercased())@example.org")! }

    /// A fetch of every member list that came whole, naming `names`.
    private func list(_ names: String...) { list(all: names) }

    private func list(all names: [String]) {
        let members = names.map(address)
        session.rosterListed(room, members: members)
        session.rosterListingDone(room, members: members, since: Date().addingTimeInterval(60))
        session.settleRoster()
    }

    private func isListed() throws -> Bool? {
        try database.reader.read { try Bool.fetchOne($0, sql: "SELECT listed FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId]) }
    }

    /// When a fetch, a baseline or a count is said to have happened, in seconds from now.
    private func at(_ seconds: Double) -> Date { Date().addingTimeInterval(seconds) }

    /// The first complete listing after the first join, which is the baseline.
    private func baseline(_ names: String...) {
        join("Alice")
        list(all: names)
    }

    private func affiliation(_ jid: String, _ affiliation: String) -> Martin.Message {
        parseStanza("<message from='\(room)' type='groupchat'><x xmlns='http://jabber.org/protocol/muc#user'><item jid='\(jid)' affiliation='\(affiliation)'/></x></message>")
    }

    // MARK: Presence says nothing

    @Test func theFirstJoinBeginsTheBaselineAndCountsNobodyFromPresence() throws {
        join("Alice", "Bob")
        #expect(try lines().isEmpty)
        #expect(try counted().isEmpty)
        #expect(try isBaselineBegun())
    }

    @Test func someoneArrivingOrChangingShowWritesNoLine() throws {
        baseline("Alice", "Carol")
        arrive("Carol")
        session.roomPresence(presence("Carol", show: "away"), room: room)
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org", "carol@example.org"])
    }

    @Test func aMemberGoingOfflineAndComingBackWritesNothing() throws {
        baseline("Alice", "Bob")
        leave("Bob")
        arrive("Bob")
        leave("Bob")
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org", "bob@example.org"], "being offline doesn't end membership")
    }

    @Test func ourRejoinWritesNothingEvenWhenPeopleCameAndWentMeanwhile() throws {
        baseline("Alice", "Bob", "Carol", "Dave")
        rejoin("Alice", "Carol", "Dave")
        #expect(try lines().isEmpty)
        rejoin("Alice", "Bob", "Dave")
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org", "bob@example.org", "carol@example.org", "dave@example.org"])
    }

    @Test func aKickWithoutAnAffiliationChangeWritesNothing() throws {
        baseline("Alice", "Bob")
        leave("Bob", statuses: [307])
        arrive("Bob")
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org", "bob@example.org"])
    }

    @Test func aNicknameChangeWritesNothing() throws {
        baseline("Alice", "Bob")
        session.roomPresence(presence("Bob", type: "unavailable", statuses: [303], renamedTo: "Bobby"), room: room)
        session.roomPresence(presence("Bobby", jid: "bob@example.org"), room: room)
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org", "bob@example.org"])
    }

    @Test func ourOwnJoinsAndLeavesNeverWriteALine() throws {
        baseline("Alice")
        session.roomPresence(presence("me", jid: "me@example.org"), room: room)
        session.roomPresence(presence("Phone", jid: "me@example.org"), room: room)
        session.roomPresence(presence("Phone", jid: "me@example.org", type: "unavailable", statuses: [301]), room: room)
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org"])
    }

    // MARK: The baseline

    @Test func theFirstCompleteListingIsCountedWithoutLinesInBothDirections() throws {
        join("Alice")
        session.rosterListed(room, members: [address("alice"), address("erin")])
        session.settleRoster()
        #expect(try counted() == ["alice@example.org", "erin@example.org"])
        list("Alice", "Zed")
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org", "zed@example.org"], "erin is dropped quietly")
    }

    @Test func membersListedBeforeTheFirstListingIsDoneAreQuiet() throws {
        join("Alice")
        session.rosterListed(room, members: [address("erin")])
        session.rosterListed(room, members: [address("zed")])
        session.settleRoster()
        #expect(try lines().isEmpty)
    }

    @Test func aMemberListBeforeTheFirstJoinCountsNothing() throws {
        session.rosterListed(room, members: [address("erin")])
        session.rosterListingDone(room, members: [address("erin")], since: Date().addingTimeInterval(60))
        session.settleRoster()
        #expect(try counted().isEmpty)
    }

    @Test func leavingAGroupMakesTheNextJoinAFirstOne() throws {
        baseline("Alice")
        session.rosterForget(room)
        session.settleRoster()
        #expect(try counted().isEmpty)
        #expect(try !isBaselineBegun())
        rejoin()
        list("Bob")
        #expect(try lines().isEmpty)
    }

    // MARK: Listings

    @Test func aMemberAddedWhileWeWereAwayIsAnnouncedByTheNextListing() throws {
        baseline("Alice", "Erin")
        rejoin("Alice")
        session.rosterListed(room, members: [address("erin"), address("zed"), me])
        session.settleRoster()
        #expect(try lines() == [joined("Zed")])
        session.rosterListed(room, members: [address("zed")])
        session.settleRoster()
        #expect(try lines().count == 1)
    }

    @Test func aCompleteListingThatDropsACountedMemberWritesOneLeftLine() throws {
        baseline("Alice", "Bob")
        list("Alice")
        #expect(try lines() == [left("Bob")])
        #expect(try counted() == ["alice@example.org"])
        list("Alice")
        #expect(try lines().count == 1, "and isn't said again")
    }

    @Test func aMemberWhoIsListedAgainAfterLeavingIsAnnouncedAgain() throws {
        baseline("Alice", "Bob")
        list("Alice")
        list("Alice", "Bob")
        #expect(try lines().map(\.event) == [.leftGroup, .joinedGroup])
    }

    @Test func aMemberWhoIsOnlyOfflineIsNotMissedByTheListing() throws {
        baseline("Alice", "Bob")
        leave("Bob")
        list("Alice", "Bob")
        #expect(try lines().isEmpty)
    }

    // MARK: The room changing who is a member

    @Test func theRoomAddingAMemberWhoIsNotHereWritesALine() throws {
        baseline("Alice")
        session.affiliationChanged(in: room, affiliation("zed@example.org", "member"))
        session.settleRoster()
        #expect(try lines() == [joined("Zed")])
        #expect(try counted() == ["alice@example.org", "zed@example.org"])
        session.affiliationChanged(in: room, affiliation("zed@example.org", "admin"))
        session.affiliationChanged(in: room, affiliation("alice@example.org", "admin"))
        session.settleRoster()
        #expect(try lines().count == 1, "a promotion, or someone already counted, is not news")
    }

    @Test func aPromotionBeforeTheFirstListingIsDoneIsCountedQuietly() throws {
        join("Alice")
        session.affiliationChanged(in: room, affiliation("bob@example.org", "admin"))
        session.settleRoster()
        #expect(try lines().isEmpty, "a member made admin before the listing counted them was there all along")
        #expect(try counted() == ["bob@example.org"])
        list("Bob")
        #expect(try lines().isEmpty)
    }

    @Test func theRoomAddingOurselvesWritesNothing() throws {
        baseline("Alice")
        session.affiliationChanged(in: room, affiliation("me@example.org", "member"))
        session.settleRoster()
        #expect(try lines().isEmpty)
    }

    @Test func theRoomRemovingAnAbsentMembersAffiliationWritesALine() throws {
        baseline("Alice")
        session.affiliationChanged(in: room, affiliation("zed@example.org", "member"))
        session.affiliationChanged(in: room, affiliation("zed@example.org", "none"))
        session.settleRoster()
        #expect(try lines().map(\.event) == [.joinedGroup, .leftGroup])
        #expect(try counted() == ["alice@example.org"])
    }

    @Test func theRoomRemovingAPresentMembersAffiliationWritesALineAtOnce() throws {
        baseline("Alice", "Bob")
        arrive("Bob")
        session.affiliationChanged(in: room, affiliation("bob@example.org", "outcast"))
        session.settleRoster()
        #expect(try lines() == [left("Bob")])
        #expect(try counted() == ["alice@example.org"])
    }

    @Test func aRemovalToldByBothThePresenceAndTheAffiliationGivesOneLine() throws {
        baseline("Alice", "Bob", "Carol")
        arrive("Bob", "Carol")
        leave("Bob", statuses: [321])
        session.affiliationChanged(in: room, affiliation("bob@example.org", "none"))
        session.affiliationChanged(in: room, affiliation("carol@example.org", "outcast"))
        leave("Carol", statuses: [301])
        session.settleRoster()
        #expect(try lines().map(\.event) == [.leftGroup, .leftGroup])
        #expect(try counted() == ["alice@example.org"])
    }

    @Test func aPresenceThatEndsMembershipWritesALineWithoutAnAffiliationNotice() throws {
        baseline("Alice", "Bob")
        leave("Bob", statuses: [322])
        #expect(try lines() == [left("Bob")])
    }

    @Test func aBannedMemberTheServerAddsAgainIsAnnounced() throws {
        baseline("Alice", "Bob")
        leave("Bob", statuses: [301])
        list("Alice", "Bob")
        #expect(try lines().map(\.event) == [.leftGroup, .joinedGroup])
    }

    @Test func aRemovalOfSomeoneNeverCountedWritesNothing() throws {
        baseline("Alice")
        leave("Zed", statuses: [301])
        session.affiliationChanged(in: room, affiliation("zed@example.org", "outcast"))
        session.settleRoster()
        #expect(try lines().isEmpty)
    }

    @Test func aRemovalBeforeTheFirstListingIsQuietToo() throws {
        join("Alice")
        session.affiliationChanged(in: room, affiliation("zed@example.org", "member"))
        session.affiliationChanged(in: room, affiliation("zed@example.org", "none"))
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted().isEmpty)
    }

    // MARK: Presence that carries a membership

    @Test func aMemberArrivingWhoWasNotCountedIsAnnouncedOnce() throws {
        baseline("Alice")
        arrive("Carol")
        #expect(try lines() == [joined("Carol")])
        leave("Carol")
        arrive("Carol")
        #expect(try lines() == [joined("Carol")], "coming back says nothing")
        #expect(try counted() == ["alice@example.org", "carol@example.org"])
    }

    @Test func anArrivalWhoIsNotAMemberOrBeforeTheListingWritesNothing() throws {
        join("Alice")
        arrive("Carol")
        #expect(try lines().isEmpty)
        #expect(try counted() == ["carol@example.org"], "counted, but before the baseline's listing nothing is known to be new")
        list("Alice")
        session.roomPresence(presence("Dave", affiliation: "none"), room: room)
        session.roomPresence(presence("Eve", affiliation: "outcast"), room: room)
        session.settleRoster()
        #expect(try lines().isEmpty)
        #expect(try counted() == ["alice@example.org"])
    }

    // MARK: A fetch begun before a change

    @Test func aMemberCountedAfterAFetchBeganIsNotJudgedByItsListing() throws {
        let (begun, started, later) = (at(-300), at(-200), at(-100))
        try database.rosterSelfJoined(conversationId: conversationId, at: begun)
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [address("alice")], since: started, at: started)
        let fetchBegan = at(-50)
        try database.rosterAffiliated(conversationId: conversationId, room: room, jid: address("zed"), isMember: true, at: at(-40))
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [address("alice")], since: fetchBegan, at: later)
        #expect(try counted() == ["zed@example.org"])
        #expect(try lines() == [joined("Zed")])
    }

    @Test func aMemberCountedBeforeAFetchBeganAndNotNamedHasLeft() throws {
        try database.rosterSelfJoined(conversationId: conversationId, at: at(-300))
        try database.rosterListed(conversationId: conversationId, room: room, members: [address("zed")], at: at(-250))
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [address("zed")], since: at(-200), at: at(-200))
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [], since: at(-100), at: at(-100))
        #expect(try lines() == [left("Zed")])
    }

    @Test func aMemberCountedQuietlyAfterAFetchBeganIsNotDroppedByIt() throws {
        try database.rosterSelfJoined(conversationId: conversationId, at: at(-300))
        try database.rosterAffiliated(conversationId: conversationId, room: room, jid: address("zed"), isMember: true, at: at(-100))
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [address("alice")], since: at(-200), at: at(-50))
        #expect(try counted() == ["zed@example.org"])
        #expect(try lines().isEmpty)
        #expect(try isListed() == true)
    }

    @Test func aFetchBegunBeforeTheBaselineWasRestartedSaysNothingOfTheNewOne() throws {
        try database.rosterSelfJoined(conversationId: conversationId, at: at(-100))
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [address("alice")], since: at(-200), at: at(-90))
        #expect(try isListed() == false)
        try database.rosterListingRefused(conversationId: conversationId, since: at(-200))
        #expect(try isListed() == false)
        try database.rosterListingDone(conversationId: conversationId, room: room, members: [address("alice")], since: at(-50), at: at(-40))
        #expect(try isListed() == true)
        #expect(try counted().isEmpty)
    }

    @Test func aRefusedListingEndsTheBaselineWithoutJudgingAnyone() throws {
        try database.rosterSelfJoined(conversationId: conversationId, at: at(-100))
        try database.rosterListed(conversationId: conversationId, room: room, members: [address("zed")], at: at(-90))
        try database.rosterListingRefused(conversationId: conversationId, since: at(-50))
        #expect(try isListed() == true)
        #expect(try counted() == ["zed@example.org"])
        session.affiliationChanged(in: room, affiliation("erin@example.org", "member"))
        session.settleRoster()
        #expect(try lines() == [joined("Erin")])
    }

    // MARK: Which groups say

    @Test func aRoomThatStopsBeingPrivateCountsNothingMoreAndStartsAfreshWhenPrivateAgain() throws {
        baseline("Alice", "Bob")
        try database.setRoomInfo(room, name: nil, isMembersOnly: false, isNonAnonymous: true)
        #expect(try counted().isEmpty)
        #expect(try !isBaselineBegun())
        session.affiliationChanged(in: room, affiliation("zed@example.org", "member"))
        list("Alice")
        #expect(try lines().isEmpty)
        try database.setRoomInfo(room, name: nil, isMembersOnly: true, isNonAnonymous: true)
        #expect(try isBaselineBegun())
        list("Alice", "Zed")
        #expect(try lines().isEmpty, "the first listing after it became private is a baseline")
        list("Alice")
        #expect(try lines().count == 1)
    }

    @Test(arguments: [(false, true), (true, false), (false, false)])
    func aGroupThatIsNotPrivateWritesNoLines(isPrivate: Bool, showsAddresses: Bool) throws {
        let test = try RoomRosterTests(isPrivate: isPrivate, showsAddresses: showsAddresses)
        test.join("Alice", "Bob")
        test.arrive("Carol")
        test.leave("Bob", statuses: [301])
        test.leave("Carol", statuses: [307])
        test.rejoin("Alice")
        test.list("Alice", "Dave")
        test.list("Alice")
        test.session.affiliationChanged(in: room, test.affiliation("zed@example.org", "member"))
        test.session.affiliationChanged(in: room, test.affiliation("zed@example.org", "outcast"))
        test.session.settleRoster()
        #expect(try test.lines().isEmpty)
        #expect(try test.counted().isEmpty)
        #expect(try !test.isBaselineBegun())
    }

    // MARK: The lines are not messages

    @Test func theLinesAreNotUnreadNotThePreviewAndNotTheReadPoint() throws {
        baseline("Alice")
        let hello = try database.insert(YapnestKit.Message(conversationId: conversationId, direction: .incoming, sender: YapnestKit.JID("alice@example.org")!, body: "Hello nest", timestamp: Date().addingTimeInterval(-60), isRead: true, remoteId: "m1"))
        session.affiliationChanged(in: room, affiliation("bob@example.org", "member"))
        session.affiliationChanged(in: room, affiliation("bob@example.org", "none"))
        session.settleRoster()
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
