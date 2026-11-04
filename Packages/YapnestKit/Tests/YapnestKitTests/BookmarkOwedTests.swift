import Foundation
import GRDB
import Testing
@preconcurrency import Martin
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
private let pubsubNS = "http://jabber.org/protocol/pubsub"

/// A server that keeps XEP-0402 bookmarks: what it holds, what it was asked,
/// and how it answers a publish or a retraction.
private final class BookmarkServer: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Bookmark] = []
    private var publishes: [Bookmark] = []
    private var retractions: [String] = []
    private var order: [String] = []
    private var refusePublish: (@Sendable (Iq) -> Iq?)?
    private var refuseRetract: (@Sendable (Iq) -> Iq?)?
    private var onPublish: (@Sendable () -> Void)?
    private var rawHeld: Element?
    private var rawPublished: Element?
    private var refuseRead: (@Sendable (Iq) -> Iq?)?
    private var legacyCount = 0

    /// A conference as another client wrote it, served as is.
    var rawItem: Element? {
        get { lock.withLock { rawHeld } }
        set { lock.withLock { rawHeld = newValue } }
    }

    /// The last conference published, as it came.
    var publishedElement: Element? { lock.withLock { rawPublished } }

    var list: [Bookmark] {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    var published: [Bookmark] { lock.withLock { publishes } }
    var retracted: [String] { lock.withLock { retractions } }
    /// "publish" and "retract" in the order they reached the server.
    var requests: [String] { lock.withLock { order } }

    func refusingReads(_ answer: (@Sendable (Iq) -> Iq?)?) { lock.withLock { refuseRead = answer } }
    /// How many requests for the old kind of bookmarks arrived.
    var legacyRequests: Int { lock.withLock { legacyCount } }

    func refusingPublishes(_ answer: (@Sendable (Iq) -> Iq?)?) { lock.withLock { refusePublish = answer } }
    func refusingRetractions(_ answer: (@Sendable (Iq) -> Iq?)?) { lock.withLock { refuseRetract = answer } }
    func whenPublishing(_ action: (@Sendable () -> Void)?) { lock.withLock { onPublish = action } }

    func respond(_ iq: Iq) -> Iq? {
        guard let pubsub = iq.firstChild(name: "pubsub", xmlns: pubsubNS) else { return nil }
        // The old kind of bookmarks is not kept here.
        if pubsub.firstChild(name: "items")?.getAttribute("node") == NS.legacyBookmarks
            || pubsub.firstChild(name: "publish")?.getAttribute("node") == NS.legacyBookmarks {
            lock.withLock { legacyCount += 1 }
            return FakeWire.error(to: iq, condition: "service-unavailable")
        }
        if let items = pubsub.firstChild(name: "items"), items.getAttribute("node") == NS.bookmarks {
            if let refusal = lock.withLock({ refuseRead }) { return refusal(iq) }
            let result = Element(name: "pubsub", xmlns: pubsubNS)
            let list = Element(name: "items", attributes: ["node": NS.bookmarks])
            for bookmark in self.list {
                let item = Element(name: "item", attributes: ["id": bookmark.jid.description])
                item.addChild(lock.withLock { rawHeld } ?? bookmark.element)
                list.addChild(item)
            }
            result.addChild(list)
            return FakeWire.result(to: iq, result)
        }
        if let publish = pubsub.firstChild(name: "publish"), publish.getAttribute("node") == NS.bookmarks {
            guard let bookmark = Bookmark(id: publish.firstChild(name: "item")?.getAttribute("id") ?? "", payload: publish.firstChild(name: "item")?.firstChild(name: "conference")) else { return nil }
            let (refusal, action) = lock.withLock {
                publishes.append(bookmark)
                rawPublished = publish.firstChild(name: "item")?.firstChild(name: "conference")
                order.append("publish")
                return (refusePublish, onPublish)
            }
            action?()
            if let refusal { return refusal(iq) }
            lock.withLock { held.removeAll { $0.jid == bookmark.jid }; held.append(bookmark) }
            return FakeWire.result(to: iq)
        }
        if let retract = pubsub.firstChild(name: "retract"), retract.getAttribute("node") == NS.bookmarks {
            let id = retract.firstChild(name: "item")?.getAttribute("id") ?? ""
            let refusal = lock.withLock {
                retractions.append(id)
                order.append("retract")
                return refuseRetract
            }
            if let refusal { return refusal(iq) }
            lock.withLock { held.removeAll { $0.jid.description == id } }
            return FakeWire.result(to: iq)
        }
        return nil
    }
}

