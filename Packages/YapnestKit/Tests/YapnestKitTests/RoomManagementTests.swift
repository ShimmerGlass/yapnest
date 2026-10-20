import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let anna = YapnestKit.JID("anna@example.org")!
private let ben = YapnestKit.JID("ben@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private let adminNS = "http://jabber.org/protocol/muc#admin"
private let ownerNS = "http://jabber.org/protocol/muc#owner"

// MARK: Who may do what

struct RoomManagementPermissionTests {
    private func actions(
        _ actor: RoomAffiliation, _ target: RoomAffiliation, isSelf: Bool = false, isLastOwner: Bool = false,
        role: String? = nil, present: Bool = false,
    ) -> GroupModeration.MemberActions {
        GroupModeration.actions(by: actor, on: target, isSelf: isSelf, isLastOwner: isLastOwner, actorRole: role, targetIsPresent: present)
    }

    @Test func onlyOwnersMakeAndUnmakeOwners() {
        #expect(actions(.owner, .member).canMakeOwner)
        #expect(actions(.owner, .admin).canMakeOwner)
        #expect(!actions(.owner, .owner).canMakeOwner)
        #expect(actions(.owner, .owner).canRemoveOwner)
        #expect(!actions(.owner, .admin).canRemoveOwner)
        for actor in [RoomAffiliation.admin, .member, .none, .outcast] {
            for target in [RoomAffiliation.owner, .admin, .member, .none, .outcast] {
                let result = actions(actor, target)
                #expect(!result.canMakeOwner && !result.canRemoveOwner, "\(actor) on \(target)")
            }
        }
    }

    @Test func anOwnerMayStepDownUnlessTheLastOne() {
        #expect(actions(.owner, .owner, isSelf: true, isLastOwner: false).canRemoveOwner)
        #expect(!actions(.owner, .owner, isSelf: true, isLastOwner: true).canRemoveOwner)
        // Nothing else is done to oneself.
        var result = actions(.owner, .owner, isSelf: true, isLastOwner: false)
        result.canRemoveOwner = false
        #expect(result.isEmpty)
        #expect(actions(.admin, .admin, isSelf: true).isEmpty)
    }

    @Test func ownersAndAdminsUnbanTheBanned() {
        #expect(actions(.owner, .outcast).canUnban)
        #expect(actions(.admin, .outcast).canUnban)
        #expect(!actions(.member, .outcast).canUnban)
        #expect(!actions(.owner, .member).canUnban)
    }

    @Test func aModeratorKicksThoseBelowThemWhoArePresent() {
        #expect(actions(.admin, .member, role: "moderator", present: true).canKick)
        #expect(actions(.admin, .none, role: "moderator", present: true).canKick)
        #expect(actions(.owner, .admin, role: "moderator", present: true).canKick)
        #expect(actions(.owner, .member, role: "moderator", present: true).canKick)
    }

    @Test func aKickNeedsPresenceAndTheModeratorRole() {
        #expect(!actions(.admin, .member, role: "moderator", present: false).canKick)
        #expect(!actions(.admin, .member, role: "participant", present: true).canKick)
        #expect(!actions(.admin, .member, role: nil, present: true).canKick)
    }

    @Test func aKickNeverReachesEqualOrHigherStanding() {
        // §8.2: an admin can't kick an owner or another admin.
        #expect(!actions(.admin, .owner, role: "moderator", present: true).canKick)
        #expect(!actions(.admin, .admin, role: "moderator", present: true).canKick)
        #expect(!actions(.owner, .owner, role: "moderator", present: true).canKick)
        // A member who holds the moderator role can't kick another member.
        #expect(!actions(.member, .member, role: "moderator", present: true).canKick)
        #expect(!actions(.none, .none, role: "moderator", present: true).canKick)
    }

    @Test func nobodyKicksThemselves() {
        #expect(!actions(.owner, .owner, isSelf: true, role: "moderator", present: true).canKick)
    }

    @Test func theRoomStatusDecidesWhichControlsToShow() {
        var status = RoomStatus(phase: .joined, nickname: "me")
        #expect(!status.canEditInfo && !status.canDestroy && !status.canSeeBans && !status.canChangeSubject)
        status.affiliation = .admin
        status.role = "moderator"
        #expect(status.canSeeBans && status.canChangeSubject)
        #expect(!status.canEditInfo && !status.canDestroy)
        status.affiliation = .owner
        #expect(status.canEditInfo && status.canDestroy && status.canSeeBans)
        status.phase = .joining
        #expect(!status.canEditInfo && !status.canDestroy && !status.canSeeBans && !status.canChangeSubject)
    }

    @Test func participantsChangeTheSubjectOnlyWhereTheRoomLetsThem() {
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.affiliation = .member
        #expect(!status.canChangeSubject)
        status.participantsMayChangeSubject = false
        #expect(!status.canChangeSubject)
        status.participantsMayChangeSubject = true
        #expect(status.canChangeSubject)
        status.role = "visitor"
        #expect(!status.canChangeSubject)
    }

    @Test func theLastOwnerIsOneWithNoOtherKnown() {
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.affiliation = .owner
        status.setAffiliation(.owner, of: me)
        #expect(status.isLastOwner(me))
        status.setAffiliation(.owner, of: anna)
        #expect(!status.isLastOwner(me))
        status.setAffiliation(.member, of: anna)
        #expect(status.isLastOwner(me))
        // Present, with an address the room doesn't show.
        status.occupants["zed"] = RoomOccupant(nick: "zed", jid: nil, affiliation: .owner, role: "moderator")
        #expect(!status.isLastOwner(me))
    }

    @Test func bansFollowAffiliations() {
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.setAffiliation(.outcast, of: anna)
        #expect(status.banned == [anna])
        #expect(status.affiliation(of: anna) == .outcast)
        #expect(status.members.isEmpty)
        status.setAffiliation(.none, of: anna)
        #expect(status.banned.isEmpty)
        #expect(status.affiliation(of: anna) == RoomAffiliation.none)
    }
}

// MARK: Stanzas and forms

struct RoomManagementEncryptionTests {
    private func group(membersOnly: Bool, nonAnonymous: Bool) -> GroupChat {
        GroupChat(conversationId: 1, jid: room, nickname: "me", isMembersOnly: membersOnly, isNonAnonymous: nonAnonymous)
    }

    @Test func openingAPrivateGroupStopsItBeingPrivate() {
        let change = RoomConfiguration(isMembersOnly: false)
        #expect(group(membersOnly: true, nonAnonymous: true).wouldStopBeingPrivate(by: change))
    }

    @Test func hidingAddressesFromMembersStopsItBeingPrivate() {
        let change = RoomConfiguration(whoCanSeeAddresses: .moderators)
        #expect(group(membersOnly: true, nonAnonymous: true).wouldStopBeingPrivate(by: change))
    }

    @Test func otherChangesLeaveAPrivateGroupPrivate() {
        let private_ = group(membersOnly: true, nonAnonymous: true)
        #expect(!private_.wouldStopBeingPrivate(by: RoomConfiguration(name: "Roost", membersCanInvite: true)))
        #expect(!private_.wouldStopBeingPrivate(by: RoomConfiguration(isMembersOnly: true, whoCanSeeAddresses: .anyone)))
        #expect(!private_.wouldStopBeingPrivate(by: nil))
    }

    @Test func aGroupThatIsNotPrivateHasNothingToLose() {
        let change = RoomConfiguration(isMembersOnly: false, whoCanSeeAddresses: .moderators)
        #expect(!group(membersOnly: false, nonAnonymous: true).wouldStopBeingPrivate(by: change))
    }
}

struct RoomManagementStanzaTests {
    @Test func aKickSetsTheRoleOfANickname() throws {
        let iq = OutboundStanza.kick(nickname: "annie", reason: "Spam", in: room)
        #expect(iq.type == .set)
        #expect(iq.to?.stringValue == room.description)
        let item = try #require(iq.firstChild(name: "query", xmlns: adminNS)?.firstChild(name: "item"))
        #expect(item.getAttribute("nick") == "annie")
        #expect(item.getAttribute("role") == "none")
        #expect(item.getAttribute("affiliation") == nil)
        #expect(item.firstChild(name: "reason")?.value == "Spam")
        #expect(OutboundStanza.kick(nickname: "annie", reason: nil, in: room).firstChild(name: "query")?.firstChild(name: "item")?.firstChild(name: "reason") == nil)
    }

    @Test func aDestroyIsAnOwnerQuery() throws {
        let iq = OutboundStanza.destroy(room, reason: "Moving")
        #expect(iq.type == .set)
        let destroy = try #require(iq.firstChild(name: "query", xmlns: ownerNS)?.firstChild(name: "destroy"))
        #expect(destroy.firstChild(name: "reason")?.value == "Moving")
        #expect(OutboundStanza.destroy(room, reason: nil).firstChild(name: "query")?.firstChild(name: "destroy")?.firstChild(name: "reason") == nil)
    }
}

private func form(_ fields: [(String, String, [String])]) -> Element {
    let x = Element(name: "x", xmlns: "jabber:x:data")
    x.setAttribute("type", value: "form")
    for (name, type, values) in fields {
        let field = Element(name: "field")
        field.setAttribute("var", value: name)
        field.setAttribute("type", value: type)
        for value in values { field.addChild(Element(name: "value", cdata: value)) }
        x.addChild(field)
    }
    return x
}

private let fullForm: [(String, String, [String])] = [
    ("FORM_TYPE", "hidden", ["http://jabber.org/protocol/muc#roomconfig"]),
    ("muc#roomconfig_roomname", "text-single", ["Cake"]),
    ("muc#roomconfig_roomdesc", "text-single", ["About cake"]),
    ("muc#roomconfig_persistentroom", "boolean", ["1"]),
    ("muc#roomconfig_membersonly", "boolean", ["1"]),
    ("muc#roomconfig_whois", "list-single", ["anyone"]),
    ("muc#roomconfig_allowinvites", "boolean", ["0"]),
    ("muc#roomconfig_changesubject", "boolean", ["0"]),
    ("muc#roomconfig_getmemberlist", "list-multi", ["moderator", "participant"]),
]

struct RoomConfigurationTests {
    @Test func aFullFormIsRead() {
        let configuration = RoomConfiguration(form: form(fullForm))
        #expect(configuration == RoomConfiguration(
            name: "Cake", description: "About cake", isMembersOnly: true, whoCanSeeAddresses: .anyone,
            membersCanInvite: false, membersCanChangeSubject: false,
        ))
    }

    @Test func fieldsTheFormLacksAreNil() {
        let configuration = RoomConfiguration(form: form([
            ("muc#roomconfig_roomname", "text-single", ["Cake"]),
            ("muc#roomconfig_whois", "list-single", ["moderators"]),
        ]))
        #expect(configuration.name == "Cake")
        #expect(configuration.whoCanSeeAddresses == .moderators)
        #expect(configuration.description == nil)
        #expect(configuration.isMembersOnly == nil)
        #expect(configuration.membersCanInvite == nil)
        #expect(configuration.membersCanChangeSubject == nil)
        #expect(RoomConfiguration(form: nil) == RoomConfiguration())
    }

    @Test func booleansMayBeWrittenEitherWay() {
        let configuration = RoomConfiguration(form: form([
            ("muc#roomconfig_membersonly", "boolean", ["true"]),
            ("muc#roomconfig_allowinvites", "boolean", ["false"]),
            // Present without a value: off.
            ("muc#roomconfig_changesubject", "boolean", []),
            ("muc#roomconfig_roomdesc", "text-single", []),
        ]))
        #expect(configuration.isMembersOnly == true)
        #expect(configuration.membersCanInvite == false)
        #expect(configuration.membersCanChangeSubject == false)
        #expect(configuration.description == "")
    }

    @Test func onlyWhatDiffersChanges() throws {
        let x = form(fullForm)
        let current = RoomConfiguration(form: x)
        var wanted = RoomConfiguration(name: "Cake", description: "More cake", isMembersOnly: true)
        wanted.membersCanInvite = true
        let changes = try wanted.changes(from: current, in: x)
        #expect(changes == ["muc#roomconfig_roomdesc": ["More cake"], "muc#roomconfig_allowinvites": ["1"]])
        #expect(try RoomConfiguration().changes(from: current, in: x).isEmpty)
        #expect(try current.changes(from: current, in: x).isEmpty)
    }

    @Test func aBooleanIsWrittenAsTheFormWritesIt() throws {
        let x = form([("muc#roomconfig_membersonly", "boolean", ["false"])])
        let changes = try RoomConfiguration(isMembersOnly: true).changes(from: RoomConfiguration(form: x), in: x)
        #expect(changes == ["muc#roomconfig_membersonly": ["true"]])
    }

    @Test func changingWhatTheRoomDoesNotOfferThrows() {
        let x = form([("muc#roomconfig_roomname", "text-single", ["Cake"])])
        #expect(throws: GroupError.self) {
            try RoomConfiguration(membersCanInvite: true).changes(from: RoomConfiguration(form: x), in: x)
        }
    }

    private let nest = RoomConfiguration(
        name: "Nest", description: "Birds", isMembersOnly: true, whoCanSeeAddresses: .anyone, membersCanInvite: false, membersCanChangeSubject: false,
    )

    @Test func anUntouchedFormDiffersInNothing() {
        #expect(nest.difference(from: nest) == nil)
    }

    @Test func onlyWhatDiffersIsADifference() {
        var draft = nest
        draft.name = "Roost"
        draft.membersCanInvite = true
        #expect(draft.difference(from: nest) == RoomConfiguration(name: "Roost", membersCanInvite: true))
    }

    @Test func fieldsTheRoomLacksAreNoDifference() {
        let bare = RoomConfiguration(name: "Nest")
        var draft = bare
        draft.name = "Roost"
        #expect(draft.difference(from: bare) == RoomConfiguration(name: "Roost"))
    }

    @Test func mergingAChangeKeepsTheRest() {
        let merged = nest.merging(RoomConfiguration(name: "Roost", isMembersOnly: false))
        #expect(merged.name == "Roost")
        #expect(merged.isMembersOnly == false)
        #expect(merged.description == "Birds")
        #expect(merged.whoCanSeeAddresses == .anyone)
    }

    @Test func aFormIsSentBackWithoutItsFixedAndTypeFields() {
        let fields = XMPPSession.formFields(form(fullForm + [("", "fixed", ["Configure the room"])]))
        #expect(fields["FORM_TYPE"] == nil)
        #expect(fields["muc#roomconfig_getmemberlist"] == ["moderator", "participant"])
        #expect(fields.count == fullForm.count - 1)
    }
}

