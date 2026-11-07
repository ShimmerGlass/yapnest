import Combine
import Foundation
import GRDB
import os
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

/// How the stand-in server answers a client that asks to resume.
private enum ResumeAnswer {
    case accepts(h: UInt32)
    case refuses
    /// No stream management at all: the new session isn't resumable.
    case unsupported
}

/// What the stand-in server saw and what it will say.
private final class ServerScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [Stanza] = []
    private var _stops: [Bool] = []
    var answer: ResumeAnswer
    /// Stanzas the server sends right after signing in, as it replays what it held.
    var afterSignIn: [Element] = []
    /// Stanzas that reach the client while it is closing the connection.
    var duringStop: [Element] = []
    /// How long the close takes to finish, as on a loaded device: the stanzas above arrive, and the
    /// connection is reported closed, only then.
    var stopDelay: TimeInterval = 0
    init(_ answer: ResumeAnswer) { self.answer = answer }

    var sent: [Stanza] { lock.withLock { _sent } }
    /// One entry per close, whether it was forced: a graceful close is what sends `</stream>`.
    var stops: [Bool] { lock.withLock { _stops } }
    func record(_ stanza: Stanza) { lock.withLock { _sent.append(stanza) } }
    func recordStop(force: Bool) { lock.withLock { _stops.append(force) } }

    var authentications: [Stanza] { sent.filter { $0.name == "authenticate" } }
    var archiveQueries: [Iq] {
        sent.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") != nil }
    }
}

private struct ScriptedOptions: ConnectorOptions {
    var script = ServerScript(.refuses)
    init() {}
    init(script: ServerScript) { self.script = script }
    var connector: Connector.Type { ScriptedServer.self }
}

/// A server on the other side of a connector: offers SASL2 with stream management, answers a sign-in the
/// way `script` says, and answers the requests that follow so that a session can finish its catch-up.
private final class ScriptedServer: Connector {
    static var supportedProtocols: [ConnectorProtocol] { [] }
    @Published var state: ConnectorState = .disconnected()
    var statePublisher: Published<ConnectorState>.Publisher { $state }
    let events = PassthroughSubject<StreamEvent, Never>()
    var streamEventsPublisher: AnyPublisher<StreamEvent, Never> { events.eraseToAnyPublisher() }
    var availableFeatures: Set<ConnectorFeature> = []
    var activeFeatures: Set<ConnectorFeature> = [.TLS]
    var streamLogger: StreamLogger?
    var currentEndpoint: ConnectorEndpoint?
    let script: ServerScript

    required init(context: Context) {
        script = (context.connectionConfiguration.connectorOptions as! ScriptedOptions).script
    }

    func activate(feature: ConnectorFeature) {}
    func restartStream() {}
    func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? { nil }
    func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? { nil }

    func start(endpoint: ConnectorEndpoint?) {
        DispatchQueue.global().async { [self] in
            state = .connecting
            state = .connected
            events.send(.streamStart)
        }
    }

    func stop(force: Bool, completionHandler: @escaping () -> Void) {
        script.recordStop(force: force)
        let finish = { [self] in
            for element in script.duringStop { events.send(.stanza(Stanza.from(element: element))) }
            state = .disconnected()
            completionHandler()
        }
        if script.stopDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + script.stopDelay, execute: finish)
        } else {
            finish()
        }
    }

    private func features(signIn: Bool) -> Stanza {
        let features = Element(name: "features", xmlns: "http://etherx.jabber.org/streams")
        if signIn {
            var inline = [element("bind", "urn:xmpp:bind:0")]
            if case .unsupported = script.answer {} else { inline.append(element("sm", "urn:xmpp:sm:3")) }
            features.addChild(element("authentication", "urn:xmpp:sasl:2", [:], [
                Element(name: "mechanism", cdata: "PLAIN"),
                element("inline", "urn:xmpp:sasl:2", [:], inline),
            ]))
        }
        return Stanza.from(element: features)
    }

    func send(_ data: StreamEvent, completion: WriteCompletion) {
        switch data {
        case .streamOpen:
            DispatchQueue.global().async { [self] in events.send(.stanza(features(signIn: true))) }
        case .stanza(let stanza):
            script.record(stanza)
            respond(to: stanza)
        default:
            break
        }
    }

    private func respond(to stanza: Stanza) {
        DispatchQueue.global().async { [self] in
            if stanza.name == "authenticate" {
                signedIn(resuming: stanza.findChild(name: "resume", xmlns: "urn:xmpp:sm:3"))
            } else if let iq = stanza as? Iq, iq.type == .get || iq.type == .set {
                events.send(.stanza(result(to: iq)))
            }
        }
    }

    private func signedIn(resuming resume: Element?) {
        var children = [Element(name: "authorization-identifier", cdata: "alice@localhost/app")]
        switch script.answer {
        case .accepts(let h) where resume != nil:
            children.append(element("resumed", "urn:xmpp:sm:3", ["h": String(h), "previd": resume?.getAttribute("previd") ?? ""]))
            events.send(.stanza(Stanza.from(element: element("success", "urn:xmpp:sasl:2", [:], children))))
            for stanza in script.afterSignIn { events.send(.stanza(Stanza.from(element: stanza))) }
            return
        case .unsupported:
            children.append(element("bound", "urn:xmpp:bind:0"))
        default:
            // A refused resume, or none asked for: the server binds a new session, which it can resume.
            if resume != nil { children.append(element("failed", "urn:xmpp:sm:3")) }
            children.append(element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "new-stream", "resume": "true"]),
            ]))
        }
        events.send(.stanza(Stanza.from(element: element("success", "urn:xmpp:sasl:2", [:], children))))
        events.send(.stanza(features(signIn: false)))
        for stanza in script.afterSignIn { events.send(.stanza(Stanza.from(element: stanza))) }
    }

    private func result(to iq: Iq) -> Iq {
        let reply = Iq()
        reply.type = .result
        reply.id = iq.id
        reply.from = iq.to
        if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
            reply.addChild(element("query", "http://jabber.org/protocol/disco#info", [:], [
                element("identity", "http://jabber.org/protocol/disco#info", ["category": "account", "type": "registered"]),
                element("feature", "http://jabber.org/protocol/disco#info", ["var": "urn:xmpp:mam:2"]),
            ]))
        } else if iq.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") != nil {
            reply.addChild(element("fin", "urn:xmpp:mam:2", ["complete": "true"], [element("set", "http://jabber.org/protocol/rsm")]))
        } else if iq.firstChild(name: "query", xmlns: "jabber:iq:roster") != nil {
            reply.addChild(element("query", "jabber:iq:roster", [:], [element("item", "jabber:iq:roster", ["jid": "bob@localhost", "subscription": "both"])]))
        }
        return reply
    }
}

