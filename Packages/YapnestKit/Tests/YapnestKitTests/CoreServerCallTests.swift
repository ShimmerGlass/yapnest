import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!

private func isDisco(_ iq: Iq) -> Bool {
    iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil
}

private func bindResult(_ iq: Iq) -> Iq? {
    guard let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" else { return nil }
    let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
    result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
    return FakeWire.result(to: iq, result)
}

private func isArchiveQuery(_ iq: Iq) -> Bool {
    iq.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") != nil
}

// MARK: Account discovery

struct AccountDiscoveryFailureTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.lock.withLock { $0.retryBackoff = 0 }
    }

    private func connect(answeringDiscoWith answer: @escaping @Sendable (Iq) -> Iq) {
        wire.answer { iq in bindResult(iq) ?? (isDisco(iq) ? answer(iq) : nil) }
        session.connectForTesting(wire, syncing: true)
        session.lock.withLock { $0.awaitsAccountDiscovery = true }
        session.client.module(.resourceBind).bind()
        session.client.module(.disco).discoverAccountFeaturesOnBind()
    }

    private var discoRequests: Int {
        wire.written.compactMap { $0 as? Iq }.filter { isDisco($0) && $0.to?.stringValue == "me@example.org" }.count
    }

    @Test func aDiscoveryThatKeepsTimingOutStillLeadsToCatchUpAndIsShown() async throws {
        connect { FakeWire.error(to: $0, condition: "remote-server-timeout", type: "wait") }
        #expect(await eventually { session.state.value == .connected(isSyncing: false) })
        #expect(discoRequests == ServerRetry.attempts + 1)
        #expect(session.warnings.current.map(\.key) == ["discovery"])
    }

    @Test func aFinalRefusalOfTheDiscoveryGoesOnAndShowsTheReason() async throws {
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        #expect(await eventually { session.state.value == .connected(isSyncing: false) })
        #expect(discoRequests == 1)
        #expect(session.warnings.current.map(\.key) == ["discovery"])
        #expect(session.warnings.current.first?.retry != nil)
    }

    @Test func aDiscoveryThatPassesOnTheSecondTryLearnsTheFeatures() async throws {
        let calls = OSAllocatedCounter()
        connect { iq in
            calls.next() == 0
                ? FakeWire.error(to: iq, condition: "internal-server-error", type: "wait")
                : FakeWire.discoInfo(to: iq, category: "account", type: "registered", features: ["urn:xmpp:mam:2"])
        }
        #expect(await eventually { session.lock.withLock { $0.archiveVersion } == .MAM2 })
        #expect(session.warnings.current.isEmpty)
    }
}

// MARK: Archive catch-up

struct ArchiveCatchUpFailureTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.lock.withLock { $0.retryBackoff = 0 }
        try database.setSetting(.lastArchiveId, "cursor")
        session.connectForTesting(wire, syncing: true)
        session.lock.withLock { $0.archiveVersion = .MAM2 }
    }

    /// Answers the first `failing` queries with a timeout, then with a last page.
    private func answerQueries(failing: Int) {
        let calls = OSAllocatedCounter()
        wire.answer { request in
            guard isArchiveQuery(request) else { return nil }
            if calls.next() < failing { return FakeWire.error(to: request, condition: "remote-server-timeout", type: "wait") }
            let fin = Element(name: "fin", xmlns: "urn:xmpp:mam:2")
            fin.setAttribute("complete", value: "true")
            fin.addChild(Element(name: "set", xmlns: "http://jabber.org/protocol/rsm", children: [Element(name: "last", cdata: "page-2")]))
            return FakeWire.result(to: request, fin)
        }
    }

    private var queries: Int {
        wire.written.compactMap { $0 as? Iq }.filter(isArchiveQuery).count
    }

    @Test func aPageThatFailsOnceIsAskedForAgain() async throws {
        answerQueries(failing: 1)
        session.catchUp()
        #expect(await eventually { session.state.value == .connected(isSyncing: false) })
        #expect(queries == 2)
        #expect(try database.setting(.lastArchiveId) == "page-2")
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aPageThatNeverAnswersEndsTheSyncWithAWarningAndTheCursorWhereItWas() async throws {
        answerQueries(failing: 100)
        session.catchUp()
        #expect(await eventually { session.state.value == .connected(isSyncing: false) })
        #expect(queries == ServerRetry.attempts)
        #expect(try database.setting(.lastArchiveId) == "cursor")
        #expect(session.warnings.current.map(\.title) == ["Some messages may be missing"])
    }

    @Test func aFinalErrorEndsTheSyncAtOnceWithAWarning() async throws {
        wire.answer { request in
            isArchiveQuery(request) ? FakeWire.error(to: request, condition: "forbidden", type: "auth") : nil
        }
        session.catchUp()
        #expect(await eventually { session.state.value == .connected(isSyncing: false) })
        #expect(queries == 1)
        #expect(try database.setting(.lastArchiveId) == "cursor")
        #expect(session.warnings.current.map(\.key) == ["archive"])
    }

    @Test func theWarningsRetryReadsThePageAndClearsIt() async throws {
        answerQueries(failing: 100)
        session.catchUp()
        #expect(await eventually { session.warnings.current.count == 1 })
        answerQueries(failing: 0)
        #expect(await session.warnings.retry("archive"))
        #expect(session.warnings.current.isEmpty)
        #expect(try database.setting(.lastArchiveId) == "page-2")
    }
}

