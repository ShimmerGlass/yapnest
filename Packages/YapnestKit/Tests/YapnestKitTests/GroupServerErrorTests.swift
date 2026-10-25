import Foundation
import GRDB
import Martin
import os
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private func presence(from nick: String = "me", in room: YapnestKit.JID = room, type: String? = nil, affiliation: String = "member", statuses: [Int] = [110]) -> Martin.Presence {
    let codes = statuses.map { "<status code='\($0)'/>" }.joined()
    let type = type.map { " type='\($0)'" } ?? ""
    return parseStanza("<presence from='\(room)/\(nick)' to='me@example.org/t'\(type)><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='\(affiliation)' role='participant'/>\(codes)</x></presence>")
}

private func joinError(_ condition: String, in room: YapnestKit.JID = room) -> Martin.Presence {
    parseStanza("<presence type='error' from='\(room)/me'><error type='auth'><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>")
}

private func isQuery(_ iq: Iq, _ xmlns: String) -> Bool {
    iq.firstChild(name: "query", xmlns: xmlns) != nil
}

/// The answer to a bookmark request. The old-style bookmarks wait for theirs on
/// a queue the whole process shares, so one left unanswered holds up every
/// other test's.
private func bookmarksUnsupported(_ iq: Iq) -> Iq? {
    iq.firstChild(name: "pubsub") == nil ? nil : FakeWire.error(to: iq, condition: "service-unavailable")
}

