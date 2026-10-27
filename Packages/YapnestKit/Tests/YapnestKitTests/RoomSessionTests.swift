import Foundation
import GRDB
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
private let other = YapnestKit.JID("book@rooms.example.org")!

/// Our own presence in `room`, as the room sends it.
private func selfPresence(type: String? = nil, statuses: [Int] = [110]) -> Martin.Presence {
    let codes = statuses.map { "<status code='\($0)'/>" }.joined()
    let type = type.map { " type='\($0)'" } ?? ""
    return parseStanza("<presence from='cake@rooms.example.org/me' to='me@example.org/t'\(type)><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='participant'/>\(codes)</x></presence>")
}

private func liveMessage(id: String, stanzaId: String) -> Martin.Message {
    parseStanza("<message from='cake@rooms.example.org/anna' type='groupchat' id='\(id)'><body>live \(id)</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='\(stanzaId)'/></message>")
}

private func messageCount(_ database: AppDatabase) throws -> Int {
    try database.reader.read { try YapnestKit.Message.fetchCount($0) }
}

// MARK: Leaving and failing to join a room

struct RoomFailureTests {
    let session: XMPPSession

    init() throws {
        session = try makeSession(me)
        try session.database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
    }

    private func status(_ phase: RoomStatus.Phase) {
        session.updateRoom(room) { $0 = RoomStatus(phase: phase, nickname: "me") }
    }

    @Test func aRestartOfTheRoomsServiceFailsTheRoomAndRejoinsLater() {
        status(.joined)
        session.roomPresence(selfPresence(type: "unavailable", statuses: [110, 332]), room: room)

        #expect(session.roomStatus(room)?.canRetry == true)
        #expect(session.hasScheduledRejoin(room))
        session.cancelAllRejoins()
    }

    @Test func liveMessagesFromARoomWeLeftAreDropped() throws {
        try session.database.updateGroupChat(room) { $0.hasLeft = true }
        session.handleRoomStanza(liveMessage(id: "l1", stanzaId: "r6"), source: .live)
        #expect(try messageCount(session.database) == 0)
        try session.database.updateGroupChat(room) { $0.hasLeft = false }
        session.handleRoomStanza(liveMessage(id: "l2", stanzaId: "r7"), source: .live)
        #expect(try messageCount(session.database) == 1)
    }

    @Test func beingKickedFailsTheRoomAndStaysOut() {
        status(.joined)
        session.roomPresence(selfPresence(type: "unavailable", statuses: [110, 307]), room: room)

        guard case .failed? = session.roomStatus(room)?.phase else {
            Issue.record("the room should have failed")
            return
        }
        #expect(session.roomStatus(room)?.canRetry == false)
        #expect(!session.hasScheduledRejoin(room))
    }

    @Test func aNicknameConflictRetryKeepsWhatTheRoomLookupLearned() {
        session.updateRoom(room) {
            var joining = RoomStatus(phase: .joining, nickname: "me", hasArchive: true, mayCreate: false)
            joining.supportsModeration = true
            joining.occupants = ["other": RoomOccupant(nick: "other", jid: nil, affiliation: .none)]
            $0 = joining
        }
        session.roomPresence(joinError("conflict"), room: room)

        let retry = session.roomStatus(room)
        #expect(retry?.phase == .joining)
        #expect(retry?.nickname == "me_")
        #expect(retry?.supportsModeration == true)
        #expect(retry?.hasArchive == true)
        #expect(retry?.mayCreate == false)
        #expect(retry?.triedOtherNickname == true)
        #expect(retry?.occupants.isEmpty == true)
    }

    @Test func aRemoteServerTimeoutOnJoiningIsRetried() {
        status(.joining)
        session.roomPresence(joinError("remote-server-timeout"), room: room)

        #expect(session.roomStatus(room)?.canRetry == true)
        #expect(session.hasScheduledRejoin(room))
        session.cancelAllRejoins()
    }