private let aliceJid = JID("alice@localhost")!

private func ticketed(_ snapshot: StreamManagementModule.Snapshot) -> (ResumeTicketStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ticket-\(UUID().uuidString)")
    let store = ResumeTicketStore(directory: AccountDirectory(url: directory))
    store.save(snapshot)
    return (store, directory)
}

private let appStream = StreamManagementModule.Snapshot(
    id: "app-stream", timeout: 600, incoming: 7, outgoing: 5, boundJid: "alice@localhost/app", resumedH: 4,
)

private func session(
    _ mode: XMPPSession.Mode, answering answer: ResumeAnswer, store: ResumeTicketStore?, bound: String? = "app",
    callMedia: (any CallMediaFactory)? = nil,
) throws -> (XMPPSession, ServerScript) {
    let database = try AppDatabase.inMemory()
    let session = try XMPPSession(
        credentials: .init(jid: aliceJid, password: "x", disableTLS: true), resource: mode == .app ? "app" : "push", database: database, mode: mode,
        callMedia: callMedia, identityKeys: testIdentityKeys(for: database), boundResource: mode == .app ? nil : bound, resumeTickets: store,
    )
    let script = ServerScript(answer)
    session.client.connectionConfiguration.connectorOptions = ScriptedOptions(script: script)
    return (session, script)
}

/// The extension takes over the app's stream, so the server never sees a second session come and go.
struct ResumedStreamTests {
    @Test(.timeLimit(.minutes(1)))
    func theExtensionResumesTheTicketsStreamAndCatchesUpOnIt() async throws {
        let (store, directory) = ticketed(appStream)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try #require(store.load())
        let (extensionSession, server) = try session(.notificationService, answering: .accepts(h: 5), store: store)

        let finished = await extensionSession.catchUpOnce(timeout: 20)

        #expect(finished)
        let resume = try #require(server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3"))
        #expect(resume.getAttribute("previd") == "app-stream")
        #expect(resume.getAttribute("h") == "7")
        #expect(server.authentications.count == 1)
        // A resumed stream asks for nothing by itself: the catch-up is the extension's own doing.
        #expect(!server.archiveQueries.isEmpty, "the extension returned without reading the archive")
        #expect(server.stops == [true], "leaving sent </stream>, which ends the stream the app needs")

        let after = try #require(store.load())
        #expect(after.generation > before.generation)
        #expect(after.stream.id == "app-stream")
        #expect(after.stream.resumedH == 5)
        #expect(after.stream.boundJid == "alice@localhost/app")
        // The server counted the extension's own requests and the extension its answers.
        #expect(after.stream.outgoing > appStream.outgoing)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedResumeFallsBackToANewSessionAndLeavesItsTicket() async throws {
        let (store, directory) = ticketed(appStream)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try #require(store.load())
        let (extensionSession, server) = try session(.notificationService, answering: .refuses, store: store)

        let finished = await extensionSession.catchUpOnce(timeout: 20)

        #expect(finished)
        #expect(!server.archiveQueries.isEmpty)
        #expect(server.stops == [true])
        let after = try #require(store.load(), "the new session left no ticket for the next wake")
        #expect(after.stream.id == "new-stream")
        #expect(after.stream.resumedH == nil)
        #expect(after.generation > before.generation)
        #expect(after.stream.boundJid == "alice@localhost/app")
    }