// MARK: Read state

struct ReadStatePublishTests {
    let session: XMPPSession
    let wire = FakeWire()
    let alice = YapnestKit.JID("alice@example.org")!

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
    }

    private var message: YapnestKit.Message {
        YapnestKit.Message(conversationId: 1, direction: .incoming, sender: alice, body: "hi", timestamp: Date(), serverId: "s1")
    }

    private func requests(_ kind: String) -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "pubsub")?.firstChild(name: kind) != nil }
    }

    @Test func aPublishTheNodeRefusesForItsOptionsReconfiguresItAndGoesAgain() async throws {
        wire.answer { iq in
            guard let pubsub = iq.firstChild(name: "pubsub") else { return nil }
            if pubsub.firstChild(name: "publish") != nil, pubsub.firstChild(name: "publish-options") != nil {
                return FakeWire.error(to: iq, condition: "conflict")
            }
            return FakeWire.result(to: iq)
        }
        session.publishDisplayed(message, route: .direct(alice))
        #expect(await eventually { requests("configure").count == 1 && requests("publish").count == 2 })
        let configured = try #require(requests("configure").first?.firstChild(name: "pubsub")?.firstChild(name: "configure")?.attribute("node"))
        #expect(configured == NS.mds)
        #expect(session.warnings.current.isEmpty)
        #expect(session.lock.withLock { $0.publishedDisplayed[alice] } == "s1")
    }

    @Test func aPublishRefusedForGoodIsShownAndLetsTheNextReadTryAgain() async throws {
        wire.answer { iq in
            iq.firstChild(name: "pubsub")?.firstChild(name: "publish") != nil ? FakeWire.error(to: iq, condition: "forbidden", type: "auth") : nil
        }
        session.publishDisplayed(message, route: .direct(alice))
        #expect(await eventually { session.warnings.current.map(\.key) == ["readState"] })
        #expect(session.lock.withLock { $0.publishedDisplayed[alice] } == nil)
    }
}

// MARK: Stream management, timeouts and carbons

struct AcknowledgementRequestTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
    }

    private var requests: Int {
        wire.written.filter { $0.name == "r" && $0.xmlns == "urn:xmpp:sm:3" }.count
    }

    @Test func aStreamWithoutManagementIsNotAskedToAcknowledge() {
        session.requestAcknowledgement()
        session.sendUnclaimedPending()
        #expect(requests == 0)
    }

    @Test func requestsInQuickSuccessionAreSentOnceAndTheNextOneWaitsItsTurn() async throws {
        session.enableAcknowledgementsForTesting()
        for _ in 0..<3 { session.requestAcknowledgement() }
        #expect(requests == 1)
        // Not lost: the server is asked again once the second is up.
        #expect(await eventually(timeout: 3) { requests == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(requests == 2)
    }
}

struct ResponseDeadlineTests {
    @Test func aRequestTimesOutNearItsDeadlineNotAtTheNextSweep() async throws {
        let manager = ResponseManager()
        let iq = Iq()
        iq.type = .get
        iq.to = Martin.JID("example.org")
        iq.id = "q1"
        let answered = OSAllocatedBool()
        let started = Date()
        _ = manager.registerResponseHandler(for: iq, timeout: 0.2, errorDecoder: XMPPError.from(stanza:)) { (_: Result<Iq, XMPPError>) in
            answered.set()
        }
        #expect(await eventually(timeout: 15) { answered.value })
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test func anAnsweredRequestIsNotTimedOutAfterwards() async throws {
        let manager = ResponseManager()
        let iq = Iq()
        iq.type = .get
        iq.to = Martin.JID("example.org")
        iq.id = "q2"
        let calls = OSAllocatedCounter()
        _ = manager.registerResponseHandler(for: iq, timeout: 0.2, errorDecoder: XMPPError.from(stanza:)) { (_: Result<Iq, XMPPError>) in
            _ = calls.next()
        }
        let reply = Iq()
        reply.type = .result
        reply.id = "q2"
        reply.from = Martin.JID("example.org")
        try await Task.sleep(for: .milliseconds(20))
        manager.getResponseHandler(for: reply)?(reply)
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls.next() == 1)
    }
}