    @Test func aRefusedJoinIsNotRetried() {
        status(.joining)
        session.roomPresence(joinError("forbidden"), room: room)

        #expect(session.roomStatus(room)?.canRetry == false)
        #expect(!session.hasScheduledRejoin(room))
    }

    /// Both read as `undefined-condition`, but only the one naming no
    /// condition says nothing, and is retried.
    @Test func anUndefinedConditionIsNotRetriedButABareErrorIs() {
        status(.joining)
        session.roomPresence(joinError("undefined-condition"), room: room)
        #expect(session.roomStatus(room)?.canRetry == false)

        status(.joining)
        session.roomPresence(parseStanza("<presence type='error' from='cake@rooms.example.org/me'><error type='cancel'/></presence>"), room: room)
        #expect(session.roomStatus(room)?.canRetry == true)
        session.cancelAllRejoins()
    }

    private func joinError(_ condition: String) -> Martin.Presence {
        parseStanza("<presence type='error' from='cake@rooms.example.org/me'><error type='wait'><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>")
    }
}

// MARK: A room's catch-up that gave up

/// The cursor that the extension reads from must not skip what a catch-up
/// failed to fetch or store.
struct RoomCatchUpTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me")
        try database.updateGroupChat(room) { $0.lastArchiveId = "old" }
        session.reloadKnownRooms()
        var status = RoomStatus(phase: .joining, nickname: "me")
        status.hasArchive = true
        session.updateRoom(room) { $0 = status }
    }

    /// The room's archive answers the catch-up with one message and `fin`.
    private func archive(delivers message: String? = "<message from='cake@rooms.example.org/anna' type='groupchat' id='a1'><body>archived</body></message>", last: String = "r5") {
        let session = self.session
        wire.answer { request in
            guard let query = request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") else { return nil }
            if let message {
                session.client.module(.mam).archivedMessagesPublisher.send(.init(
                    messageId: "r4", source: room.martin, query: .init(id: query.getAttribute("queryid") ?? "", version: .MAM2),
                    timestamp: Date(), message: parseStanza(message),
                ))
            }
            return FakeWire.result(to: request, Self.fin(last: last))
        }
    }

    /// The end of an archive page, by default the archive's last.
    static func fin(last: String, complete: Bool = true) -> Element {
        let fin = Element(name: "fin", xmlns: "urn:xmpp:mam:2")
        if complete { fin.setAttribute("complete", value: "true") }
        fin.addChild(Element(name: "set", xmlns: "http://jabber.org/protocol/rsm", children: [Element(name: "last", cdata: last)]))
        return fin
    }

    private var cursor: String? { get throws { try database.groupChat(room)?.lastArchiveId } }

    @Test func aPageThatReachedTheEndLetsLiveMessagesMoveTheCursor() throws {
        archive()
        session.roomPresence(selfPresence(), room: room)

        #expect(session.roomStatus(room)?.isSyncing == false)
        #expect(try cursor == "r5")
        session.handleRoomStanza(liveMessage(id: "l1", stanzaId: "r6"), source: .live)
        #expect(try cursor == "r6")
    }

    @Test func aPageThatCouldNotBeStoredLeavesTheCursorForLiveMessagesToo() throws {
        archive()
        try failStoringMessages(database)
        session.roomPresence(selfPresence(), room: room)

        // The catch-up ended without the page, and without moving on.
        #expect(session.roomStatus(room)?.isSyncing == false)
        #expect(try cursor == "old")
        #expect(try messageCount(database) == 0)

        try allowStoringMessages(database)
        session.handleRoomStanza(liveMessage(id: "l1", stanzaId: "r6"), source: .live)
        #expect(try messageCount(database) == 1)
        #expect(try cursor == "old")
    }

    /// Answers every archive query with an incomplete page, ending at the
    /// cursor `last` gives for the page asked after.
    private func endlessArchive(last: @escaping @Sendable (String?) -> String) {
        wire.answer { request in
            guard let query = request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") else { return nil }
            let after = query.firstChild(name: "set", xmlns: "http://jabber.org/protocol/rsm")?.firstChild(name: "after")?.value
            return FakeWire.result(to: request, Self.fin(last: last(after), complete: false))
        }
    }

    private var archiveQueries: Int {
        wire.written.filter { ($0 as? Iq)?.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") != nil }.count
    }

    @Test func anArchiveThatNeverEndsIsReadAPageLimitAtATime() async throws {
        wire.answersLater = true
        endlessArchive { after in "\(after ?? "")+" }
        session.roomPresence(selfPresence(), room: room)

        #expect(await eventually(timeout: 10) { session.roomStatus(room)?.isSyncing == false })
        #expect(archiveQueries == XMPPSession.roomArchivePageLimit)
        // What's left is read from the cursor next time, so live messages
        // don't move it past.
        #expect(session.roomStatus(room)?.catchUpReachedEnd == false)
        #expect(try cursor?.hasPrefix("old+") == true)
        // The user is told, and a Retry that stops short again leaves it so.
        let key = "room-history:\(room)"
        #expect(session.warnings.current.contains { $0.key == key })
        #expect(await session.warnings.retry(key) == false)
        #expect(session.warnings.current.contains { $0.key == key })
    }

    @Test func anArchiveWhoseCursorDoesNotMoveIsReadOnce() throws {
        endlessArchive { after in after ?? "old" }
        session.roomPresence(selfPresence(), room: room)

        #expect(archiveQueries == 1)
        #expect(session.roomStatus(room)?.isSyncing == false)
        #expect(session.roomStatus(room)?.catchUpReachedEnd == false)
    }

    @Test func whatFollowsAPage() {
        #expect(XMPPSession.nextRoomArchivePage(after: "a", last: "b", complete: false, pagesRead: 1) == .after("b"))
        #expect(XMPPSession.nextRoomArchivePage(after: "a", last: "b", complete: true, pagesRead: 1) == .end)
        #expect(XMPPSession.nextRoomArchivePage(after: "a", last: nil, complete: false, pagesRead: 1) == .end)
        #expect(XMPPSession.nextRoomArchivePage(after: "a", last: "a", complete: false, pagesRead: 1) == .stop)
        #expect(XMPPSession.nextRoomArchivePage(after: "a", last: "b", complete: false, pagesRead: XMPPSession.roomArchivePageLimit) == .stop)
    }

    @Test func aPageTheArchiveRefusedLeavesTheCursorForLiveMessagesToo() throws {
        wire.answer { request in
            request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") == nil ? nil : FakeWire.error(to: request, condition: "forbidden", type: "auth")
        }
        session.roomPresence(selfPresence(), room: room)

        #expect(session.roomStatus(room)?.isSyncing == false)
        session.handleRoomStanza(liveMessage(id: "l1", stanzaId: "r6"), source: .live)
        #expect(try messageCount(database) == 1)
        #expect(try cursor == "old")
    }
}