    @Test(.timeLimit(.minutes(1)))
    func withoutATicketTheExtensionOpensASessionAndLeavesATicket() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (extensionSession, server) = try session(.notificationService, answering: .refuses, store: store)

        #expect(await extensionSession.catchUpOnce(timeout: 20))

        #expect(server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3") == nil)
        #expect(server.stops == [true])
        #expect(store.load()?.stream.id == "new-stream")
    }

    /// A server without resumption gets the usual close, and no ticket says otherwise.
    @Test(.timeLimit(.minutes(1)))
    func aServerThatCannotResumeGetsAGracefulCloseAndNoTicket() async throws {
        let (store, directory) = ticketed(appStream)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (extensionSession, server) = try session(.notificationService, answering: .unsupported, store: store)

        #expect(await extensionSession.catchUpOnce(timeout: 20))

        #expect(server.stops == [false])
        #expect(store.load() == nil)
    }

    /// The extension's time ran out before the stream came up: nothing was learned about the ticket, which
    /// may still be good, so it stays as it was.
    @Test(.timeLimit(.minutes(1)))
    func aResumeThatNeverConnectedKeepsTheTicket() async throws {
        let (store, directory) = ticketed(appStream)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try #require(store.load())
        let database = try AppDatabase.inMemory()
        let unreachable = try XMPPSession(
            credentials: .init(jid: aliceJid, password: "x", host: "127.0.0.1", port: 1, disableTLS: true), resource: "push", database: database,
            mode: .notificationService, identityKeys: testIdentityKeys(for: database), boundResource: "app", resumeTickets: store,
        )

        #expect(await unreachable.catchUpOnce(timeout: 3) == false)

        #expect(store.load() == before)
    }

    /// What the room said while the app was away reaches the extension in the resumed stream's queue, but
    /// without the occupants that say who wrote it. Stored from there an encrypted message was kept as
    /// undecryptable, and its archive copy, which the extension reads next, dropped as a duplicate.
    @Test func anExtensionLeavesTheRoomsLiveMessagesToItsArchiveRead() throws {
        let room = YapnestKit.JID("cake@rooms.example.org")!
        func stored(by mode: XMPPSession.Mode, source: InboundMessage.Source) throws -> Int {
            let database = try AppDatabase.inMemory()
            let session = try makeSession(JID("me@example.org")!, database: database, mode: mode)
            try database.joinGroupChat(room, nickname: "me")
            session.reloadKnownRooms()
            session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
            session.handleRoomStanza(parseStanza(
                "<message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>hi</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='s1'/></message>",
            ), source: source)
            // The archive's results wait for the end of their page.
            _ = session.flushArchive()
            return try database.reader.read { try YapnestKit.Message.fetchCount($0) }
        }
        #expect(try stored(by: .app, source: .live) == 1)
        #expect(try stored(by: .notificationService, source: .live) == 0)
        #expect(try stored(by: .notificationService, source: .archive(serverId: "s1", timestamp: Date())) == 1)
    }


    // MARK: What an extension consumes from the stream, kept for the app

    private static let caller = "bob@localhost/phone"
    private static let bob = YapnestKit.JID("bob@localhost")!
    private static let room = YapnestKit.JID("cake@rooms.localhost")!

    private func xml(_ text: String) -> Element { Element.from(string: text)! }

    private func proposal(sid: String, from: String = caller, delayedBy age: TimeInterval? = nil) -> Element {
        let stamp = age.map { "<delay xmlns='urn:xmpp:delay' from='localhost' stamp='\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-$0)))'/>" } ?? ""
        return xml("<message from='\(from)' to='alice@localhost' type='chat' id='p-\(sid)'><propose xmlns='urn:xmpp:jingle-message:0' id='\(sid)'><description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/></propose>\(stamp)</message>")
    }

    private func retraction(sid: String) -> Element {
        xml("<message from='\(Self.caller)' to='alice@localhost' type='chat' id='r-\(sid)'><retract xmlns='urn:xmpp:jingle-message:0' id='\(sid)'/></message>")
    }

    private func presence(_ show: String?) -> Element {
        xml("<presence from='\(Self.caller)' to='alice@localhost/app'>\(show.map { "<show>\($0)</show>" } ?? "")</presence>")
    }

    private func roomMessage(_ id: String, body: String) -> Element {
        xml("<message from='cake@rooms.localhost/anna' to='alice@localhost/app' type='groupchat' id='\(id)'><body>\(body)</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.localhost' id='s-\(id)'/></message>")
    }

    private func freshStore() -> (ResumeTicketStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ticket-\(UUID().uuidString)")
        return (ResumeTicketStore(directory: AccountDirectory(url: directory)), directory)
    }

    /// Which of an app's connections were resumptions.
    private final class ResumeLog: @unchecked Sendable {
        let values = OSAllocatedUnfairLock(initialState: [Bool]())
        var cancellable: AnyCancellable?
        var resumed: Bool { values.withLock { $0.contains(true) } }
    }

    /// An app that signed in with bob online and a room joined, then suspended; an extension that woke and
    /// found `replayed` waiting in the stream.
    private struct Scene {
        var app: XMPPSession
        var appServer: ServerScript
        var extensionServer: ServerScript
        var store: ResumeTicketStore
        var directory: URL
        var log: ResumeLog
        /// What the app had unacknowledged when it suspended, and the counter then.
        var queued: [Stanza]
        var written: UInt32
    }

    private func scene(
        replayed: [Element], handled: UInt32? = nil, calls: Bool = false, wakes: [[Element]] = [],
    ) async throws -> Scene {
        let (store, directory) = freshStore()
        let (app, appServer) = try session(.app, answering: .refuses, store: store, callMedia: calls ? FakeCallMediaFactory() : nil)
        let log = ResumeLog()
        log.cancellable = app.client.$state.sink { state in
            if case .connected(let resumed) = state { log.values.withLock { $0.append(resumed) } }
        }
        try await app.database.writer.write { db in
            try Contact(jid: Self.bob, subscription: .both, isInRoster: true).insert(db)
        }
        try app.database.joinGroupChat(Self.room, nickname: "alice")
        app.reloadKnownRooms()
        app.connect()
        await eventually("the app to sync") { app.state.value == .connected(isSyncing: false) }
        // A new session forgets presences when it comes up, so bob is heard once it has.
        app.client.replayIncoming(Stanza.from(element: presence(nil)))
        await eventually("the app to see bob online") { app.presence(of: Self.bob) == .online }
        app.updateRoom(Self.room) { $0 = RoomStatus(phase: .joined, nickname: "alice") }
        await app.suspend()
        let sm = app.client.module(.streamManagement)
        let queued = sm.unacknowledgedStanzas
        let written = try #require(sm.snapshot).outgoing

        var extensionServer = ServerScript(.refuses)
        for (n, wake) in ([replayed] + wakes).enumerated() {
            // The server's count after an earlier wake includes what that wake sent.
            let h = n == 0 ? handled ?? written : try #require(store.load()).stream.outgoing
            let (woken, server) = try session(.notificationService, answering: .accepts(h: h), store: store)
            server.afterSignIn = wake
            #expect(await woken.catchUpOnce(timeout: 20), "wake \(n + 1)")
            extensionServer = server
        }
        return Scene(
            app: app, appServer: appServer, extensionServer: extensionServer, store: store, directory: directory, log: log, queued: queued, written: written,
        )
    }

    /// The app comes back, and the server resumes the stream, having handled everything the app and the extension sent.
    private func returning(_ scene: Scene, live: [Element] = []) async throws {
        let ticket = try #require(scene.store.load())
        scene.appServer.answer = .accepts(h: ticket.stream.outgoing)
        scene.appServer.afterSignIn = live
        scene.app.connect()
        await eventually("the app to be back") { scene.app.isConnected && scene.appServer.authentications.count == 2 }
    }

    private func resumeRequest(_ server: ServerScript) -> Element? {
        server.authentications.last?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3")
    }

    /// What an extension keeps is what the app's modules act on and it doesn't store, in the order it came.
    @Test(.timeLimit(.minutes(1)))
    func theJournalHoldsWhatTheAppNeedsAndNothingElse() async throws {
        let (store, directory) = ticketed(appStream)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (woken, _) = try session(.notificationService, answering: .accepts(h: 5), store: store)
        let server = ServerScript(.accepts(h: 5))
        woken.client.connectionConfiguration.connectorOptions = ScriptedOptions(script: server)
        server.afterSignIn = [
            presence("away"),
            roomMessage("g1", body: "in the room"),
            xml("<message from='bob@localhost/phone' to='alice@localhost' type='chat' id='c1'><body>stored by the extension</body></message>"),
            xml("<iq from='localhost' to='alice@localhost/app' type='get' id='v1'><query xmlns='jabber:iq:version'/></iq>"),
            xml("<iq from='localhost' to='alice@localhost/app' type='result' id='x1'/>"),
            xml("<iq from='alice@localhost' type='set' id='ro1'><query xmlns='jabber:iq:roster'><item jid='bob@localhost' subscription='both'/></query></iq>"),
            xml("<message from='bob@localhost' to='alice@localhost' type='headline' id='e1'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:avatar:metadata'/></event></message>"),
            xml("<message from='cake@rooms.localhost' to='alice@localhost/app' id='mam1'><result xmlns='urn:xmpp:mam:2' queryid='q' id='1'><forwarded xmlns='urn:xmpp:forward:0'><message type='groupchat' from='cake@rooms.localhost/x'><body>archived</body></message></forwarded></result></message>"),
            proposal(sid: "j1"),
            xml("<message from='alice@localhost' to='alice@localhost/app' id='k1'><sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'><message from='alice@localhost/tablet' to='bob@localhost/phone' type='chat'><reject xmlns='urn:xmpp:jingle-message:0' id='j2'/></message></forwarded></sent></message>"),
            xml("<message from='alice@localhost' to='alice@localhost/app' id='k2'><received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'><message from='bob@localhost/phone' to='alice@localhost' type='chat' id='c2'><body>a carbon, stored</body></message></forwarded></received></message>"),
        ]

        #expect(await woken.catchUpOnce(timeout: 20))

        let journal = store.readJournal()
        #expect(journal.isComplete)
        let kept = try journal.entries.map { try #require(Element.from(string: $0.xml)) }.map { "\($0.name)/\($0.getAttribute("id") ?? "-")" }
        #expect(kept == ["presence/-", "message/g1", "iq/ro1", "message/e1", "message/p-j1", "message/k1"])
        #expect(Set(journal.entries.map(\.stream)) == ["app-stream"])
        #expect(journal.entries.allSatisfy { abs($0.at.timeIntervalSinceNow) < 60 })
    }

    /// A message the server queued carries its own `<delay>`, which a room's stamp isn't: the replay adds
    /// the time the extension read it, vouched for by the room, or the message would be dated by the return.
    @Test func aReplayedRoomMessageIsDatedByWhenTheExtensionReadIt() throws {
        let at = Date().addingTimeInterval(-3600)
        let queued = "<message from='cake@rooms.localhost/anna' type='groupchat' id='g'><body>hi</body><delay xmlns='urn:xmpp:delay' from='localhost' stamp='2026-01-01T00:00:00Z'/></message>"
        let elements = XMPPSession.journalReplay(
            [JournalEntry(stream: "s", at: at, xml: queued)], account: YapnestKit.JID("alice@localhost")!, now: Date(), offset: 0,
            isRoom: { $0 == Self.room }, callsOnly: false,
        )
        let first = try #require(elements.first)
        let message = try #require(Stanza.from(element: first) as? Martin.Message)
        let stamp = InboundMessage.trustedStamp(in: message, stamper: Self.room, account: YapnestKit.JID("alice@localhost")!)
        let stamped = try #require(stamp)
        #expect(abs(stamped.timeIntervalSince(at)) < 2)
    }

    @Test func theJournalAppendsAcrossWakesAndOverflowsInsteadOfGrowing() throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        func entry(_ n: Int) -> JournalEntry { JournalEntry(stream: "s", at: Date(), xml: "<presence from='bob@localhost/\(n)'/>") }
        let first = ResumeJournal(store: store, capacity: 400)
        first.append(entry(1))
        // A later wake goes on from the file.
        let second = ResumeJournal(store: store, capacity: 400)
        second.append(entry(2))
        #expect(store.readJournal().entries.count == 2)
        #expect(store.readJournal().isComplete)

        for n in 3...10 { second.append(entry(n)) }

        let after = store.readJournal()
        #expect(second.isLost)
        #expect(!after.isComplete)
        #expect(after.entries.count < 10, "the journal grew past its capacity")
        #expect(after.entries.count >= 2, "what was kept before the overflow is still there, for the calls in it")
        // Not appended to once lost, and lost for the next wake too.
        let size = try Data(contentsOf: store.journalURL).count
        second.append(entry(11))
        #expect(try Data(contentsOf: store.journalURL).count == size)
        #expect(ResumeJournal(store: store, capacity: 400).isLost == false)
        let third = ResumeJournal(store: store, capacity: 400)
        third.append(entry(12))
        #expect(third.isLost)
    }

    @Test func theJournalHasTheTicketsProtectionAndIsLeftOutOfBackups() throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        ResumeJournal(store: store).append(JournalEntry(stream: "s", at: Date(), xml: "<presence/>"))
        let protection = (try FileManager.default.attributesOfItem(atPath: store.journalURL.path))[.protectionKey] as? FileProtectionType
        #expect(protection == nil || protection == FileProtection.level)
        #expect(try store.journalURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// The app resumes the stream the extension used, with the extension's counters, and sees what it
    /// consumed: a contact's presence, a room's message once, and a call offer that rings.
    @Test(.timeLimit(.minutes(1)))
    func theAppResumesAfterAnExtensionAndReplaysWhatItConsumed() async throws {
        let scene = try await scene(
            replayed: [presence("away"), roomMessage("g1", body: "hello room"), proposal(sid: "call-1")], calls: true,
        )
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }
        let ticket = try #require(scene.store.load())
        #expect(scene.app.presence(of: Self.bob) == .online, "the extension's read reached the app before it returned")

        try await returning(scene)

        let resume = try #require(resumeRequest(scene.appServer))
        #expect(resume.getAttribute("previd") == ticket.stream.id)
        #expect(resume.getAttribute("h") == String(ticket.stream.incoming), "the app resumed with counters from before the extension")
        #expect(scene.log.resumed, "the app started a new session")
        await eventually("the presence replayed") { scene.app.presence(of: Self.bob) == .away }
        await eventually("the call to ring") { scene.app.callState.value?.phase == .incoming }
        func copies() throws -> Int {
            try scene.app.database.reader.read { try YapnestKit.Message.filter(Column("body") == "hello room").fetchCount($0) }
        }
        try await eventually("the room's message") { try copies() == 1 }
        try await Task.sleep(for: .seconds(1))
        #expect(try copies() == 1)
        #expect(scene.store.load() == nil)
        #expect(scene.store.readJournal() == JournalContents(entries: [], isComplete: true), "the journal was left to be replayed again")
    }

    /// Counted stanzas the server sent after the extension left arrive live, after the replay: a newer
    /// presence is not overwritten by an older one.
    @Test(.timeLimit(.minutes(1)))
    func aPresenceTheServerSendsAfterTheReplayWins() async throws {
        let scene = try await scene(replayed: [presence("away")])
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }

        try await returning(scene, live: [presence("dnd"), presence(nil)])

        await eventually("the live presence") { scene.app.presence(of: Self.bob) == .online }
        try await Task.sleep(for: .seconds(1))
        #expect(scene.app.presence(of: Self.bob) == .online)
    }

    @Test(.timeLimit(.minutes(1)))
    func aProposeThatIsPastTheRingWindowDoesNotRing() async throws {
        let scene = try await scene(replayed: [proposal(sid: "old", delayedBy: 120)], calls: true)
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }

        try await returning(scene)
        try await Task.sleep(for: .seconds(1))

        #expect(scene.log.resumed)
        #expect(scene.app.callState.value == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallThatEndedInTheJournalDoesNotRing() async throws {
        let scene = try await scene(replayed: [proposal(sid: "call-2"), retraction(sid: "call-2")], calls: true)
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }

        try await returning(scene)
        try await Task.sleep(for: .seconds(1))

        #expect(scene.log.resumed)
        #expect(scene.app.callState.value == nil)
    }

    /// The caller gave up after the extension left: the retraction is live, and ends the call the replay rang.
    @Test(.timeLimit(.minutes(1)))
    func aLiveEndSignalEndsTheCallTheReplayRang() async throws {
        let scene = try await scene(replayed: [proposal(sid: "call-3")], calls: true)
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }

        try await returning(scene, live: [retraction(sid: "call-3")])

        await eventually("the call to have rung and ended") {
            scene.app.callState.value == nil || scene.app.callState.value?.phase.isEnded == true
        }
        #expect(scene.log.resumed)
        #expect(scene.app.callState.value?.phase != .incoming)
    }

    /// An app that was evicted has no stream in memory, so it starts a new session, and still rings for
    /// the offer the extension consumed: a new session would only read it back from the archive.
    @Test(.timeLimit(.minutes(1)))
    func anEvictedAppStartsANewSessionAndStillRingsForAFreshPropose() async throws {
        let scene = try await scene(replayed: [presence("away"), proposal(sid: "call-4")], calls: true)
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }
        let (reborn, server) = try session(.app, answering: .refuses, store: scene.store, callMedia: FakeCallMediaFactory())
        defer { reborn.disconnect() }
        try await reborn.database.writer.write { try Contact(jid: Self.bob, subscription: .both, isInRoster: true).insert($0) }

        reborn.connect()

        await eventually("the call to ring") { reborn.callState.value?.phase == .incoming }
        #expect(!server.authentications.isEmpty)
        #expect(server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3") == nil)
        #expect(scene.store.load() == nil)
        #expect(scene.store.readJournal() == JournalContents(entries: [], isComplete: true))
    }

    /// The journal is the extension's, of the stream it resumed: one that names another stream isn't
    /// applied to this one, and the app starts a new session.
    @Test(.timeLimit(.minutes(1)))
    func aJournalFromAnotherStreamIsIgnored() async throws {
        let scene = try await scene(replayed: [presence("away")])
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }
        let entries = scene.store.readJournal().entries
        scene.store.deleteJournal()
        let foreign = ResumeJournal(store: scene.store)
        for entry in entries { foreign.append(JournalEntry(stream: "another-stream", at: entry.at, xml: entry.xml)) }

        scene.appServer.answer = .refuses
        scene.app.connect()
        await eventually("the sign-in") { scene.appServer.authentications.count == 2 }

        #expect(resumeRequest(scene.appServer) == nil)
        try await Task.sleep(for: .seconds(1))
        #expect(scene.app.presence(of: Self.bob) == .offline, "a journal of another stream was replayed into a new session")
    }

    /// Anything that makes the journal unreliable sends the app to a new session, which has none of its gaps.
    @Test(.timeLimit(.minutes(2)), arguments: ["overflow", "torn", "ticket", "crashed", "unnamed"])
    func aJournalThatCannotBeTrustedStartsANewSession(_ fault: String) async throws {
        let scene = try await scene(replayed: [presence("away")])
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }
        let ticket = try #require(scene.store.load())
        switch fault {
        case "overflow":
            scene.store.deleteJournal()
            let small = ResumeJournal(store: scene.store, capacity: 10)
            small.append(JournalEntry(stream: ticket.stream.id, at: Date(), xml: "<presence from='bob@localhost/phone'/>"))
        case "torn":
            let handle = try FileHandle(forWritingTo: scene.store.journalURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"entry\":{\"xml\":".utf8))
            try handle.close()
        case "ticket":
            scene.store.save(ticket.stream, appHandled: ticket.appHandled, journalLost: true)
        case "crashed":
            // The extension died before it left: the ticket is still the app's own.
            let saved = scene.store.load()
            scene.store.delete()
            if let saved { scene.store.save(saved.stream) }
            scene.store.deleteJournal()
            ResumeJournal(store: scene.store).append(JournalEntry(stream: ticket.stream.id, at: Date(), xml: "<presence from='bob@localhost/phone'/>"))
        default:
            // Nothing says how much of the app's own stanzas arrived.
            scene.store.save(ticket.stream)
        }

        scene.appServer.answer = .refuses
        scene.app.connect()
        await eventually("the sign-in") { scene.appServer.authentications.count == 2 }

        #expect(resumeRequest(scene.appServer) == nil, "\(fault): the app resumed")
    }

    /// Two wakes: the second's `resumedH` counts the first's stanzas, so the ticket carries the first's, which
    /// is what the app's own stanzas had reached.
    @Test(.timeLimit(.minutes(1)))
    func theTicketKeepsWhatTheFirstWakeFoundOfTheAppsOwnStanzas() async throws {
        let scene = try await scene(replayed: [presence("away")], handled: 4, wakes: [[presence(nil)]])
        defer { try? FileManager.default.removeItem(at: scene.directory); scene.app.disconnect() }

        let ticket = try #require(scene.store.load())
        #expect(ticket.appHandled == 4)
        #expect(ticket.stream.resumedH != 4, "the second wake's resumedH counts the first wake's stanzas")
        // Both wakes' stanzas are in the journal, in order.
        #expect(scene.store.readJournal().entries.count == 2)
    }

    /// What the app wrote that the server never got is sent again after the extension's own stanzas, and what
    /// it did get isn't: the counts then agree, so the server takes the resumption and nothing is lost or doubled.
    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func theAppSendsAgainOnlyWhatTheServerNeverGot(_ lost: Int) async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, appServer) = try session(.app, answering: .refuses, store: store)
        defer { app.disconnect() }
        app.connect()
        await eventually("the app to sync") { app.state.value == .connected(isSyncing: false) }
        await app.suspend()
        let sm = app.client.module(.streamManagement)
        let queued = sm.unacknowledgedStanzas
        let written = try #require(sm.snapshot).outgoing
        #expect(Int(written) == queued.count, "the server never acknowledged, so everything is still queued")
        let handled = written - UInt32(lost)
        let (woken, extensionServer) = try session(.notificationService, answering: .accepts(h: handled), store: store)
        #expect(await woken.catchUpOnce(timeout: 20))
        let ticket = try #require(store.load())
        let own = extensionServer.sent.filter { ["iq", "message", "presence"].contains($0.name) }.count
        #expect(ticket.appHandled == handled)
        #expect(ticket.stream.outgoing == handled + UInt32(own), "the extension's counter is the server's: what it handled plus what it wrote itself")

        appServer.answer = .accepts(h: ticket.stream.outgoing)
        let sentBefore = appServer.sent.count
        app.connect()
        await eventually("the app to resume") { app.isConnected && appServer.authentications.count == 2 }
        await eventually("the app to settle") { app.state.value == .connected(isSyncing: false) }

        let resume = try #require(resumeRequest(appServer))
        #expect(resume.getAttribute("h") == String(ticket.stream.incoming))
        let ids = Set(queued.compactMap(\.id))
        let resent = appServer.sent.dropFirst(sentBefore).filter { $0.id.map(ids.contains) ?? false }.compactMap(\.id)
        #expect(resent == queued.suffix(lost).compactMap(\.id), "the stanzas the server never got, in order, and no others")
        if lost > 0 { #expect(!resent.isEmpty) }
        #expect(sm.unacknowledgedStanzas.map(\.id).contains { $0.map(ids.contains) ?? false } == (lost > 0) || lost == 0)
    }

    // MARK: Counters after the close

    /// Stanzas the stream handles while closing are in the counters a ticket saved after it holds, and Prosody
    /// fails a resume with counters behind what the server was told.
    @Test(.timeLimit(.minutes(1)))
    func theTicketHoldsWhatTheStreamHandledWhileClosing() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try session(.app, answering: .refuses, store: store)
        app.connect()
        await eventually("the stream") { app.state.value == .connected(isSyncing: false) }
        let before = try #require(app.client.module(.streamManagement).snapshot).incoming
        // Longer than the wait used to be, so a ticket saved before the close finished would miss the stanza.
        server.stopDelay = 2
        server.duringStop = [element("message", "jabber:client", ["from": "bob@localhost/x", "to": "alice@localhost", "type": "chat", "id": "late"], [Element(name: "body", cdata: "hi")])]

        await app.suspend()

        // What the session was sent while it finished syncing counts as well, so the ticket is compared
        // with the counters once the connection is gone, which nothing changes.
        let final = try #require(app.client.module(.streamManagement).snapshot).incoming
        #expect(final > before, "the stanza that came while closing wasn't counted")
        #expect(store.load()?.stream.incoming == final)
        app.disconnect()
    }

    /// With no time to wait the ticket is saved at once, whatever the close has not yet delivered.
    @Test(.timeLimit(.minutes(1)))
    func suspendingImmediatelySavesTheTicketWithoutWaitingForTheClose() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try session(.app, answering: .refuses, store: store)
        app.connect()
        await eventually("the stream") { app.state.value == .connected(isSyncing: false) }
        server.stopDelay = 2
        server.duringStop = [element("message", "jabber:client", ["from": "bob@localhost/x", "to": "alice@localhost", "type": "chat", "id": "late"], [Element(name: "body", cdata: "hi")])]

        app.suspendImmediately()

        let saved = try #require(store.load()).stream.incoming
        await eventually("the close to finish") { app.client.state == .disconnected() }
        let final = try #require(app.client.module(.streamManagement).snapshot).incoming
        #expect(saved < final, "the ticket waited for the close")
        app.disconnect()
    }

    // MARK: The app coming back

    /// Suspends an app session holding `appStream` in memory, then lets `extensionWrites` happen to the ticket.
    private func suspendedApp(
        store: ResumeTicketStore, callMedia: (any CallMediaFactory)? = nil, extensionWrites: () -> Void,
    ) async throws -> (XMPPSession, ServerScript) {
        let (app, server) = try session(.app, answering: .refuses, store: store, callMedia: callMedia)
        app.client.module(.streamManagement).seed(appStream)
        await app.suspend()
        #expect(store.load()?.stream == app.client.module(.streamManagement).snapshot, "suspend left no ticket of its stream")
        extensionWrites()
        return (app, server)
    }

    @Test(.timeLimit(.minutes(1)))
    func theAppResumesFromMemoryWhenNobodyUsedTheStream() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try await suspendedApp(store: store) {}
        defer { app.disconnect() }

        app.connect()
        await eventually("the sign-in") { !server.authentications.isEmpty }

        let resume = server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3")
        #expect(resume?.getAttribute("previd") == "app-stream")
        // The ticket is stale as soon as the app uses the stream, so it goes.
        #expect(store.load() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theAppStartsANewSessionWhenAnExtensionUsedTheStream() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try await suspendedApp(store: store) {
            var used = appStream
            used.incoming += 3
            store.save(used)
        }
        defer { app.disconnect() }

        app.connect()
        await eventually("the sign-in") { !server.authentications.isEmpty }

        #expect(server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3") == nil, "the app resumed with counters from before the extension")
        #expect(store.load() == nil)
    }

    /// The extension's resume failed, so it deleted the ticket: the stream is gone.
    @Test(.timeLimit(.minutes(1)))
    func theAppStartsANewSessionWhenTheTicketWasDeleted() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try await suspendedApp(store: store) { store.delete() }
        defer { app.disconnect() }

        app.connect()
        await eventually("the sign-in") { !server.authentications.isEmpty }

        #expect(server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3") == nil)
    }

    @Test func endingTheSessionDeletesTheTicketButTheShareExtensionsDoesNot() throws {
        let (store, directory) = ticketed(appStream)
        defer { try? FileManager.default.removeItem(at: directory) }
        let share = try XMPPSession(
            credentials: .init(jid: aliceJid, password: "x"), resource: "share", database: try AppDatabase.inMemory(), mode: .share,
            resumeTickets: store,
        )
        share.disconnect()
        #expect(store.load() != nil)

        let (app, _) = try session(.app, answering: .refuses, store: store)
        app.disconnect()
        #expect(store.load() == nil)
    }
}