private func wait(_ iq: Iq) -> Iq { FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") }
private func forbidden(_ iq: Iq) -> Iq { FakeWire.error(to: iq, condition: "forbidden", type: "auth") }

private func form(for iq: Iq) -> Iq {
    let query = Element(name: "query", xmlns: "http://jabber.org/protocol/muc#owner")
    query.addChild(Element(name: "x", xmlns: "jabber:x:data"))
    return FakeWire.result(to: iq, query)
}

private func joinPresences(_ wire: FakeWire) -> [Martin.Presence] {
    wire.written.compactMap { $0 as? Martin.Presence }.filter { $0.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc") != nil }
}

private func leavePresences(_ wire: FakeWire) -> [Martin.Presence] {
    wire.written.compactMap { $0 as? Martin.Presence }.filter { $0.type == .unavailable }
}

private func warningKeys(_ session: XMPPSession) -> [String] {
    session.warnings.current.map(\.key)
}

// MARK: The room archive

struct RoomArchiveFailureTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let queries = Locked(0)

    init() throws {
        try self.init(cursor: "old")
    }

    init(cursor: String?) throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        session.lock.withLock { $0.retryBackoff = 0 }
        try database.joinGroupChat(room, nickname: "me")
        try database.updateGroupChat(room) { $0.lastArchiveId = cursor }
        session.reloadKnownRooms()
        var status = RoomStatus(phase: .joining, nickname: "me")
        status.hasArchive = true
        session.updateRoom(room) { $0 = status }
    }

    private func answerArchive(_ response: @escaping @Sendable (Iq, Int) -> Iq) {
        let queries = self.queries
        wire.answer { request in
            guard request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") != nil else { return nil }
            queries.value += 1
            return response(request, queries.value)
        }
    }

    private var cursor: String? { get throws { try database.groupChat(room)?.lastArchiveId } }

    @Test func aPageThatFailsForNowIsAskedForAgain() async throws {
        answerArchive { request, count in
            count < 3 ? wait(request) : FakeWire.result(to: request, RoomCatchUpTests.fin(last: "r5"))
        }
        session.roomPresence(presence(), room: room)

        #expect(await eventually { session.roomStatus(room)?.isSyncing == false })
        #expect(queries.value == 3)
        #expect(try cursor == "r5")
        #expect(warningKeys(session).isEmpty)
    }

    @Test func aPageThatKeepsFailingLeavesTheCursorAndWarnsOfTheGap() async throws {
        answerArchive { request, _ in wait(request) }
        session.roomPresence(presence(), room: room)

        #expect(await eventually { warningKeys(session).contains("room-history:\(room)") })
        #expect(queries.value == 3)
        #expect(try cursor == "old")
        #expect(session.roomStatus(room)?.catchUpReachedEnd == false)
        // What the room sends live doesn't move the cursor over the gap.
        session.handleRoomStanza(
            parseStanza("<message from='cake@rooms.example.org/anna' type='groupchat' id='l1'><body>live</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r9'/></message>"),
            source: .live,
        )
        #expect(try cursor == "old")
    }

    @Test func aFinalRefusalIsNotAskedAgainAndWarnsToo() async throws {
        answerArchive { request, _ in forbidden(request) }
        session.roomPresence(presence(), room: room)

        #expect(await eventually { warningKeys(session).contains("room-history:\(room)") })
        #expect(queries.value == 1)
        #expect(session.warnings.current.first?.detail.contains("forbidden") == true)
    }

    @Test func theWarningsRetryReadsOnFromTheCursorAndClearsIt() async throws {
        answerArchive { request, _ in forbidden(request) }
        session.roomPresence(presence(), room: room)
        #expect(await eventually { warningKeys(session).contains("room-history:\(room)") })

        answerArchive { request, _ in FakeWire.result(to: request, RoomCatchUpTests.fin(last: "r5")) }
        #expect(await session.warnings.retry("room-history:\(room)"))
        #expect(warningKeys(session).isEmpty)
        #expect(try cursor == "r5")
        #expect(session.roomStatus(room)?.catchUpReachedEnd == true)
    }

    @Test func anArchiveThatDoesNotKnowOurCursorIsReadFromItsNewestPage() async throws {
        answerArchive { request, count in
            count == 1 ? FakeWire.error(to: request) : FakeWire.result(to: request, RoomCatchUpTests.fin(last: "r5"))
        }
        session.roomPresence(presence(), room: room)

        #expect(await eventually { session.roomStatus(room)?.isSyncing == false })
        #expect(queries.value == 2)
        #expect(try cursor == "r5")
    }

    @Test func aNewestPageThatIsNotFoundIsNotAskedForAgainForEver() async throws {
        let fresh = try RoomArchiveFailureTests(cursor: nil)
        // Ends the loop that would otherwise run for ever.
        let queries = fresh.queries
        fresh.wire.answer { request in
            guard request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") != nil else { return nil }
            queries.value += 1
            return queries.value > 5 ? FakeWire.result(to: request, RoomCatchUpTests.fin(last: "r5")) : FakeWire.error(to: request)
        }
        fresh.session.roomPresence(presence(), room: room)

        #expect(await eventually { fresh.session.roomStatus(room)?.isSyncing == false })
        #expect(queries.value == 1)
        #expect(warningKeys(fresh.session).contains("room-history:\(room)"))
    }
}

// MARK: Creating a group