// MARK: The account's catch-up

struct AccountCatchUpTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        session.lock.withLock { $0.archiveVersion = .MAM2 }
        try database.setSetting(.lastArchiveId, "old")
        let session = self.session
        wire.answer { request in
            guard let query = request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") else { return nil }
            session.client.module(.mam).archivedMessagesPublisher.send(.init(
                messageId: "s1", source: me.martin, query: .init(id: query.getAttribute("queryid") ?? "", version: .MAM2),
                timestamp: Date(), message: parseStanza("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='a1'><body>archived</body></message>"),
            ))
            return FakeWire.result(to: request, RoomCatchUpTests.fin(last: "s9"))
        }
    }

    @Test func aStoredPageMovesTheCursor() throws {
        session.catchUp()

        #expect(try database.setting(.lastArchiveId) == "s9")
        #expect(try messageCount(database) == 1)
    }

    @Test func aPageThatCouldNotBeStoredLeavesTheCursorWhereItWas() throws {
        try failStoringMessages(database)
        session.catchUp()

        #expect(try database.setting(.lastArchiveId) == "old")
        #expect(try messageCount(database) == 0)
        // The catch-up ends rather than going on past the lost page.
        #expect(session.state.value == .connected(isSyncing: false))
    }

    @Test func aFlushThatCouldNotStoreSaysSoAndRunsNoCallbacks() throws {
        let stored = OSAllocatedBool()
        let inbound = try #require(InboundMessage(
            parseStanza("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='a1'><body>hi</body></message>") as Martin.Message,
            account: me, source: .archive(serverId: "s1", timestamp: Date()),
        ))
        session.bufferArchived(inbound) { _ in stored.set() }

        try failStoringMessages(database)
        #expect(session.flushArchive() == false)
        #expect(!stored.value)

        try allowStoringMessages(database)
        session.bufferArchived(inbound) { _ in stored.set() }
        #expect(session.flushArchive() == true)
        #expect(stored.value)
    }
}

