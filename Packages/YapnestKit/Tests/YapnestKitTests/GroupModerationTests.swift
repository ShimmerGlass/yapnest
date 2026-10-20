import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let anna = YapnestKit.JID("anna@example.org")!
private let ben = YapnestKit.JID("ben@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

// MARK: Who may act on whom

struct ModerationPermissionTests {
    private func actions(_ actor: RoomAffiliation, _ target: RoomAffiliation, isSelf: Bool = false) -> GroupModeration.MemberActions {
        GroupModeration.actions(by: actor, on: target, isSelf: isSelf)
    }

    @Test func ownersMayActOnEveryone() {
        let member = actions(.owner, .member)
        #expect(member.canRemove && member.canBan && member.canMakeAdmin && !member.canRemoveAdmin)
        let admin = actions(.owner, .admin)
        #expect(admin.canRemove && admin.canBan && !admin.canMakeAdmin && admin.canRemoveAdmin)
        let owner = actions(.owner, .owner)
        #expect(owner.canRemove && owner.canBan && !owner.canMakeAdmin && !owner.canRemoveAdmin)
    }

    @Test func adminsMayOnlyActOnMembers() {
        let member = actions(.admin, .member)
        #expect(member.canRemove && member.canBan)
        // Making admins, and unmaking them, is for owners (§10.5).
        #expect(!member.canMakeAdmin && !member.canRemoveAdmin)
        #expect(actions(.admin, .admin).isEmpty)
        #expect(actions(.admin, .owner).isEmpty)
    }

    @Test func membersAndOutsidersMayNotModerate() {
        for actor in [RoomAffiliation.member, .none, .outcast] {
            for target in [RoomAffiliation.owner, .admin, .member, .none, .outcast] {
                #expect(actions(actor, target).isEmpty, "\(actor) on \(target)")
            }
        }
    }

    @Test func nobodyActsOnThemselves() {
        // Except an owner giving up ownership, unless the last one (see RoomManagementPermissionTests).
        #expect(actions(.admin, .admin, isSelf: true).isEmpty)
        #expect(actions(.owner, .owner, isSelf: true).isEmpty)
    }

    @Test func someoneAlreadyBannedCanOnlyBeUnbanned() {
        for actor in [RoomAffiliation.owner, .admin] {
            var result = actions(actor, .outcast)
            #expect(result.canUnban)
            result.canUnban = false
            #expect(result.isEmpty)
        }
    }

    @Test func aRoomsAffiliationsComeFromPresenceThenTheMemberLists() {
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.setAffiliation(.admin, of: anna)
        status.setAffiliation(.member, of: ben)
        #expect(status.affiliation(of: anna) == .admin)
        // A member the lists name without saying which kind.
        #expect(status.affiliation(of: ben) == .member)
        #expect(status.affiliation(of: me) == .none)
        status.occupants["annie"] = RoomOccupant(nick: "annie", jid: anna, affiliation: .owner, role: "moderator")
        #expect(status.affiliation(of: anna) == .owner)
    }

    @Test func onlyModeratorsOfAnAdvertisingRoomMayRetract() {
        var status = RoomStatus(phase: .joined, nickname: "me")
        #expect(!status.canModerateMessages)
        status.supportsModeration = true
        #expect(!status.canModerateMessages)
        status.role = "moderator"
        #expect(status.canModerateMessages)
        status.supportsModeration = false
        #expect(!status.canModerateMessages)
    }
}

// MARK: Stanzas

struct ModerationStanzaTests {
    @Test func anAffiliationChangeIsOneItemInAnAdminQuery() throws {
        let iq = OutboundStanza.affiliation(.outcast, of: anna, in: room)
        #expect(iq.type == .set)
        #expect(iq.to?.stringValue == room.description)
        let query = try #require(iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin"))
        let items = query.filterChildren(name: "item", xmlns: nil)
        #expect(items.count == 1)
        #expect(items.first?.getAttribute("jid") == "anna@example.org")
        #expect(items.first?.getAttribute("affiliation") == "outcast")
        // No reason: the room would tell everyone present.
        #expect(items.first?.firstChild(name: "reason") == nil)
    }

    @Test func aModeratedRetractionNamesTheRoomsStanzaId() throws {
        let iq = OutboundStanza.moderatedRetraction(of: "stanza-9", in: room)
        #expect(iq.type == .set)
        #expect(iq.to?.stringValue == room.description)
        let moderate = try #require(iq.firstChild(name: "moderate", xmlns: "urn:xmpp:message-moderate:1"))
        #expect(moderate.getAttribute("id") == "stanza-9")
        #expect(moderate.firstChild(name: "retract", xmlns: "urn:xmpp:message-retract:1") != nil)
    }
}

// MARK: Receiving a moderator's retraction

private func announcement(from: String, target: String = "room-1", v0: Bool = false) -> Martin.Message {
    let content = v0
        ? "<apply-to xmlns='urn:xmpp:fasten:0' id='\(target)'><moderated xmlns='urn:xmpp:message-moderate:0' by='mod'><retract xmlns='urn:xmpp:message-retract:0'/></moderated></apply-to>"
        : "<retract xmlns='urn:xmpp:message-retract:1' id='\(target)'><moderated xmlns='urn:xmpp:message-moderate:1'><occupant-id xmlns='urn:xmpp:occupant-id:0' id='o'/></moderated></retract>"
    return parseStanza("<message from='\(from)' type='groupchat' id='a1'>\(content)</message>")
}

struct ModeratedRetractionTests {
    let database: AppDatabase
    let session: XMPPSession

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
    }

    private func store(_ body: String, from nick: String, stanzaId: String) throws {
        let xml = "<message from='cake@rooms.example.org/\(nick)' type='groupchat' id='m-\(stanzaId)'><body>\(body)</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='\(stanzaId)'/></message>"
        session.handleRoomStanza(parseStanza(xml), source: .live)
    }

    private func messages() throws -> [YapnestKit.Message] {
        try database.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    @Test func theRoomsRetractionEmptiesSomeoneElsesMessage() throws {
        try store("rude words", from: "anna", stanzaId: "room-1")
        try store("hello", from: "ben", stanzaId: "room-2")
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org"), source: .live)
        let stored = try messages()
        #expect(stored[0].isRetracted && stored[0].isModerated)
        #expect(stored[0].body == "")
        #expect(!stored[1].isRetracted && stored[1].body == "hello")
    }

    @Test func theOlderFormWorksToo() throws {
        try store("rude words", from: "anna", stanzaId: "room-1")
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org", v0: true), source: .live)
        #expect(try messages()[0].isModerated)
    }

    @Test func anOccupantsForgedRetractionChangesNothing() throws {
        try store("keep me", from: "anna", stanzaId: "room-1")
        // Mallory writes the room's announcement under their own nickname.
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org/mallory"), source: .live)
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org/mallory", v0: true), source: .live)
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(!stored[0].isRetracted && !stored[0].isModerated)
        #expect(stored[0].body == "keep me")
    }

    @Test func aRetractionFromAnotherRoomChangesNothing() throws {
        try store("keep me", from: "anna", stanzaId: "room-1")
        let other = YapnestKit.JID("book@rooms.example.org")!
        try database.joinGroupChat(other, nickname: "me")
        session.handleRoomStanza(announcement(from: "book@rooms.example.org"), source: .live)
        #expect(try messages()[0].isRetracted == false)
    }

    @Test func itOnlyWorksOnTheRoomsOwnStanzaIds() throws {
        // Matching the sender's own id would let anyone name a victim's message.
        let xml = "<message from='cake@rooms.example.org/anna' type='groupchat' id='room-1'><body>mine</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='real-id'/></message>"
        session.handleRoomStanza(parseStanza(xml), source: .live)
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org", target: "room-1"), source: .live)
        #expect(try messages()[0].isRetracted == false)
    }

    @Test func aReplayOfItIsHarmless() throws {
        try store("rude words", from: "anna", stanzaId: "room-1")
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org"), source: .live)
        session.handleRoomStanza(announcement(from: "cake@rooms.example.org"), source: .archive(serverId: "x", timestamp: Date()))
        #expect(try messages().count == 1)
        #expect(try messages()[0].isModerated)
    }

    @Test func anAuthorsOwnRetractionIsNotModerated() throws {
        try store("oops", from: "anna", stanzaId: "room-1")
        session.handleRoomStanza(parseStanza("<message from='cake@rooms.example.org/anna' type='groupchat' id='r'><retract xmlns='urn:xmpp:message-retract:1' id='room-1'/></message>"), source: .live)
        let stored = try messages()
        #expect(stored[0].isRetracted)
        #expect(!stored[0].isModerated)
    }

    @Test func theParserNeedsTheRoomsBareAddress() {
        #expect(XMPPSession.moderatedRetraction(in: announcement(from: "cake@rooms.example.org")) == "room-1")
        #expect(XMPPSession.moderatedRetraction(in: announcement(from: "cake@rooms.example.org", v0: true)) == "room-1")
        #expect(XMPPSession.moderatedRetraction(in: announcement(from: "cake@rooms.example.org/x")) == nil)
        // A plain retraction, which anyone may send of their own, isn't one.
        let plain: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='groupchat'><retract xmlns='urn:xmpp:message-retract:1' id='room-1'/></message>")
        #expect(XMPPSession.moderatedRetraction(in: plain) == nil)
    }
}

// MARK: Acting

struct ModerationSessionTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        wire.answer { FakeWire.result(to: $0) }
    }

    private func join(as affiliation: RoomAffiliation, role: String = "moderator", others: [YapnestKit.JID: RoomAffiliation] = [:]) {
        session.updateRoom(room) { status in
            var joined = RoomStatus(phase: .joined, nickname: "me")
            joined.affiliation = affiliation
            joined.role = role
            joined.supportsModeration = true
            for (jid, affiliation) in others { joined.setAffiliation(affiliation, of: jid) }
            status = joined
        }
    }

    /// Only the moderation requests, not whatever else the session wrote.
    private var requests: [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter {
            $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin") != nil || $0.firstChild(name: "moderate", xmlns: "urn:xmpp:message-moderate:1") != nil
        }
    }

    @Test func anOwnerRemovesAMemberAndTheListFollows() async throws {
        join(as: .owner, others: [anna: .member, ben: .member])
        try await session.removeMember(anna, from: room)
        let item = try #require(requests.last?.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin")?.firstChild(name: "item"))
        #expect(item.getAttribute("affiliation") == "none")
        #expect(item.getAttribute("jid") == "anna@example.org")
        #expect(session.roomStatus(room)?.members == [ben])
        #expect(session.roomStatus(room)?.memberAffiliations[anna] == nil)
    }

    @Test func banningRecordsAnOutcast() async throws {
        join(as: .admin, others: [anna: .member])
        try await session.banMember(anna, from: room)
        let item = try #require(requests.last?.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#admin")?.firstChild(name: "item"))
        #expect(item.getAttribute("affiliation") == "outcast")
        #expect(session.roomStatus(room)?.members == [])
    }

    @Test func ownersMakeAndUnmakeAdmins() async throws {
        join(as: .owner, others: [anna: .member])
        try await session.setAdmin(true, member: anna, in: room)
        #expect(session.roomStatus(room)?.memberAffiliations[anna] == .admin)
        #expect(requests.last?.firstChild(name: "query")?.firstChild(name: "item")?.getAttribute("affiliation") == "admin")
        try await session.setAdmin(false, member: anna, in: room)
        #expect(session.roomStatus(room)?.memberAffiliations[anna] == .member)
        #expect(requests.last?.firstChild(name: "query")?.firstChild(name: "item")?.getAttribute("affiliation") == "member")
    }

    @Test func nothingIsSentForWhatIsNotAllowed() async throws {
        join(as: .admin, others: [anna: .admin, ben: .owner])
        await #expect(throws: GroupError.self) { try await session.removeMember(anna, from: room) }
        await #expect(throws: GroupError.self) { try await session.banMember(ben, from: room) }
        await #expect(throws: GroupError.self) { try await session.setAdmin(true, member: anna, in: room) }
        await #expect(throws: GroupError.self) { try await session.removeMember(me, from: room) }
        join(as: .member, others: [anna: .member])
        await #expect(throws: GroupError.self) { try await session.removeMember(anna, from: room) }
        #expect(requests.isEmpty)
    }

    @Test func aRefusalFromTheRoomIsReportedAndChangesNothing() async throws {
        join(as: .owner, others: [anna: .member])
        wire.answer { FakeWire.error(to: $0, condition: "forbidden") }
        await #expect(throws: (any Error).self) { try await session.removeMember(anna, from: room) }
        #expect(session.roomStatus(room)?.members == [anna])
    }

    @Test func offlineFails() async throws {
        let offline = try makeSession(me, database: database)
        await #expect(throws: GroupError.self) { try await offline.removeMember(anna, from: room) }
    }

    @Test func theRoomTellsAboutMembersWhoAreNotHere() throws {
        join(as: .owner, others: [anna: .member])
        let removed: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='groupchat'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='none' jid='anna@example.org'/></x></message>")
        session.handleRoomStanza(removed, source: .live)
        #expect(session.roomStatus(room)?.members == [])
        let added: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='groupchat'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='admin' jid='ben@example.org'/></x></message>")
        session.handleRoomStanza(added, source: .live)
        #expect(session.roomStatus(room)?.memberAffiliations[ben] == .admin)
    }

    // MARK: Messages

    private func store(from nick: String, stanzaId: String) async throws -> YapnestKit.Message {
        let xml = "<message from='cake@rooms.example.org/\(nick)' type='groupchat' id='m-\(stanzaId)'><body>hi</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='\(stanzaId)'/></message>"
        session.handleRoomStanza(parseStanza(xml), source: .live)
        return try #require(try await database.reader.read { try YapnestKit.Message.filter(Column("serverId") == stanzaId).fetchOne($0) })
    }

    @Test func aModeratorRetractsForEveryone() async throws {
        join(as: .admin)
        let message = try await store(from: "anna", stanzaId: "s-1")
        try await session.retractForEveryone(message)
        let moderate = try #require(requests.last?.firstChild(name: "moderate", xmlns: "urn:xmpp:message-moderate:1"))
        #expect(moderate.getAttribute("id") == "s-1")
        let stored = try #require(try await database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id) })
        #expect(stored.isRetracted && stored.isModerated)
    }

    @Test func aParticipantCannot() async throws {
        join(as: .member, role: "participant")
        let message = try await store(from: "anna", stanzaId: "s-1")
        await #expect(throws: GroupError.self) { try await session.retractForEveryone(message) }
        #expect(requests.isEmpty)
    }

    @Test func aRoomWithoutTheFeatureCannot() async throws {
        join(as: .owner)
        session.updateRoom(room) { $0?.supportsModeration = false }
        let message = try await store(from: "anna", stanzaId: "s-1")
        await #expect(throws: GroupError.self) { try await session.retractForEveryone(message) }
        #expect(requests.isEmpty)
    }

    @Test func aRefusalLeavesTheMessage() async throws {
        join(as: .owner)
        let message = try await store(from: "anna", stanzaId: "s-1")
        wire.answer { FakeWire.error(to: $0, condition: "forbidden") }
        await #expect(throws: (any Error).self) { try await session.retractForEveryone(message) }
        let stored = try #require(try await database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id) })
        #expect(!stored.isRetracted)
    }
}