struct CreateGroupFailureTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        session.lock.withLock {
            $0.retryBackoff = 0
            $0.mucService = "rooms.example.org"
        }
    }

    /// The room the creation picked, once it has asked to join it.
    private func createdRoom() async -> YapnestKit.JID? {
        _ = await eventually { !joinPresences(wire).isEmpty }
        return joinPresences(wire).first?.to.flatMap { YapnestKit.JID($0) }
    }

    private func answers(configuration: @escaping @Sendable (Iq) -> Iq, affiliation: @escaping @Sendable (Iq) -> Iq = { FakeWire.result(to: $0) }) {
        wire.answer { iq in
            if isQuery(iq, "http://jabber.org/protocol/disco#info") {
                return FakeWire.discoInfo(to: iq, category: "conference", type: "text", features: ["urn:xmpp:mam:2"])
            }
            if isQuery(iq, "http://jabber.org/protocol/muc#owner") {
                if iq.firstChild(name: "query")?.firstChild(name: "destroy") != nil { return FakeWire.result(to: iq) }
                return configuration(iq)
            }
            if isQuery(iq, "http://jabber.org/protocol/muc#admin") { return affiliation(iq) }
            return bookmarksUnsupported(iq)
        }
    }

    @Test func aJoinThatFailsLeavesNoGroupBehind() async throws {
        answers(configuration: { FakeWire.result(to: $0) })
        let session = self.session
        let creation = Task { try await session.createGroup(name: "Cake", inviting: []) }
        let created = try #require(await createdRoom())
        session.roomPresence(joinError("not-authorized", in: created), room: created)

        await #expect(throws: GroupError.self) { try await creation.value }
        #expect(try database.groupChat(created) == nil)
        #expect(!session.isGroup(created))
        #expect(session.roomStatus(created) == nil)
    }

    @Test func aConfigurationThatFailsDestroysTheLockedRoomAndLeavesNoGroup() async throws {
        answers(configuration: { forbidden($0) })
        let session = self.session
        let creation = Task { try await session.createGroup(name: "Cake", inviting: []) }
        let created = try #require(await createdRoom())
        session.roomPresence(presence(in: created, affiliation: "owner", statuses: [110, 201]), room: created)

        await #expect(throws: (any Error).self) { try await creation.value }
        let destroyed = wire.written.compactMap { $0 as? Iq }.contains { $0.firstChild(name: "query")?.firstChild(name: "destroy") != nil && $0.to?.stringValue == created.description }
        #expect(destroyed)
        #expect(try database.groupChat(created) == nil)
        #expect(session.roomStatus(created) == nil)
    }

    @Test func aConfigurationThatFailsForNowIsTriedAgainBeforeGivingUp() async throws {
        let attempts = Locked(0)
        answers(configuration: { iq in
            attempts.value += 1
            return attempts.value < 3 ? wait(iq) : FakeWire.result(to: iq)
        })
        let session = self.session
        let creation = Task { try await session.createGroup(name: "Cake", inviting: []) }
        let created = try #require(await createdRoom())
        session.roomPresence(presence(in: created, affiliation: "owner", statuses: [110, 201]), room: created)

        #expect(try await creation.value == created)
    }

    @Test func aFailedInvitationLeavesTheCreatedGroupAndWarnsWithRetry() async throws {
        let refuse = Locked(true)
        answers(configuration: { form(for: $0) }, affiliation: { refuse.value ? forbidden($0) : FakeWire.result(to: $0) })
        let session = self.session
        let creation = Task { try await session.createGroup(name: "Cake", inviting: [alice]) }
        let created = try #require(await createdRoom())
        session.roomPresence(presence(in: created, affiliation: "owner", statuses: [110, 201]), room: created)

        // The group was created, so the call doesn't fail: a second try would make another.
        #expect(try await creation.value == created)
        #expect(try database.groupChat(created) != nil)
        let key = "room-invite:\(created)"
        #expect(warningKeys(session).contains(key))
        #expect(session.warnings.current.first { $0.key == key }?.detail.contains("The group was created") == true)

        refuse.value = false
        #expect(await session.warnings.retry(key))
        #expect(wire.messages.contains { $0.firstChild(name: "x", xmlns: "jabber:x:conference") != nil })
    }
}

// MARK: Rejoining