// MARK: Archive results about someone else's conversation

/// Martin doesn't tie an archive result to the archive that was queried, so a
/// hostile room could forward a message from another room.
struct ArchiveSourceTests {
    let database: AppDatabase
    let session: XMPPSession

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        try database.joinGroupChat(room, nickname: "me")
        try database.joinGroupChat(other, nickname: "me")
        session.reloadKnownRooms()
    }

    private func receive(from source: YapnestKit.JID, _ xml: String, id: String = "s1") {
        session.client.module(.mam).archivedMessagesPublisher.send(.init(
            messageId: id, source: source.martin, query: .init(id: "q", version: .MAM2), timestamp: Date(), message: parseStanza(xml),
        ))
        session.flushArchive()
    }

    private func bodies(in peer: YapnestKit.JID) throws -> [String] {
        try database.reader.read { db in
            guard let conversation = try Conversation.filter(Column("peer") == peer.description).fetchOne(db) else { return [] }
            return try YapnestKit.Message.filter(Column("conversationId") == conversation.id).order(Column("id")).fetchAll(db).map(\.body)
        }
    }

    @Test func aRoomsArchiveCannotWriteIntoAnotherRoom() throws {
        // The archive of cake forwards a message that claims to be from book.
        receive(from: room, "<message from='book@rooms.example.org/anna' type='groupchat' id='x1'><body>forged</body></message>")

        #expect(try bodies(in: other) == [])
        #expect(try bodies(in: room) == [])
    }

    @Test func aRoomsArchiveStoresItsOwnMessages() throws {
        receive(from: room, "<message from='cake@rooms.example.org/anna' type='groupchat' id='x1'><body>genuine</body></message>")

        #expect(try bodies(in: room) == ["genuine"])
    }

    @Test func ourArchiveCannotStoreAConversationBetweenOthers() throws {
        receive(from: me, "<message from='carol@example.org/phone' to='dave@example.org' type='chat' id='x1'><body>not ours</body></message>")

        #expect(try database.reader.read { try YapnestKit.Message.fetchCount($0) } == 0)
    }

    @Test func ourArchiveStoresWhatWeTookPartIn() throws {
        receive(from: me, "<message from='alice@example.org/phone' to='me@example.org' type='chat' id='x1'><body>hello</body></message>")

        #expect(try bodies(in: alice) == ["hello"])
    }
}

// MARK: Invitations