struct CarbonsEnableTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.lock.withLock { $0.retryBackoff = 0 }
    }

    /// Connects, which asks for carbons by itself, and has what follows go to a wire of its own.
    private func connect() async {
        let first = FakeWire()
        session.connectForTesting(first)
        _ = await eventually { first.written.contains { ($0 as? Iq)?.firstChild(name: "enable", xmlns: "urn:xmpp:carbons:2") != nil } }
        session.client.writer = wire
    }

    private var enables: Int {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "enable", xmlns: "urn:xmpp:carbons:2") != nil }.count
    }

    @Test func carbonsBind2AlreadyEnabledAreNotEnabledAgain() async throws {
        session.client.modulesManager.module(Sasl2Module.IDENTIFIER).carbonsEnabledInline = true
        let first = FakeWire()
        session.connectForTesting(first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(first.written.compactMap { $0 as? Iq }.allSatisfy { $0.firstChild(name: "enable", xmlns: "urn:xmpp:carbons:2") == nil })
    }

    @Test func carbonsAreEnabledWhenBind2DidNot() async throws {
        await connect()
        wire.answer { FakeWire.result(to: $0) }
        session.enableCarbons()
        #expect(await eventually { enables == 1 })
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aRefusalIsShownWithARetry() async throws {
        await connect()
        wire.answer { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.enableCarbons()
        #expect(await eventually { session.warnings.current.map(\.key) == ["carbons"] })
        #expect(enables == 1)
        wire.answer { FakeWire.result(to: $0) }
        #expect(await session.warnings.retry("carbons"))
    }

    @Test func aTimeoutIsTriedAgain() async throws {
        await connect()
        let calls = OSAllocatedCounter()
        wire.answer { calls.next() == 0 ? FakeWire.error(to: $0, condition: "remote-server-timeout", type: "wait") : FakeWire.result(to: $0) }
        session.enableCarbons()
        #expect(await eventually { enables == 2 })
        #expect(session.warnings.current.isEmpty)
    }
}

// MARK: Waiting for a connection, and confirming without stream management

struct RunOnceConnectedTests {
    @Test func workWaitsForAConnectionThatComesLate() async throws {
        let session = try makeSession(me)
        let ran = OSAllocatedBool()
        let attempt = session.lock.withLock { $0.attempt }
        session.runOnceConnected(attempt: attempt, tries: 2) { ran.set() }
        // Past the quick looks, which used to be the last.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!ran.value)
        session.connectForTesting(FakeWire())
        // The connection is this one's: connecting counts a new attempt, which the work was not started for.
        session.lock.withLock { $0.attempt = attempt }
        #expect(await eventually { ran.value })
    }

    @Test func workForAConnectionThatWasReplacedIsDropped() async throws {
        let session = try makeSession(me)
        let ran = OSAllocatedBool()
        session.runOnceConnected(attempt: -1, tries: 0) { ran.set() }
        session.connectForTesting(FakeWire())
        try await Task.sleep(for: .milliseconds(500))
        #expect(!ran.value)
    }
}

struct PingConfirmationRetryTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let alice = YapnestKit.JID("alice@example.org")!

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try session.setEncrypted(false, with: alice)
    }

    private func status(of message: YapnestKit.Message) throws -> YapnestKit.Message.Status? {
        try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.status }
    }

    @Test func aPingThatTimesOutIsSentAgainAndItsReplyConfirmsTheMessage() async throws {
        let pings = OSAllocatedCounter()
        wire.answer { iq in
            guard iq.firstChild(name: "ping", xmlns: "urn:xmpp:ping") != nil else { return nil }
            return pings.next() == 0 ? FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait") : FakeWire.result(to: iq)
        }
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        #expect(await eventually { (try? status(of: message)) == .sent })
        #expect(wire.pings.count == 2)
    }

    @Test func pingsThatNeverAreAnsweredEndInACheckOfTheConnection() async throws {
        wire.answer { iq in
            iq.firstChild(name: "ping", xmlns: "urn:xmpp:ping") != nil ? FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait") : nil
        }
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        #expect(await eventually { wire.pings.count == XMPPSession.confirmationPings + 1 })
        #expect(try status(of: message) == .pending)
    }
}