struct RejoinCreationTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
    }

    @Test func aRoomDestroyedWhileWeWereAwayIsNotCreatedAgainByTheRejoin() async throws {
        wire.answer { iq in isQuery(iq, "http://jabber.org/protocol/disco#info") ? FakeWire.error(to: iq) : nil }
        session.joinRooms()

        #expect(await eventually { session.roomStatus(room)?.phase == .failed("This group doesn't exist.") })
        #expect(joinPresences(wire).isEmpty)
        #expect(session.roomStatus(room)?.mayCreate == false)
    }

    @Test func aRoomThatTheRejoinCreatedAnywayIsCancelledAndMarkedGone() async throws {
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me", mayCreate: false) }
        session.roomPresence(presence(affiliation: "owner", statuses: [110, 201]), room: room)

        guard case .failed(let reason)? = session.roomStatus(room)?.phase else {
            Issue.record("the room should have failed")
            return
        }
        #expect(reason == "This group doesn't exist.")
        #expect(session.roomStatus(room)?.canRetry == false)
        let cancel = wire.written.compactMap { $0 as? Iq }.first { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/muc#owner") != nil }
        let form = cancel?.firstChild(name: "query")?.firstChild(name: "x", xmlns: "jabber:x:data")
        #expect(form?.getAttribute("type") == "cancel")
    }

    @Test func aRoomWeAreAllowedToCreateStillJoinsWhenItIsNew() async throws {
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me") }
        session.roomPresence(presence(affiliation: "owner", statuses: [110, 201]), room: room)

        #expect(session.roomStatus(room)?.phase == .joined)
        #expect(session.roomStatus(room)?.wasCreated == true)
    }

    @Test func aFailedGroupIsRejoinedWithoutCreating() async throws {
        session.updateRoom(room) {
            var failed = RoomStatus(phase: .failed("x"), nickname: "me")
            failed.canRetry = true
            $0 = failed
        }
        wire.answer { iq in isQuery(iq, "http://jabber.org/protocol/disco#info") ? FakeWire.error(to: iq) : nil }
        session.selfPingRooms()

        #expect(await eventually { session.roomStatus(room)?.phase == .failed("This group doesn't exist.") })
        #expect(joinPresences(wire).isEmpty)
    }

    @Test func aRoomServiceThatIsRestartingIsNotAMissingGroup() async throws {
        wire.answer { iq in isQuery(iq, "http://jabber.org/protocol/disco#info") ? FakeWire.error(to: iq, condition: "service-unavailable") : nil }
        session.joinRooms()

        #expect(await eventually { session.roomStatus(room)?.canRetry == true })
        guard case .failed(let reason)? = session.roomStatus(room)?.phase else {
            Issue.record("the join did not fail")
            return
        }
        #expect(!reason.contains("doesn't exist"))
        #expect(session.hasScheduledRejoin(room))
        session.cancelAllRejoins()
    }

    @Test func aRoomThatIsGoneIsAMissingGroup() async throws {
        wire.answer { iq in isQuery(iq, "http://jabber.org/protocol/disco#info") ? FakeWire.error(to: iq, condition: "gone") : nil }
        session.joinRooms()

        #expect(await eventually { session.roomStatus(room)?.phase == .failed("This group doesn't exist.") })
    }
}

// MARK: Leaving

struct LeaveGroupTests {
    @Test func aServerWithoutBookmarksHasNothingToRemoveSoLeavingWorks() async throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        try session.database.joinGroupChat(room, nickname: "me", isBookmarked: true)
        session.reloadKnownRooms()
        #expect(session.usesLegacyBookmarks)
        wire.answer { FakeWire.error(to: $0, condition: "service-unavailable") }

        try await session.leaveGroup(room)

        #expect(try session.database.groupChat(room)?.hasLeft == true)
    }

    @Test func aFailureThatIsNotAnAbsenceStillStopsLeaving() async throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        try session.database.joinGroupChat(room, nickname: "me", isBookmarked: true)
        wire.answer { forbidden($0) }

        await #expect(throws: GroupError.self) { try await session.leaveGroup(room) }
        #expect(try session.database.groupChat(room)?.hasLeft == false)
    }
}

// MARK: Inviting