/// A room named by an invitation is joined only if it answers as a group
/// chat, and never created.
struct InvitationFlowTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    private let friend = YapnestKit.JID("friend@example.org")!

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try database.updateRosterItem(jid: friend, name: nil, subscription: .both, isPending: false)
    }

    /// Answers lookups of the room with `answers`, one after another, the last
    /// repeating.
    private func disco(_ answers: [(category: String, type: String)?]) {
        let calls = OSAllocatedCounter()
        wire.answer { request in
            guard request.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil else { return nil }
            let answer = answers[min(calls.next(), answers.count - 1)]
            guard let answer else { return FakeWire.error(to: request) }
            return FakeWire.discoInfo(to: request, category: answer.category, type: answer.type)
        }
    }

    private let direct = "<message from='friend@example.org/phone' to='me@example.org'><x xmlns='jabber:x:conference' jid='cake@rooms.example.org'/></message>"
    private let relayed = "<message from='cake@rooms.example.org' to='me@example.org'><x xmlns='http://jabber.org/protocol/muc#user'><invite from='friend@example.org'/></x></message>"

    private var lookups: Int {
        wire.written.filter { $0 is Iq && $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil }.count
    }

    private var joinWasSent: Bool {
        wire.written.contains { $0 is Martin.Presence && $0.to?.bareJid == room.martin }
    }

    private func invite(_ xml: String) {
        session.invitationReceived(parseStanza(xml) as Martin.Message)
    }

    /// Accepts the held invitation, waiting for the lookup and the join that may follow it.
    private func accepted() async -> Bool {
        let session = self.session
        let accepting = Task { try await session.acceptGroupInvitation(room) }
        _ = await eventually { lookups >= 1 }
        let joined = await eventually(timeout: 0.5) { joinWasSent }
        accepting.cancel()
        return joined
    }

    @Test func aRelayedInvitationIsHeldNotJoined() async throws {
        disco([("conference", "text")])
        invite(relayed)
        let held = try #require(try database.groupInvitation(room))
        #expect(!held.isDirect)
        // The room is on a subdomain of the inviter's server.
        #expect(held.isVouched)
        #expect(lookups == 0)
        #expect(!joinWasSent)
        #expect(session.roomStatus(room) == nil)
    }

    @Test func aDirectInvitationIsHeldNotJoined() async throws {
        disco([("conference", "text")])
        invite(direct)
        let held = try #require(try database.groupInvitation(room))
        #expect(held.isDirect)
        #expect(held.isVouched)
        #expect(lookups == 0)
        #expect(!joinWasSent)
        #expect(session.roomStatus(room) == nil)
    }

    @Test func aHeldRelayedInvitationIsJoinedOnAccept() async throws {
        disco([("conference", "text")])
        invite(relayed)
        #expect(await accepted())
        #expect(session.roomStatus(room)?.phase == .joining)
    }

    @Test func aHeldDirectInvitationIsJoinedOnAccept() async throws {
        disco([("conference", "text")])
        invite(direct)
        #expect(await accepted())
        #expect(session.roomStatus(room)?.phase == .joining)
    }

    @Test func aHeldInvitationToSomethingThatIsNotARoomIsNotJoined() async throws {
        disco([("conference", "irc")])
        invite(direct)
        #expect(await !accepted())
        #expect(session.roomStatus(room) == nil)
        #expect(try database.groupChat(room) == nil)
    }

    @Test func aHeldInvitationToAnAddressThatCannotBeLookedUpIsNotJoined() async throws {
        disco([nil])
        invite(direct)
        #expect(await !accepted())
        // It stopped at the failed lookup, rather than going on to join.
        #expect(lookups == 1)
        #expect(session.roomStatus(room) == nil)
        #expect(try database.groupChat(room) == nil)
    }

    @Test func aRoomThatVanishesBetweenTheLookupAndTheJoinIsNotCreated() async throws {
        // The first lookup finds it; joining looks it up again and it's gone.
        disco([("conference", "text"), nil])
        invite(direct)
        let session = self.session
        let accepting = Task { try await session.acceptGroupInvitation(room) }
        _ = await eventually { lookups >= 2 }
        #expect(await !eventually(timeout: 0.5) { joinWasSent })
        accepting.cancel()
        // Whatever the join left behind is cleaned up.
        #expect(await eventually { (try? database.groupChat(room)) == nil })
    }
}