// MARK: Affiliation notices

struct AffiliationNoticeTests {
    let database: AppDatabase
    let session: XMPPSession
    let absent = YapnestKit.JID("zoe@example.org")!

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
    }

    private func notice(from: String, type: String? = nil, affiliation: String = "member") -> Martin.Message {
        let type = type.map { " type='\($0)'" } ?? ""
        return parseStanza("""
            <message from='\(from)'\(type)><x xmlns='http://jabber.org/protocol/muc#user'>
              <item affiliation='\(affiliation)' jid='zoe@example.org'/></x></message>
            """)
    }

    @Test func aTypelessNoticeFromTheRoomIsApplied() {
        // ejabberd and Prosody send the notice for someone who isn't in the room without a type.
        session.handleTopLevel(notice(from: "cake@rooms.example.org"))
        #expect(session.roomStatus(room)?.affiliation(of: absent) == .member)
    }

    @Test func aGroupchatNoticeFromTheRoomIsApplied() {
        session.handleTopLevel(notice(from: "cake@rooms.example.org", type: "groupchat", affiliation: "admin"))
        #expect(session.roomStatus(room)?.affiliation(of: absent) == .admin)
    }

    @Test func anArchivedNoticeIsIgnored() {
        session.handleRoomStanza(notice(from: "cake@rooms.example.org", type: "groupchat"), source: .archive(serverId: "x", timestamp: Date()))
        #expect(session.roomStatus(room)?.affiliation(of: absent) == RoomAffiliation.none)
    }

    @Test func aNoticeReplayedAsJoinHistoryIsIgnored() {
        // The room's history on joining is live traffic that only carries a delay.
        let replayed: Martin.Message = parseStanza("""
            <message from='cake@rooms.example.org' type='groupchat'>
              <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' jid='zoe@example.org'/></x>
              <delay xmlns='urn:xmpp:delay' from='cake@rooms.example.org' stamp='2020-01-01T00:00:00Z'/></message>
            """)
        session.handleTopLevel(replayed)
        #expect(session.roomStatus(room)?.affiliation(of: absent) == RoomAffiliation.none)
        session.handleRoomStanza(replayed, source: .live)
        #expect(session.roomStatus(room)?.affiliation(of: absent) == RoomAffiliation.none)
    }

    @Test func aNoticeFromAnOccupantIsIgnored() {
        session.handleTopLevel(notice(from: "cake@rooms.example.org/mallory"))
        session.handleTopLevel(notice(from: "cake@rooms.example.org/mallory", type: "groupchat"))
        #expect(session.roomStatus(room)?.affiliation(of: absent) == RoomAffiliation.none)
    }

    @Test func aNoticeFromARoomWeAreNotInIsIgnored() {
        let other = YapnestKit.JID("book@rooms.example.org")!
        session.handleTopLevel(notice(from: "book@rooms.example.org"))
        #expect(session.roomStatus(other) == nil)
        #expect(session.roomStatus(room)?.affiliation(of: absent) == RoomAffiliation.none)
    }
}