struct InviteBounceTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
    }

    private var mediated: Martin.Message? {
        wire.messages.first { $0.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc#user")?.firstChild(name: "invite") != nil }
    }

    private var directInvitations: [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "x", xmlns: "jabber:x:conference") != nil }
    }

    private func bounce(_ message: Martin.Message, condition: String = "forbidden", type: String = "auth") {
        let stanza: Martin.Message = parseStanza("<message type='error' from='cake@rooms.example.org' id='\(message.id ?? "")'><error type='\(type)'><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>")
        session.handleRoomStanza(stanza, source: .live)
    }

    @Test func aRoomThatBouncesTheInvitationFailsItAndNoDirectOneGoesOut() async throws {
        let session = self.session
        let inviting = Task { try await session.invite([alice], to: room, grace: 5) }
        #expect(await eventually { mediated != nil })
        bounce(try #require(mediated))

        do {
            try await inviting.value
            Issue.record("the invitation should have failed")
        } catch let error as ServerError {
            #expect(error.condition == "forbidden")
        }
        #expect(directInvitations.isEmpty)
    }

    @Test func aRoomThatTakesTheInvitationGetsTheDirectOneAfter() async throws {
        try await session.invite([alice], to: room, grace: 0.05)

        #expect(mediated != nil)
        #expect(directInvitations.count == 1)
        #expect(directInvitations.first?.to?.stringValue == alice.description)
    }

    @Test func aBounceThatMayPassIsAnErrorTooButOneTheUserCanRetry() async throws {
        let session = self.session
        let inviting = Task { try await session.invite([alice], to: room, grace: 5) }
        #expect(await eventually { mediated != nil })
        bounce(try #require(mediated), condition: "resource-constraint", type: "wait")

        do {
            try await inviting.value
            Issue.record("the invitation should have failed")
        } catch let error as ServerError {
            #expect(error.isPassing)
        }
        #expect(directInvitations.isEmpty)
    }

    @Test func nothingIsSentToAGroupWeAreNoLongerConnectedTo() async throws {
        wire.failsWrites = true
        await #expect(throws: GroupError.self) { try await session.invite([alice], to: room, grace: 0) }
        #expect(directInvitations.isEmpty)
    }
}

// MARK: Members

struct MemberListFailureTests {
    let session: XMPPSession
    let wire = FakeWire()
    let asked = Locked(0)

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
        session.lock.withLock { $0.retryBackoff = 0 }
        try session.database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
    }

    private func answer(_ response: @escaping @Sendable (Iq, Int) -> Iq) {
        let asked = self.asked
        wire.answer { iq in
            guard isQuery(iq, "http://jabber.org/protocol/muc#admin") else { return nil }
            asked.value += 1
            return response(iq, asked.value)
        }
    }

    private func fetch(lists: [RoomAffiliation] = [.member]) async {
        await withCheckedContinuation { continuation in
            session.fetchMembers(room, lists: lists) { continuation.resume() }
        }
    }

    @Test func aListThatFailsForNowIsAskedForAgain() async throws {
        answer { iq, count in
            if count < 3 { return wait(iq) }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/muc#admin")
            query.addChild(Element(name: "item", attributes: ["jid": "alice@example.org", "affiliation": "member"]))
            return FakeWire.result(to: iq, query)
        }
        await fetch()

        #expect(asked.value == 3)
        #expect(session.roomStatus(room)?.members == [alice])
        #expect(warningKeys(session).isEmpty)
    }

    @Test func aListThatKeepsFailingWarnsThatEncryptedMessagesMayMissMembers() async throws {
        answer { iq, _ in wait(iq) }
        await fetch()

        #expect(warningKeys(session) == ["room-members:\(room)"])
        #expect(session.warnings.current.first?.title == "Encrypted messages may not reach all members")
        #expect(session.warnings.current.first?.retry != nil)
    }

    @Test func theWarningsRetryFetchesTheMembersAndClearsIt() async throws {
        answer { iq, _ in wait(iq) }
        await fetch()
        answer { iq, _ in
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/muc#admin")
            query.addChild(Element(name: "item", attributes: ["jid": "alice@example.org", "affiliation": "member"]))
            return FakeWire.result(to: iq, query)
        }

        #expect(await session.warnings.retry("room-members:\(room)"))
        #expect(session.roomStatus(room)?.members == [alice])
        #expect(warningKeys(session).isEmpty)
    }

    @Test func aRoomThatKeepsItsMemberListFromUsIsNotAFailureToWarnOf() async throws {
        answer { iq, _ in forbidden(iq) }
        await fetch()

        #expect(asked.value == 1)
        #expect(warningKeys(session).isEmpty)
    }

    @Test func aBanListThatFailsIsLeftToTheScreenThatShowsIt() async throws {
        answer { iq, _ in wait(iq) }
        await fetch(lists: [.outcast])

        #expect(warningKeys(session).isEmpty)
    }
}