// MARK: Acting

struct RoomManagementSessionTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    /// The room's features and name, as its disco#info says.
    let info = Locked<(features: [String], name: String)>((["muc_membersonly", "muc_nonanonymous"], "Cake"))
    let configuration = Locked<[(String, String, [String])]>(fullForm)

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me", name: "Cake")
        try database.setRoomInfo(room, name: "Cake", isMembersOnly: true, isNonAnonymous: true)
        session.reloadKnownRooms()
        let info = info, configuration = configuration
        wire.answer { iq in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                let (features, name) = info.value
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
                query.addChild(Element(name: "identity", attributes: ["category": "conference", "type": "text", "name": name]))
                for feature in features { query.addChild(Element(name: "feature", attributes: ["var": feature])) }
                return FakeWire.result(to: iq, query)
            }
            if iq.type == .get, iq.firstChild(name: "query", xmlns: ownerNS) != nil {
                let query = Element(name: "query", xmlns: ownerNS)
                query.addChild(form(configuration.value))
                return FakeWire.result(to: iq, query)
            }
            return FakeWire.result(to: iq)
        }
    }

    private func join(as affiliation: RoomAffiliation, role: String = "moderator", others: [YapnestKit.JID: RoomAffiliation] = [:]) {
        session.updateRoom(room) { status in
            var joined = RoomStatus(phase: .joined, nickname: "me")
            joined.affiliation = affiliation
            joined.role = role
            for (jid, affiliation) in others { joined.setAffiliation(affiliation, of: jid) }
            status = joined
        }
    }

    private func requests(in namespace: String) -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "query", xmlns: namespace) != nil }
    }

    private func group() throws -> GroupChat { try #require(try database.groupChat(room)) }

    // MARK: Configuration

    @Test func theConfigurationIsReadFromTheOwnerForm() async throws {
        join(as: .owner)
        let read = try await session.roomConfiguration(of: room)
        #expect(read.name == "Cake" && read.isMembersOnly == true && read.whoCanSeeAddresses == .anyone)
        #expect(session.roomStatus(room)?.participantsMayChangeSubject == false)
    }

    @Test func onlyAnOwnerReadsOrChangesIt() async throws {
        join(as: .admin)
        await #expect(throws: GroupError.self) { _ = try await session.roomConfiguration(of: room) }
        await #expect(throws: GroupError.self) { try await session.updateRoomConfiguration(RoomConfiguration(name: "New"), in: room) }
        #expect(requests(in: ownerNS).isEmpty)
    }

    @Test func aChangeSubmitsTheWholeFormWithOnlyThatChanged() async throws {
        join(as: .owner)
        try await session.updateRoomConfiguration(RoomConfiguration(description: "Pie too"), in: room)
        let submit = try #require(requests(in: ownerNS).last)
        #expect(submit.type == .set)
        let x = try #require(submit.firstChild(name: "query")?.firstChild(name: "x", xmlns: "jabber:x:data"))
        #expect(x.getAttribute("type") == "submit")
        let sent = XMPPSession.formFields(x)
        var expected = XMPPSession.formFields(form(fullForm))
        expected["muc#roomconfig_roomdesc"] = ["Pie too"]
        #expect(sent == expected)
        #expect(XMPPSession.formValues("FORM_TYPE", in: x) == ["http://jabber.org/protocol/muc#roomconfig"])
    }

    @Test func nothingIsSentWhenNothingDiffers() async throws {
        join(as: .owner)
        try await session.updateRoomConfiguration(RoomConfiguration(name: "Cake", isMembersOnly: true), in: room)
        #expect(requests(in: ownerNS).filter { $0.type == .set }.isEmpty)
    }

    @Test func aFieldTheRoomLacksIsRefusedBeforeSending() async throws {
        join(as: .owner)
        configuration.value = [("muc#roomconfig_roomname", "text-single", ["Cake"])]
        await #expect(throws: GroupError.self) { try await session.updateRoomConfiguration(RoomConfiguration(membersCanInvite: true), in: room) }
        #expect(requests(in: ownerNS).filter { $0.type == .set }.isEmpty)
    }

    @Test func aRefusalIsReported() async throws {
        join(as: .owner)
        let query = Element(name: "query", xmlns: ownerNS)
        query.addChild(form(fullForm))
        wire.answer { iq in iq.type == .set ? FakeWire.error(to: iq, condition: "forbidden") : FakeWire.result(to: iq, query) }
        await #expect(throws: (any Error).self) { try await session.updateRoomConfiguration(RoomConfiguration(name: "New"), in: room) }
    }

    @Test func renamingChangesWhatWeShowAndKeepsTheBookmark() async throws {
        join(as: .owner)
        try database.updateGroupChat(room) { $0.isBookmarked = true }
        info.value = (["muc_membersonly", "muc_nonanonymous"], "Pie")
        try await session.updateRoomConfiguration(RoomConfiguration(name: "Pie"), in: room)
        #expect(try group().name == "Pie")
        #expect(try group().displayName == "Pie")
        // The bookmark that would put "Cake" back is rewritten; this
        // session's server has only the old kind, which is read first.
        #expect(await eventually {
            wire.written.compactMap { $0 as? Iq }.contains { $0.element.stringValue.contains("storage:bookmarks") }
        })
    }

    @Test func openingTheRoomMakesItPublicAndStopsEncrypting() async throws {
        join(as: .owner)
        #expect(try database.conversation(id: group().conversationId)?.isEncrypted == true)
        #expect(try group().isPrivate)
        info.value = ([], "Cake")
        try await session.updateRoomConfiguration(RoomConfiguration(isMembersOnly: false), in: room)
        #expect(try !group().isMembersOnly && !group().isNonAnonymous && !group().isPrivate)
        #expect(try database.conversation(id: group().conversationId)?.isEncrypted == false)
    }

    @Test func aConfigurationNoticeFromTheRoomReadsItsInfoAgain() async throws {
        join(as: .owner)
        info.value = (["muc_membersonly"], "Cake")
        let notice: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='groupchat' id='n'><x xmlns='http://jabber.org/protocol/muc#user'><status code='104'/></x></message>")
        session.handleRoomStanza(notice, source: .live)
        #expect(await eventually { (try? group().isPrivate) == false })
        #expect(try group().isMembersOnly && !group().isNonAnonymous)
        #expect(try database.conversation(id: group().conversationId)?.isEncrypted == false)
    }

    @Test func theRoomInfoSaysWhetherParticipantsChangeTheSubject() async throws {
        join(as: .member, role: "participant")
        let x = Element(name: "x", xmlns: "jabber:x:data")
        let formType = Element(name: "field", attributes: ["var": "FORM_TYPE"])
        formType.addChild(Element(name: "value", cdata: "http://jabber.org/protocol/muc#roominfo"))
        let field = Element(name: "field", attributes: ["var": "muc#roominfo_changesubject"])
        field.addChild(Element(name: "value", cdata: "1"))
        x.addChild(formType)
        x.addChild(field)
        wire.answer { iq in
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "identity", attributes: ["category": "conference", "type": "text", "name": "Cake"]))
            query.addChild(x)
            return FakeWire.result(to: iq, query)
        }
        session.refreshRoomInfo(room)
        #expect(await eventually { session.roomStatus(room)?.canChangeSubject == true })
    }

    // MARK: Subject

    private func echo(_ subject: String, from nick: String = "me", id: String? = "e1") -> Martin.Message {
        parseStanza("<message from='cake@rooms.example.org/\(nick)' type='groupchat' id='\(id ?? "x")'><subject>\(subject)</subject></message>")
    }

    private func subjectMessage() async -> Martin.Message? {
        _ = await eventually { wire.messages.contains { $0.subject != nil } }
        return wire.messages.first { $0.subject != nil }
    }

    @Test func aSubjectChangeReturnsWhenTheRoomEchoesIt() async throws {
        join(as: .owner)
        let change = Task { try await session.setSubject("Cake day", in: room) }
        let sent = try #require(await subjectMessage())
        #expect(sent.type == .groupchat)
        #expect(sent.to?.stringValue == room.description)
        session.handleRoomStanza(echo("Cake day"), source: .live)
        try await change.value
        #expect(try group().subject == "Cake day")
    }

    @Test func aSubjectChangeFailsWhenTheRoomRefusesIt() async throws {
        join(as: .member, role: "participant")
        let change = Task { try await session.setSubject("Cake day", in: room) }
        let sent = try #require(await subjectMessage())
        let error: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='error' id='\(sent.id!)'><error type='auth'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>")
        session.handleTopLevel(error)
        await #expect(throws: GroupError.self) { try await change.value }
        #expect(try group().subject == nil)
    }

    @Test func anotherOccupantsSubjectDoesNotAnswerOurs() async throws {
        join(as: .owner)
        let change = Task { try await session.setSubject("Mine", in: room) }
        _ = try #require(await subjectMessage())
        session.handleRoomStanza(echo("Theirs", from: "anna"), source: .live)
        session.handleRoomStanza(echo("Mine", from: "anna"), source: .live)
        try await Task.sleep(for: .milliseconds(200))
        session.handleRoomStanza(echo("Mine"), source: .live)
        try await change.value
    }

    @Test func offlineOrOutsideTheRoomASubjectCannotBeSet() async throws {
        await #expect(throws: GroupError.self) { try await session.setSubject("x", in: room) }
        #expect(wire.messages.isEmpty)
    }

    // MARK: Bans

    @Test func theBanListIsKeptAndReplacedWhenAsked() async throws {
        join(as: .admin, others: [anna: .outcast])
        wire.answer { iq in
            let query = Element(name: "query", xmlns: adminNS)
            query.addChild(Element(name: "item", attributes: ["affiliation": "outcast", "jid": ben.description]))
            return FakeWire.result(to: iq, query)
        }
        try await session.refreshBanList(of: room)
        #expect(session.roomStatus(room)?.banned == [ben])
        let item = try #require(requests(in: adminNS).last?.firstChild(name: "query")?.firstChild(name: "item"))
        #expect(item.getAttribute("affiliation") == "outcast")
    }

    @Test func onlyAdminsAndOwnersReadTheBanList() async throws {
        join(as: .member)
        await #expect(throws: GroupError.self) { try await session.refreshBanList(of: room) }
        #expect(requests(in: adminNS).isEmpty)
    }

    @Test func listsToFetchFollowTheRoomAndOurStanding() {
        #expect(XMPPSession.listsToFetch(isNonAnonymous: true, isOwnerOrAdmin: false) == [.owner, .admin, .member])
        #expect(XMPPSession.listsToFetch(isNonAnonymous: true, isOwnerOrAdmin: true) == [.owner, .admin, .member, .outcast])
        #expect(XMPPSession.listsToFetch(isNonAnonymous: false, isOwnerOrAdmin: true) == [.outcast])
        #expect(XMPPSession.listsToFetch(isNonAnonymous: false, isOwnerOrAdmin: false).isEmpty)
    }

    @Test func banningThenUnbanningMovesThemThroughTheList() async throws {
        join(as: .owner, others: [anna: .member])
        try await session.banMember(anna, from: room)
        #expect(session.roomStatus(room)?.banned == [anna])
        try await session.unban(anna, in: room)
        let item = try #require(requests(in: adminNS).last?.firstChild(name: "query")?.firstChild(name: "item"))
        #expect(item.getAttribute("affiliation") == "none")
        #expect(item.getAttribute("jid") == anna.description)
        #expect(session.roomStatus(room)?.banned.isEmpty == true)
    }

    @Test func unbanningSomeoneNotBannedIsNotAllowed() async throws {
        join(as: .owner, others: [anna: .member])
        await #expect(throws: GroupError.self) { try await session.unban(anna, in: room) }
    }

    @Test func theRoomsBroadcastsKeepTheBanListInSync() throws {
        join(as: .owner)
        let banned: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='groupchat'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='outcast' jid='anna@example.org'/></x></message>")
        session.handleRoomStanza(banned, source: .live)
        #expect(session.roomStatus(room)?.banned == [anna])
        let lifted: Martin.Message = parseStanza("<message from='cake@rooms.example.org' type='groupchat'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='none' jid='anna@example.org'/></x></message>")
        session.handleRoomStanza(lifted, source: .live)
        #expect(session.roomStatus(room)?.banned.isEmpty == true)
    }

    @Test func aBanPresenceCountsAsABan() throws {
        join(as: .owner)
        let presence: Presence = parseStanza("<presence from='cake@rooms.example.org/annie' type='unavailable'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='outcast' role='none' jid='anna@example.org'/><status code='301'/></x></presence>")
        session.roomPresence(presence, room: room)
        #expect(session.roomStatus(room)?.banned == [anna])
    }

    // MARK: Owners

    @Test func ownersMakeOwnersAndTakeOwnershipBackToAdmin() async throws {
        join(as: .owner, others: [me: .owner, anna: .member, ben: .owner])
        try await session.setOwner(true, member: anna, in: room)
        #expect(requests(in: adminNS).last?.firstChild(name: "query")?.firstChild(name: "item")?.getAttribute("affiliation") == "owner")
        #expect(session.roomStatus(room)?.memberAffiliations[anna] == .owner)
        try await session.setOwner(false, member: ben, in: room)
        let item = try #require(requests(in: adminNS).last?.firstChild(name: "query")?.firstChild(name: "item"))
        #expect(item.getAttribute("affiliation") == "admin")
        #expect(item.getAttribute("jid") == ben.description)
        #expect(session.roomStatus(room)?.memberAffiliations[ben] == .admin)
    }

    @Test func anAdminCannotMakeOwners() async throws {
        join(as: .admin, others: [anna: .member])
        await #expect(throws: GroupError.self) { try await session.setOwner(true, member: anna, in: room) }
        #expect(requests(in: adminNS).isEmpty)
    }

    @Test func theLastOwnerCannotStepDown() async throws {
        join(as: .owner, others: [me: .owner, anna: .member])
        await #expect(throws: GroupError.self) { try await session.setOwner(false, member: me, in: room) }
        #expect(requests(in: adminNS).isEmpty)
    }

    @Test func anOwnerWithCompanyStepsDown() async throws {
        join(as: .owner, others: [me: .owner, anna: .owner])
        try await session.setOwner(false, member: me, in: room)
        #expect(session.roomStatus(room)?.affiliation == .admin)
        #expect(requests(in: adminNS).last?.firstChild(name: "query")?.firstChild(name: "item")?.getAttribute("affiliation") == "admin")
    }

    // MARK: Kicking

    private func present(_ nick: String, _ jid: YapnestKit.JID?, _ affiliation: RoomAffiliation) {
        session.updateRoom(room) { $0?.occupants[nick] = RoomOccupant(nick: nick, jid: jid, affiliation: affiliation) }
    }

    @Test func aModeratorKicksAPresentMember() async throws {
        join(as: .admin)
        present("annie", anna, .member)
        try await session.kick(nickname: "annie", reason: "Off topic", in: room)
        let item = try #require(requests(in: adminNS).last?.firstChild(name: "query")?.firstChild(name: "item"))
        #expect(item.getAttribute("nick") == "annie")
        #expect(item.getAttribute("role") == "none")
        #expect(item.firstChild(name: "reason")?.value == "Off topic")
        #expect(session.roomStatus(room)?.occupants["annie"] == nil)
    }

    @Test func nobodyIsKickedWhoIsAbsentOrOutranksUs() async throws {
        join(as: .admin)
        present("boss", nil, .owner)
        present("peer", ben, .admin)
        await #expect(throws: GroupError.self) { try await session.kick(nickname: "boss", in: room) }
        await #expect(throws: GroupError.self) { try await session.kick(nickname: "peer", in: room) }
        await #expect(throws: GroupError.self) { try await session.kick(nickname: "nobody", in: room) }
        await #expect(throws: GroupError.self) { try await session.kick(nickname: "me", in: room) }
        join(as: .member, role: "participant")
        present("annie", anna, .none)
        await #expect(throws: GroupError.self) { try await session.kick(nickname: "annie", in: room) }
        #expect(requests(in: adminNS).isEmpty)
    }

    // MARK: Destroying

    @Test func destroyingEndsTheGroupLikeAnIncomingDestroy() async throws {
        join(as: .owner)
        try database.updateGroupChat(room) { $0.isBookmarked = true }
        try await session.destroyGroup(room, reason: "Moving")
        let destroy = try #require(requests(in: ownerNS).last?.firstChild(name: "query")?.firstChild(name: "destroy"))
        #expect(destroy.firstChild(name: "reason")?.value == "Moving")
        #expect(try group().hasLeft)
        #expect(try !group().isBookmarked)
        guard case .failed = session.roomStatus(room)?.phase else { Issue.record("not failed"); return }
        #expect(session.roomStatus(room)?.canRetry == false)
        // The notice that follows changes nothing, and retracts nothing twice.
        let before = wire.written.count
        let notice: Presence = parseStanza("<presence from='cake@rooms.example.org/me' type='unavailable'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='none' role='none'/><destroy/><status code='110'/></x></presence>")
        session.roomPresence(notice, room: room)
        #expect(wire.written.count == before)
    }

    @Test func anotherOwnersDestroyEndsTheGroupWithoutTheSelfStatus() throws {
        join(as: .member, role: "participant")
        // Servers send it from each occupant, ours included, with no status 110.
        let notice: Presence = parseStanza("<presence from='cake@rooms.example.org/me' type='unavailable'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='none'/><destroy><reason>Gone</reason></destroy></x></presence>")
        session.roomPresence(notice, room: room)
        #expect(try group().hasLeft)
        guard case .failed(let reason)? = session.roomStatus(room)?.phase else { Issue.record("not failed"); return }
        #expect(reason == String(localized: "This group was deleted."))
    }

    @Test func aDestroyInAnotherOccupantsPresenceIsNotBelieved() throws {
        join(as: .member, role: "participant")
        // An occupant can put anything in their own presence; only ours is the room's word.
        let notice: Presence = parseStanza("<presence from='cake@rooms.example.org/anna' type='unavailable'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='owner' role='none'/><destroy><reason>Gone</reason></destroy></x></presence>")
        session.roomPresence(notice, room: room)
        #expect(try !group().hasLeft)
        #expect(session.roomStatus(room)?.phase == .joined)
    }

    @Test func onlyAnOwnerDestroys() async throws {
        join(as: .admin)
        await #expect(throws: GroupError.self) { try await session.destroyGroup(room) }
        #expect(requests(in: ownerNS).isEmpty)
        #expect(try !group().hasLeft)
    }

    @Test func aRefusedDestroyChangesNothing() async throws {
        join(as: .owner)
        wire.answer { FakeWire.error(to: $0, condition: "forbidden") }
        await #expect(throws: (any Error).self) { try await session.destroyGroup(room) }
        #expect(try !group().hasLeft)
        #expect(session.roomStatus(room)?.isJoined == true)
    }

    // MARK: Picture

    private func vCards() -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "vCard", xmlns: "vcard-temp") != nil }
    }

    @Test func aPictureIsSetInTheRoomsVCardAndShownAtOnce() async throws {
        join(as: .owner)
        let image = onePixelPNG
        try await session.setGroupAvatar(image, mimeType: "image/jpeg", in: room)
        let set = try #require(vCards().last)
        #expect(set.type == .set)
        let photo = try #require(set.firstChild(name: "vCard")?.firstChild(name: "PHOTO"))
        #expect(photo.firstChild(name: "TYPE")?.value == "image/jpeg")
        #expect(photo.firstChild(name: "BINVAL")?.value == image.base64EncodedString())
        let hash = AvatarStore.hash(of: image)
        #expect(try database.contact(room)?.avatarHash == hash)
        #expect(session.avatars.contains(hash))
    }

    @Test func removingThePictureSendsACardWithoutOneAndKeepsTheRest() async throws {
        join(as: .owner)
        try await session.setGroupAvatar(onePixelPNG, in: room)
        wire.answer { iq in
            let card = Element(name: "vCard", xmlns: "vcard-temp")
            card.addChild(Element(name: "DESC", cdata: "About cake"))
            let photo = Element(name: "PHOTO")
            photo.addChild(Element(name: "BINVAL", cdata: "AQID"))
            card.addChild(photo)
            return FakeWire.result(to: iq, card)
        }
        try await session.setGroupAvatar(nil, in: room)
        let card = try #require(vCards().last?.firstChild(name: "vCard"))
        #expect(card.firstChild(name: "PHOTO") == nil)
        #expect(card.firstChild(name: "DESC")?.value == "About cake")
        #expect(try database.contact(room)?.avatarHash == nil)
    }

    @Test func aRoomWithNoCardYetGetsOneWithJustThePicture() async throws {
        join(as: .owner)
        wire.answer { iq in
            iq.type == .get ? FakeWire.error(to: iq, condition: "item-not-found") : FakeWire.result(to: iq)
        }
        try await session.setGroupAvatar(onePixelPNG, in: room)
        let set = try #require(vCards().last)
        #expect(set.type == .set)
        #expect(set.firstChild(name: "vCard")?.children.map(\.name) == ["PHOTO"])
    }

    @Test func aRoomWithAnEmptyCardGetsOneWithJustThePicture() async throws {
        join(as: .owner)
        wire.answer { iq in
            FakeWire.result(to: iq)
        }
        try await session.setGroupAvatar(onePixelPNG, in: room)
        #expect(vCards().last?.firstChild(name: "vCard")?.children.map(\.name) == ["PHOTO"])
    }

    @Test func aCardThatCouldNotBeReadIsNotWrittenOver() async throws {
        join(as: .owner)
        wire.answer { iq in
            iq.type == .get ? FakeWire.error(to: iq, condition: "internal-server-error") : FakeWire.result(to: iq)
        }
        await #expect(throws: (any Error).self) { try await session.setGroupAvatar(onePixelPNG, in: room) }
        #expect(vCards().allSatisfy { $0.type != .set })
        #expect(try database.contact(room)?.avatarHash == nil)
    }

    @Test func aServerWithoutRoomCardsIsReportedAsUnsupported() async throws {
        join(as: .owner)
        wire.answer { FakeWire.error(to: $0, condition: "service-unavailable") }
        do {
            try await session.setGroupAvatar(onePixelPNG, in: room)
            Issue.record("should have thrown")
        } catch let error as GroupError {
            guard case .unsupported = error else { Issue.record("\(error)"); return }
        }
        #expect(try database.contact(room)?.avatarHash == nil)
    }

    @Test func aPictureNeedsAnOwnerAndAReasonableSize() async throws {
        join(as: .admin)
        await #expect(throws: GroupError.self) { try await session.setGroupAvatar(onePixelPNG, in: room) }
        join(as: .owner)
        await #expect(throws: (any Error).self) { try await session.setGroupAvatar(Data(count: AvatarStore.maxSize + 1), in: room) }
        await #expect(throws: (any Error).self) { try await session.setGroupAvatar(Data([1, 2, 3]), in: room) }
        #expect(vCards().isEmpty)
    }
}

private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

/// A value the tests change while the wire's responder reads it.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