struct ResumeTicketStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ticket-\(UUID().uuidString)")
    var store: ResumeTicketStore { ResumeTicketStore(directory: AccountDirectory(url: directory)) }

    @Test func aTicketRoundTripsAndItsGenerationOnlyRises() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(store.save(appStream))
        #expect(store.load() == ResumeTicket(generation: first, stream: appStream))
        let second = try #require(store.save(appStream))
        #expect(second > first)
        // A deleted ticket takes its counter with it, so the clock keeps the next from repeating one.
        store.delete()
        #expect(store.load() == nil)
        // Saves in the same millisecond stand on the counter, so a deletion has to be seen from a later one.
        Thread.sleep(forTimeInterval: 0.01)
        let third = try #require(store.save(appStream))
        #expect(third > second)
    }

    @Test func theTicketHasTheDatabasesProtectionAndIsLeftOutOfBackups() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(appStream)
        let url = AccountDirectory(url: directory).resumeTicketURL
        let protection = (try FileManager.default.attributesOfItem(atPath: url.path))[.protectionKey] as? FileProtectionType
        // A file system without protection (the Mac's, a simulator's) reports none.
        #expect(protection == nil || protection == FileProtection.level)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// An old ticket left behind by a write that failed would have counters the stream has moved past.
    @Test func aFailedWriteLeavesNoTicket() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        store.save(appStream)
        let ticket = AccountDirectory(url: directory).resumeTicketURL
        try FileManager.default.removeItem(at: ticket)
        try FileManager.default.createDirectory(at: ticket, withIntermediateDirectories: false)
        try Data([1]).write(to: ticket.appending(path: "block"))
        // A directory where the file goes makes the atomic replace fail.
        #expect(store.save(appStream) == nil)
        #expect(store.load() == nil)
    }
}