// MARK: Moderation and settings

struct ModerationRequestFailureTests {
    let session: XMPPSession
    let wire = FakeWire()
    let asked = Locked(0)

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
        session.lock.withLock { $0.retryBackoff = 0 }
        try session.database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        session.joinForFixture(room, occupants: [
            RoomOccupant(nick: "me", jid: me, affiliation: .owner, role: "moderator"),
            RoomOccupant(nick: "anna", jid: alice, affiliation: .member),
        ])
    }

    private func answer(_ xmlns: String = "http://jabber.org/protocol/muc#admin", _ response: @escaping @Sendable (Iq, Int) -> Iq) {
        let asked = self.asked
        wire.answer { iq in
            guard isQuery(iq, xmlns) else { return bookmarksUnsupported(iq) }
            asked.value += 1
            return response(iq, asked.value)
        }
    }

    @Test func aRequestThatFailsForNowIsMadeAgain() async throws {
        answer { iq, count in count < 3 ? wait(iq) : FakeWire.result(to: iq) }
        try await session.banMember(alice, from: room)

        #expect(asked.value == 3)
        #expect(session.roomStatus(room)?.banned == [alice])
    }

    @Test func aRequestThatKeepsFailingThrowsTheServersErrorForTheUserToRetry() async throws {
        answer { iq, _ in wait(iq) }
        do {
            try await session.removeMember(alice, from: room)
            Issue.record("the request should have failed")
        } catch {
            #expect(ServerError.isFromServer(error))
            #expect(ServerError.classify(error).isPassing)
            #expect(ServerError.classify(error).condition == "resource-constraint")
        }
        #expect(asked.value == 3)
    }

    @Test func aFinalRefusalIsMadeOnceAndThrownAsTheServersError() async throws {
        answer { iq, _ in forbidden(iq) }
        do {
            try await session.kick(nickname: "anna", in: room)
            Issue.record("the request should have failed")
        } catch {
            #expect(ServerError.classify(error).condition == "forbidden")
        }
        #expect(asked.value == 1)
    }

    @Test func aConnectionThatDroppedIsOfflineNotRefused() async throws {
        let session = self.session
        answer { iq, _ in
            session.client.update(state: .disconnected())
            return FakeWire.error(to: iq, condition: "not-authorized", type: "auth")
        }
        await #expect(throws: GroupError.self) { try await session.banMember(alice, from: room) }
        do {
            try await session.unban(alice, in: room)
        } catch GroupError.notConnected {
        } catch {
            Issue.record("expected the not-connected error, got \(error)")
        }
    }

    @Test func martinsNotConnectedAnswerIsOffline() {
        let error = XMPPError.not_authorized("You are not connected to the XMPP server")
        #expect(XMPPSession.roomRequestError(error, isConnected: true) is GroupError)
        #expect(XMPPSession.roomRequestError(XMPPError.not_authorized("nope"), isConnected: true) is XMPPError)
    }

    @Test func destroyingARoomIsMadeAgainWhileItFailsForNow() async throws {
        answer("http://jabber.org/protocol/muc#owner") { iq, count in count < 2 ? wait(iq) : FakeWire.result(to: iq) }
        try await session.destroyGroup(room)

        #expect(asked.value == 2)
        #expect(try session.database.groupChat(room)?.hasLeft == true)
    }

    @Test func destroyingARoomThatTimedOutIsNotMadeAgain() async throws {
        answer("http://jabber.org/protocol/muc#owner") { iq, _ in FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait") }
        await #expect(throws: (any Error).self) { try await session.destroyGroup(room) }

        // The first may have been applied; a second would fail as item-not-found.
        #expect(asked.value == 1)
        #expect(try session.database.groupChat(room)?.hasLeft == false)
    }

    @Test func aKickThatTimedOutIsNotMadeAgain() async throws {
        answer { iq, _ in FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait") }
        await #expect(throws: (any Error).self) { try await session.kick(nickname: "anna", in: room) }

        #expect(asked.value == 1)
    }

    @Test func aRoomSettingsRequestThatFailsForNowIsMadeAgain() async throws {
        answer("http://jabber.org/protocol/muc#owner") { iq, count in
            if count < 2 { return wait(iq) }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/muc#owner")
            query.addChild(Element(name: "x", xmlns: "jabber:x:data"))
            return FakeWire.result(to: iq, query)
        }
        _ = try await session.roomConfiguration(of: room)

        #expect(asked.value == 2)
    }

    @Test func aSubjectOnADroppedStreamIsOfflineNotATimeout() async throws {
        wire.failsWrites = true
        do {
            try await session.setSubject("Hi", in: room)
        } catch GroupError.notConnected {
        } catch {
            Issue.record("expected the not-connected error, got \(error)")
        }
    }

    @Test func aSubjectTheRoomRefusesIsNotAllowed() async throws {
        let session = self.session
        let wire = self.wire
        let changing = Task { try await session.setSubject("Hi", in: room) }
        #expect(await eventually { wire.messages.contains { $0.subject != nil } })
        let sent = try #require(wire.messages.first { $0.subject != nil })
        session.handleRoomStanza(
            parseStanza("<message type='error' from='cake@rooms.example.org' id='\(sent.id ?? "")'><error type='auth'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>"),
            source: .live,
        )
        do {
            try await changing.value
            Issue.record("the change should have failed")
        } catch GroupError.notAllowed {
        } catch {
            Issue.record("expected not allowed, got \(error)")
        }
    }

    @Test func aSubjectTheRoomCouldNotTakeForNowIsSentAgain() async throws {
        let session = self.session
        let wire = self.wire
        let changing = Task { try await session.setSubject("Hi", in: room) }
        #expect(await eventually { wire.messages.contains { $0.subject != nil } })
        let first = try #require(wire.messages.first { $0.subject != nil })
        session.handleRoomStanza(
            parseStanza("<message type='error' from='cake@rooms.example.org' id='\(first.id ?? "")'><error type='wait'><resource-constraint xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>"),
            source: .live,
        )
        #expect(await eventually { wire.messages.filter { $0.subject != nil }.count == 2 })
        session.handleRoomStanza(
            parseStanza("<message type='groupchat' from='cake@rooms.example.org/me'><subject>Hi</subject></message>"),
            source: .live,
        )
        try await changing.value
    }
}

// MARK: Details of rooms

struct RoomDetailTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
    }

    private func status(_ phase: RoomStatus.Phase) {
        session.updateRoom(room) { $0 = RoomStatus(phase: phase, nickname: "me") }
    }

    @Test func aTechnicalRemovalIsRejoinedLater() {
        status(.joined)
        session.roomPresence(presence(type: "unavailable", statuses: [110, 333]), room: room)

        #expect(session.roomStatus(room)?.canRetry == true)
        #expect(session.hasScheduledRejoin(room))
        session.cancelAllRejoins()
    }

    @Test func aRemovalWithoutTheSelfStatusStillRemovesUs() {
        status(.joined)
        session.roomPresence(presence(type: "unavailable", statuses: [307]), room: room)

        guard case .failed? = session.roomStatus(room)?.phase else {
            Issue.record("the room should have failed")
            return
        }
        #expect(session.roomStatus(room)?.canRetry == false)
    }

    @Test func aRestartWithoutTheSelfStatusIsRejoined() {
        status(.joined)
        session.roomPresence(presence(type: "unavailable", statuses: [332]), room: room)

        #expect(session.roomStatus(room)?.canRetry == true)
        session.cancelAllRejoins()
    }

    @Test func anotherSessionOfOursLeavingIsNotBeingRemoved() {
        status(.joined)
        session.roomPresence(presence(type: "unavailable", statuses: []), room: room)

        #expect(session.roomStatus(room)?.phase == .joined)
    }

    @Test func aNewestIncomingMessageSetsTheHistoryASilentRoomIsAskedFor() throws {
        let conversation = try #require(try database.groupChat(room)).conversationId
        let seen = Date(timeIntervalSince1970: 1_000_000)
        try database.writer.write { db in
            _ = try YapnestKit.Message(conversationId: conversation, direction: .incoming, sender: alice, body: "a", timestamp: seen).inserted(db)
            // Written offline since, with the time it was written.
            _ = try YapnestKit.Message(conversationId: conversation, direction: .outgoing, sender: me, body: "b", timestamp: seen.addingTimeInterval(5000)).inserted(db)
        }

        #expect(try database.lastIncomingMessageDate(in: room) == seen)

        session.join(room, nickname: "me", discover: false)
        let history = joinPresences(wire).first?.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc")?.firstChild(name: "history")
        #expect(history?.getAttribute("since") == ISO8601DateFormatter().string(from: seen))
    }

    @Test func aJoinThatTimesOutLocallyTellsTheRoomWeAreGone() async throws {
        let session = self.session
        await #expect(throws: GroupError.self) {
            try await session.joinGroup(room, nickname: nil, mayCreate: true, password: nil, timeout: 0.05)
        }
        let leaves = leavePresences(wire)
        #expect(leaves.count == 1)
        #expect(leaves.first?.to?.stringValue == "cake@rooms.example.org/\(session.defaultNickname)")
        #expect(session.roomStatus(room) == nil)
    }

    @Test func leavingWhileJoiningTellsTheRoomToo() {
        status(.joining)
        session.leaveRoom(room)

        #expect(leavePresences(wire).count == 1)
    }

    @Test func aPasswordGoesOutWithEveryJoinOfTheVisit() async throws {
        session.join(room, nickname: "me", discover: false, password: "s3cret")
        let first = joinPresences(wire).first?.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc")
        #expect(first?.firstChild(name: "password")?.value == "s3cret")
        #expect(session.roomStatus(room)?.password == "s3cret")

        // The room has our nickname: the second try still has the password.
        session.roomPresence(parseStanza("<presence type='error' from='cake@rooms.example.org/me'><error type='cancel'><conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>"), room: room)
        let second = joinPresences(wire).last?.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc")
        #expect(joinPresences(wire).count == 2)
        #expect(second?.firstChild(name: "password")?.value == "s3cret")
    }

    @Test func aPasswordIsReadFromBothKindsOfInvitation() {
        let direct: Martin.Message = parseStanza("<message from='friend@example.org/phone'><x xmlns='jabber:x:conference' jid='cake@rooms.example.org' password='s3cret'/></message>")
        #expect(XMPPSession.invitation(in: direct)?.password == "s3cret")

        let relayed: Martin.Message = parseStanza("<message from='cake@rooms.example.org'><x xmlns='http://jabber.org/protocol/muc#user'><invite from='friend@example.org'/><password>s3cret</password></x></message>")
        #expect(XMPPSession.invitation(in: relayed)?.password == "s3cret")

        let plain: Martin.Message = parseStanza("<message from='friend@example.org/phone'><x xmlns='jabber:x:conference' jid='cake@rooms.example.org'/></message>")
        #expect(XMPPSession.invitation(in: plain)?.password == nil)
    }

    @Test func anInvitationToAPasswordRoomJoinsWithTheInvitersPassword() async throws {
        let friend = YapnestKit.JID("friend@example.org")!
        try database.updateRosterItem(jid: friend, name: nil, subscription: .both, isPending: false)
        wire.answer { iq in
            isQuery(iq, "http://jabber.org/protocol/disco#info") ? FakeWire.discoInfo(to: iq, category: "conference", type: "text") : nil
        }
        session.invitationReceived(parseStanza("<message from='friend@example.org/phone'><x xmlns='jabber:x:conference' jid='book@rooms.example.org' password='s3cret'/></message>") as Martin.Message)

        #expect(await eventually { !joinPresences(wire).isEmpty })
        let join = joinPresences(wire).first?.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc")
        #expect(join?.firstChild(name: "password")?.value == "s3cret")
    }
}