private func wait(_ iq: Iq) -> Iq { FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") }
private func forbidden(_ iq: Iq) -> Iq { FakeWire.error(to: iq, condition: "forbidden", type: "auth") }

struct OwedBookmarkTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    private let server = BookmarkServer()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.lock.withLock { $0.retryBackoff = 0 }
        try database.joinGroupChat(room, nickname: "me", name: "Cake", isBookmarked: true)
        session.reloadKnownRooms()
    }

    /// Connects to a server that keeps XEP-0402 bookmarks (`#compat`).
    private func connect(_ session: XMPPSession? = nil) async {
        let session = session ?? self.session
        let server = server
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:xmpp:bind:0" || bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
                result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
                return FakeWire.result(to: iq, result)
            }
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
                query.addChild(Element(name: "feature", attributes: ["var": NS.bookmarks + "#compat"]))
                return FakeWire.result(to: iq, query)
            }
            return server.respond(iq)
        }
        session.connectForTesting(wire)
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind(completionHandler: nil)
        session.client.module(.disco).discoverAccountFeatures(completionHandler: nil)
        _ = await eventually { !session.usesLegacyBookmarks }
    }

    private func catchUp(_ session: XMPPSession? = nil) async {
        let session = session ?? self.session
        let done = Locked<Bool?>(nil)
        session.syncBookmarks { done.value = $0 }
        _ = await eventually { done.value != nil }
    }

    private func group() throws -> GroupChat { try #require(try database.groupChat(room)) }

    private func ban() {
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
        let presence: Martin.Presence = parseStanza("<presence from='cake@rooms.example.org/me' type='unavailable'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='outcast' role='none'/><status code='110'/><status code='301'/></x></presence>")
        session.roomPresence(presence, room: room)
    }

    private var listedAsBefore: Bookmark { Bookmark(jid: room, name: "Cake", autojoin: true, nick: "me", notify: .always) }

    // MARK: A change made offline

    @Test func aNotifySettingChangedOfflineSurvivesACatchUpAndIsPublished() async throws {
        try session.setNotify(.never, in: room)
        #expect(try group().bookmarkOwed)
        server.list = [listedAsBefore]
        await connect()

        await catchUp()

        #expect(try group().notify == .never)
        #expect(await eventually { (try? group().bookmarkOwed) == false })
        #expect(server.published.last?.notify == .never)
        session.cancelAllRejoins()
    }

    @Test func aRepublishAfterANewNameKeepsAPasswordAndExtensionsOfOtherClients() async throws {
        let held = try #require(Element.from(string: """
        <conference xmlns='urn:xmpp:bookmarks:1' name='Cake' autojoin='true'><nick>me</nick><password>s3cret</password>\
        <extensions><notify xmlns='urn:xmpp:notification-settings:1'><never identity-category='client' identity-type='pc'/><always/></notify>\
        <other xmlns='urn:example:gajim'>kept</other></extensions></conference>
        """))
        server.rawItem = held
        server.list = [listedAsBefore]
        await connect()
        try database.setRoomInfo(room, name: "Pie", isMembersOnly: false, isNonAnonymous: false)
        session.sendOwedBookmarks()

        #expect(await eventually { server.publishedElement != nil })
        let sent = try #require(server.publishedElement)
        #expect(sent.getAttribute("name") == "Pie")
        #expect(sent.firstChild(name: "password")?.value == "s3cret")
        let extensions = try #require(sent.firstChild(name: "extensions"))
        #expect(extensions.firstChild(name: "other")?.value == "kept")
        let settings = try #require(extensions.firstChild(name: "notify"))
        #expect(settings.getChildren(name: "never").first?.getAttribute("identity-type") == "pc")
    }

    @Test func aPasswordInABookmarkIsKeptToJoinWith() async throws {
        let bookmark = Bookmark(jid: room, name: "Cake", autojoin: true, nick: "me", password: "s3cret")
        session.reconcileBookmarks([bookmark])
        #expect(try group().password == "s3cret")
        #expect(Bookmark(id: room.description, payload: bookmark.element)?.password == "s3cret")
    }

    @Test func ourPasswordIsNotAddedToABookmarkWithoutOne() async throws {
        try database.updateGroupChat(room) { $0.password = "ours" }
        let group = try group()
        #expect(Bookmark(group).element.firstChild(name: "password") == nil)
        let held = try #require(Element.from(string: "<conference xmlns='urn:xmpp:bookmarks:1' name='Cake' autojoin='true'><password>theirs</password></conference>"))
        #expect(Bookmark(group).merged(into: held).firstChild(name: "password")?.value == "theirs")
    }

    @Test func aNotifySettingChangedOnlineIsPublishedAndConfirmed() async throws {
        await connect()
        try session.setNotify(.onMention, in: room)
        #expect(await eventually { (try? group().bookmarkOwed) == false })
        #expect(server.published.map(\.notify) == [.onMention])
    }

    @Test func aChangeMadeWhileOneIsBeingSentStaysOwedAndIsSentNext() async throws {
        await connect()
        let session = session
        let once = Locked(true)
        server.whenPublishing {
            if once.value {
                once.value = false
                try? session.setNotify(.never, in: room)
            }
        }
        try session.setNotify(.onMention, in: room)

        #expect(await eventually { server.published.map(\.notify) == [.onMention, .never] })
        #expect(await eventually { (try? group().bookmarkOwed) == false })
        #expect(try group().notify == .never)
    }

    @Test func aRenameMadeWhileOneIsBeingSentStaysOwedAndIsSentNext() async throws {
        await connect()
        let database = database
        let once = Locked(true)
        server.whenPublishing {
            if once.value {
                once.value = false
                try? database.setRoomInfo(room, name: "Pie", isMembersOnly: false, isNonAnonymous: false)
            }
        }
        try session.setNotify(.onMention, in: room)

        #expect(await eventually { server.published.count == 1 })
        await session.sendOwedBookmarks()?.value
        #expect(await eventually { server.published.map(\.name) == ["Cake", "Pie"] })
        #expect(await eventually { (try? group().bookmarkOwed) == false })
    }

    @Test func aRenameThatIsOwedIsPublishedWithTheNewName() throws {
        try database.setRoomInfo(room, name: "Pie", isMembersOnly: false, isNonAnonymous: false)
        #expect(try group().bookmarkOwed)
        #expect(try group().name == "Pie")
    }

    @Test func anUnchangedNameOrAnUnbookmarkedGroupOwesNothing() throws {
        try database.setRoomInfo(room, name: "Cake", isMembersOnly: false, isNonAnonymous: false)
        #expect(try !group().bookmarkOwed)
        try database.updateGroupChat(room) { $0.isBookmarked = false }
        try database.setRoomInfo(room, name: "Pie", isMembersOnly: false, isNonAnonymous: false)
        #expect(try !group().bookmarkOwed)
    }

    @Test func aGroupWeLeftOwesNothingForANotifyChange() throws {
        try database.updateGroupChat(room) { $0.hasLeft = true }
        try session.setNotify(.never, in: room)
        #expect(try !group().bookmarkOwed)
    }

    @Test func whatTheServerSaysDoesNotReplaceAnOwedGroupLive() async throws {
        try session.setNotify(.never, in: room)
        session.reconcileBookmarks([Bookmark(jid: room, name: "Other", autojoin: true, nick: "me", notify: .always)])
        #expect(try group().notify == .never)
        #expect(try group().name == "Cake")
        // Its first publish hasn't landed, so the absence says nothing.
        try database.updateGroupChat(room) { $0.isBookmarked = false }
        session.bookmarkChanged(.retracted(room))
        #expect(try !group().hasLeft)
        session.bookmarkChanged(.published(Bookmark(jid: room, name: "Other", autojoin: true, nick: "me", notify: .always)))
        #expect(try group().notify == .never)
    }

    // MARK: Leaving on another device

    @Test func leavingElsewhereWinsOverAnOwedPublishAtCatchUp() async throws {
        // A session that doesn't send, so that the connect's own resumption can't publish before the list is read.
        let reading = try makeSession(me, database: database, mode: .notificationService)
        try session.setNotify(.never, in: room)
        server.list = []
        await connect(reading)

        await catchUp(reading)

        #expect(try group().hasLeft)
        #expect(try !group().bookmarkOwed)
        #expect(server.published.isEmpty)
    }

    @Test func aBookmarkWithoutAutojoinAlsoMeansLeftElsewhere() async throws {
        try session.setNotify(.never, in: room)
        session.reconcileBookmarks([Bookmark(jid: room, name: "Cake", autojoin: false, nick: "me")])
        #expect(try group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    @Test func leavingElsewhereWinsOverAnOwedPublishLive() async throws {
        try session.setNotify(.never, in: room)
        session.bookmarkChanged(.retracted(room))
        #expect(try group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    @Test func aGroupWhoseFirstPublishHasntLandedIsPublishedWhenAbsentFromTheList() async throws {
        try database.updateGroupChat(room) { $0.isBookmarked = false }
        try session.setNotify(.never, in: room)
        server.list = []
        await connect()

        await catchUp()

        #expect(try !group().hasLeft)
        #expect(await eventually { server.published.last?.notify == .never && (try? group().bookmarkOwed) == false })
        session.cancelAllRejoins()
    }

    @Test func leavingElsewhereDuringASendIsNotUndoneByIt() async throws {
        await connect()
        let session = session
        server.whenPublishing { session.bookmarkChanged(.retracted(room)) }
        try session.setNotify(.never, in: room)
        #expect(await eventually { !server.published.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    // MARK: Leaving without the server's bookmark going

    @Test func aBanWhoseRetractionFailsIsNotJoinedAgainAtTheNextCatchUp() async throws {
        await connect()
        server.list = [listedAsBefore]
        server.refusingRetractions { wait($0) }

        ban()

        #expect(await eventually { !server.retracted.isEmpty })
        #expect(try group().hasLeft)
        #expect(try group().bookmarkOwed)

        server.refusingRetractions(nil)
        await catchUp()

        #expect(try group().hasLeft)
        #expect(await eventually { server.retracted.count >= 2 && (try? group().bookmarkOwed) == false })
        #expect(server.list.isEmpty)
        #expect(try group().hasLeft)
    }

    @Test func aBanMadeWhileOfflineIsRetractedAtTheNextConnect() async throws {
        ban()
        #expect(try group().hasLeft)
        #expect(try group().bookmarkOwed)
        server.list = [listedAsBefore]
        await connect()

        await catchUp()

        #expect(try group().hasLeft)
        #expect(await eventually { server.retracted == [room.description] && (try? group().bookmarkOwed) == false })
    }

    @Test func aDestroyedGroupIsRetractedAndNotJoinedAgain() async throws {
        session.groupDestroyed(room)
        #expect(try group().bookmarkOwed)
        server.list = [listedAsBefore]
        await connect()

        await catchUp()

        #expect(try group().hasLeft)
        #expect(await eventually { server.retracted == [room.description] && (try? group().bookmarkOwed) == false })
    }

    @Test func aLeftGroupThatIsRejoinedPublishesInsteadOfRetracting() async throws {
        ban()
        try database.joinGroupChat(room, nickname: "me")
        #expect(try group().bookmarkOwed)
        await connect()
        session.sendOwedBookmarks()

        #expect(await eventually { server.published.count == 1 })
        #expect(server.retracted.isEmpty)
    }

    @Test func theNotificationExtensionOwesButDoesNotSend() async throws {
        let quiet = try makeSession(me, database: database, mode: .notificationService)
        quiet.connectForTesting(wire)
        wire.answer { [server] in server.respond($0) }
        try quiet.setNotify(.never, in: room)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try group().bookmarkOwed)
        #expect(server.published.isEmpty)
    }

    // MARK: Errors

    @Test func aPassingErrorLeavesItOwedWithoutAWarning() async throws {
        await connect()
        server.refusingPublishes { wait($0) }
        try session.setNotify(.never, in: room)
        #expect(await eventually { !server.published.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try group().bookmarkOwed)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aReadThatFailsLeavesTheXEP0402PublishOwedInsteadOfFallingBack() async throws {
        await connect()
        server.refusingReads { wait($0) }

        try session.setNotify(.never, in: room)

        try await Task.sleep(for: .milliseconds(500))
        #expect(server.legacyRequests == 0)
        #expect(server.published.isEmpty)
        #expect(try group().bookmarkOwed)

        server.refusingReads(nil)
        session.sendOwedBookmarks()
        #expect(await eventually { (try? group().bookmarkOwed) == false })
        #expect(server.published.last?.notify == .never)
    }

    @Test func aRefusedRetractionShowsAWarningWithRetry() async throws {
        await connect()
        server.refusingRetractions { forbidden($0) }

        ban()

        #expect(await eventually { session.warnings.current.contains { $0.key == "bookmark/\(room)" } })
        #expect(try !group().bookmarkOwed)
        #expect(session.warnings.current.first?.action == .retry)

        server.refusingRetractions(nil)
        let gone = await session.warnings.retry("bookmark/\(room)")
        #expect(gone)
        #expect(session.warnings.current.isEmpty)
        #expect(server.retracted.count == 2)
        #expect(try !group().bookmarkOwed)
    }

    @Test func aRefusedPublishShowsAWarningAndRetryKeepsItWhileRefused() async throws {
        await connect()
        server.refusingPublishes { forbidden($0) }

        try session.setNotify(.never, in: room)

        // The old kind of bookmark is tried after the refusal, on a queue the whole process shares.
        #expect(await eventually(timeout: 40) { session.warnings.current.contains { $0.key == "bookmark/\(room)" } })
        #expect(try !group().bookmarkOwed)
        let gone = await session.warnings.retry("bookmark/\(room)")
        #expect(!gone)
        #expect(session.warnings.current.contains { $0.key == "bookmark/\(room)" })
    }

    // MARK: Leaving

    @Test func leavingOfflineLeavesAtOnceAndRetractsAtTheNextConnect() async throws {
        server.list = [listedAsBefore]
        try await session.leaveGroup(room)
        #expect(try group().hasLeft)
        #expect(try group().bookmarkOwed)

        await connect()
        await catchUp()

        #expect(try group().hasLeft)
        #expect(await eventually { server.retracted == [room.description] && (try? group().bookmarkOwed) == false })
        #expect(server.list.isEmpty)
    }

    @Test func aGroupLeftOfflineIsNotJoinedAgainFromItsBookmark() async throws {
        server.list = [listedAsBefore]
        try await session.leaveGroup(room)
        session.reconcileBookmarks([listedAsBefore])
        #expect(try group().hasLeft)
        #expect(try group().bookmarkOwed)
    }

    @Test func aLeaveOwedSurvivesANewSessionOnTheSameDatabase() async throws {
        try await session.leaveGroup(room)
        let next = try makeSession(me, database: database)
        server.list = [listedAsBefore]
        await connect(next)
        await catchUp(next)

        #expect(await eventually { server.retracted == [room.description] && (try? group().bookmarkOwed) == false })
        #expect(try group().hasLeft)
    }

    @Test func aRetractionThatPassesWhileLeavingIsOwedInsteadOfFailing() async throws {
        await connect()
        server.refusingRetractions { wait($0) }

        try await session.leaveGroup(room)

        #expect(try group().hasLeft)
        #expect(try group().bookmarkOwed)
    }

    @Test func aRetractionRefusedForGoodWhileLeavingThrowsAndChangesNothing() async throws {
        await connect()
        server.refusingRetractions { forbidden($0) }

        await #expect(throws: GroupError.self) { try await session.leaveGroup(room) }

        #expect(try !group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    @Test func leavingWithoutOwingTheRetractionThrowsOfflineAndChangesNothing() async throws {
        do {
            try await session.leaveGroup(room, owingRetraction: false)
            Issue.record("Leaving should have thrown")
        } catch GroupError.notConnected {
        }

        #expect(try !group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    @Test func leavingWithoutOwingTheRetractionThrowsAPassingErrorAndChangesNothing() async throws {
        await connect()
        server.refusingRetractions { wait($0) }

        do {
            try await session.leaveGroup(room, owingRetraction: false)
            Issue.record("Leaving should have thrown")
        } catch let error as ServerError {
            #expect(error.isPassing)
            #expect(error.condition == "resource-constraint")
        }

        #expect(try !group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    @Test func leavingWithoutOwingTheRetractionThrowsAFinalRefusalAndChangesNothing() async throws {
        await connect()
        server.refusingRetractions { forbidden($0) }

        do {
            try await session.leaveGroup(room, owingRetraction: false)
            Issue.record("Leaving should have thrown")
        } catch GroupError.leaveRefused(let error) {
            #expect(error.condition == "forbidden")
        }

        #expect(try !group().hasLeft)
        #expect(try !group().bookmarkOwed)
    }

    @Test func leavingWithoutOwingTheRetractionRetractsOnceConnected() async throws {
        await connect()
        server.list = [listedAsBefore]

        try await session.leaveGroup(room, owingRetraction: false)

        #expect(try group().hasLeft)
        #expect(try !group().bookmarkOwed)
        #expect(server.list.isEmpty)
    }

    // MARK: Ordering

    @Test func leavingWaitsForAPublishThatIsStillOwed() async throws {
        await connect()
        try session.setNotify(.never, in: room)
        try await session.leaveGroup(room)

        #expect(server.requests == ["publish", "retract"])
        #expect(try group().hasLeft)
        #expect(try !group().bookmarkOwed)
        #expect(server.list.isEmpty)
    }
}

/// A server that keeps only the old kind of bookmarks: no node yet, and a set
/// it answers as told. Every request is answered, as the old kind waits for
/// each on a queue the whole process shares.
struct OwedLegacyBookmarkTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    private let sets = Locked(0)
    private let heldStorage = Locked<Element?>(nil)
    private let publishedStorage = Locked<Element?>(nil)

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.lock.withLock { $0.retryBackoff = 0 }
        try database.joinGroupChat(room, nickname: "me", name: "Cake", isBookmarked: true)
        session.reloadKnownRooms()
    }

    private func connect(_ session: XMPPSession? = nil, refusingSetsWith refusal: @escaping @Sendable (Iq) -> Iq) async {
        let session = session ?? self.session
        let sets = sets, heldStorage = heldStorage, publishedStorage = publishedStorage
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:xmpp:bind:0" || bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
                result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
                return FakeWire.result(to: iq, result)
            }
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                return FakeWire.result(to: iq, Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info"))
            }
            guard let pubsub = iq.firstChild(name: "pubsub", xmlns: pubsubNS) else { return nil }
            if pubsub.firstChild(name: "items")?.getAttribute("node") == NS.legacyBookmarks {
                guard let storage = heldStorage.value else { return FakeWire.error(to: iq, condition: "item-not-found") }
                let result = Element(name: "pubsub", xmlns: pubsubNS)
                let list = Element(name: "items", attributes: ["node": NS.legacyBookmarks])
                let item = Element(name: "item", attributes: ["id": "current"])
                item.addChild(storage)
                list.addChild(item)
                result.addChild(list)
                return FakeWire.result(to: iq, result)
            }
            if let publish = pubsub.firstChild(name: "publish"), publish.getAttribute("node") == NS.legacyBookmarks {
                publishedStorage.value = publish.firstChild(name: "item")?.firstChild(name: "storage")
                sets.value += 1
                return refusal(iq)
            }
            return FakeWire.error(to: iq, condition: "service-unavailable")
        }
        session.connectForTesting(wire)
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind(completionHandler: nil)
        session.client.module(.disco).discoverAccountFeatures(completionHandler: nil)
        _ = await eventually { session.usesLegacyBookmarks && session.isConnected }
    }

    private func group() throws -> GroupChat { try #require(try database.groupChat(room)) }

    @Test func aRepublishOfTheOldKindKeepsAPasswordAndUnknownChildrenOfOtherClients() async throws {
        heldStorage.value = try #require(Element.from(string: """
        <storage xmlns='storage:bookmarks'><conference jid='cake@rooms.example.org' name='Cake' autojoin='true'><nick>me</nick>\
        <password>s3cret</password><extensions><other xmlns='urn:example:conversations'>kept</other></extensions></conference></storage>
        """))
        await connect { FakeWire.result(to: $0) }
        try database.setRoomInfo(room, name: "Pie", isMembersOnly: false, isNonAnonymous: false)
        session.sendOwedBookmarks()

        #expect(await eventually { publishedStorage.value != nil })
        let conference = try #require(publishedStorage.value?.firstChild(name: "conference"))
        #expect(conference.getAttribute("name") == "Pie")
        #expect(conference.firstChild(name: "password")?.value == "s3cret")
        #expect(conference.firstChild(name: "extensions")?.firstChild(name: "other")?.value == "kept")
    }

    @Test func aFinalRefusalOfTheOldKindShowsAWarningAndStopsBeingOwed() async throws {
        await connect { forbidden($0) }
        #expect(session.usesLegacyBookmarks)
        try session.setNotify(.never, in: room)

        #expect(await eventually(timeout: 40) { session.warnings.current.contains { $0.key == "bookmark/\(room)" } })
        #expect(try !group().bookmarkOwed)
        #expect(session.warnings.current.first?.action == .retry)
    }

    @Test func aFinalRefusalOfTheOldKindIsNotSentAgainAtTheNextConnect() async throws {
        await connect { forbidden($0) }
        try session.setNotify(.never, in: room)
        #expect(await eventually(timeout: 40) { session.warnings.current.contains { $0.key == "bookmark/\(room)" } })
        let sent = sets.value

        let later = try makeSession(me, database: database)
        later.lock.withLock { $0.retryBackoff = 0 }
        later.reloadKnownRooms()
        await connect(later) { forbidden($0) }
        later.sendOwedBookmarks()
        try await Task.sleep(for: .milliseconds(300))
        #expect(sets.value == sent)
        #expect(later.warnings.current.isEmpty)
    }

    @Test func aRetryOfTheOldKindThrowsTheRefusalWhileTheServerStillRefuses() async throws {
        await connect { forbidden($0) }
        try session.setNotify(.never, in: room)
        #expect(await eventually(timeout: 40) { session.warnings.current.contains { $0.key == "bookmark/\(room)" } })
        let retry = try #require(session.warnings.current.first?.retry)

        let error = await #expect(throws: (any Error).self) { try await retry() }
        #expect(ServerError.userMessage(for: try #require(error), friendly: "").contains("forbidden"))
        #expect(try !group().bookmarkOwed)
        #expect(session.warnings.current.contains { $0.key == "bookmark/\(room)" })
    }

    @Test func aPassingErrorOfTheOldKindKeepsItOwedWithoutAWarning() async throws {
        await connect { wait($0) }
        try session.setNotify(.never, in: room)

        #expect(await eventually(timeout: 40) { sets.value > 0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try group().bookmarkOwed)
        #expect(session.warnings.current.isEmpty)
    }
}

struct BookmarkOwedMigrationTests {
    @Test func theColumnIsAddedToADatabaseFromBefore() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v52-pending-block-changes")
        try AppDatabase.migrator.migrate(queue)
        let column = try queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(groupChat)").first { $0["name"] as String == "bookmarkOwed" } }
        #expect(column?["notnull"] as Int? == 1)
        #expect(column?["dflt_value"] as String? == "0" || column?["dflt_value"] as String? == "false")
    }
}
