import Combine
import Foundation
import GRDB
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
        for element in script.duringStop { events.send(.stanza(Stanza.from(element: element))) }
        state = .disconnected()
        completionHandler()
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


    // MARK: Calls that arrive while an extension holds the stream

    private static let caller = "bob@localhost/phone"

    private func proposal(sid: String, from: String = caller) -> Element {
        element("message", "jabber:client", ["from": from, "to": "alice@localhost", "type": "chat", "id": "p-\(sid)"], [
            element("propose", "urn:xmpp:jingle-message:0", ["id": sid], [element("description", "urn:xmpp:jingle:apps:rtp:1", ["media": "audio"])]),
        ])
    }

    private func retraction(sid: String) -> Element {
        element("message", "jabber:client", ["from": Self.caller, "to": "alice@localhost", "type": "chat", "id": "r-\(sid)"], [
            element("retract", "urn:xmpp:jingle-message:0", ["id": sid]),
        ])
    }

    /// The app suspended with `appStream`, then an extension woke and found `replayed` waiting in the stream.
    /// Returns the app, ready to come back, with a contact who may call it.
    private func appAfterAnExtensionRead(
        _ replayed: [Element], store: ResumeTicketStore,
    ) async throws -> (XMPPSession, ServerScript) {
        let (app, appServer) = try suspendedApp(store: store, callMedia: FakeCallMediaFactory()) {}
        try await app.database.writer.write { try Contact(jid: JID("bob@localhost")!, subscription: .both, isInRoster: true).insert($0) }
        let (woken, extensionServer) = try session(.notificationService, answering: .accepts(h: 5), store: store)
        extensionServer.afterSignIn = replayed
        #expect(await woken.catchUpOnce(timeout: 20))
        #expect(extensionServer.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3") != nil)
        return (app, appServer)
    }

    private func freshStore() -> (ResumeTicketStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ticket-\(UUID().uuidString)")
        return (ResumeTicketStore(directory: AccountDirectory(url: directory)), directory)
    }

    /// iOS rings only for a live `propose`, which the extension consumed from the app's stream: the app's
    /// new session reads it back from the archive, which never rings.
    @Test(.timeLimit(.minutes(1)))
    func aCallTheExtensionConsumedRingsWhenTheAppReturns() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try await appAfterAnExtensionRead([proposal(sid: "call-1")], store: store)
        defer { app.disconnect() }
        #expect(store.handovers().map(\.sid) == ["call-1"])

        app.connect()

        await eventually("the call to ring") { app.callState.value?.phase == .incoming }
        #expect(server.authentications.first?.findChild(name: "resume", xmlns: "urn:xmpp:sm:3") == nil, "the app resumed a stream an extension used")
        #expect(store.handovers().isEmpty, "the handover was left for another return to ring for again")
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallThatEndedWhileTheExtensionHeldTheStreamDoesNotRing() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, _) = try await appAfterAnExtensionRead([proposal(sid: "call-2"), retraction(sid: "call-2")], store: store)
        defer { app.disconnect() }
        #expect(store.handovers().isEmpty)

        app.connect()
        try await Task.sleep(for: .seconds(1))

        #expect(app.callState.value == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStaleHandoverDoesNotRing() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, _) = try suspendedApp(store: store, callMedia: FakeCallMediaFactory()) {}
        defer { app.disconnect() }
        try await app.database.writer.write { try Contact(jid: JID("bob@localhost")!, subscription: .both, isInRoster: true).insert($0) }
        store.addHandover(
            CallHandover(sid: "old", sender: "bob@localhost", recipient: "alice@localhost", from: Self.caller, media: ["audio"], timestamp: Date().addingTimeInterval(-120)),
            ringWindow: .infinity,
        )

        app.connect()
        try await Task.sleep(for: .seconds(1))

        #expect(app.callState.value == nil)
        #expect(store.handovers().isEmpty)
    }

    /// Our own other device ringing us isn't a call to answer here.
    @Test(.timeLimit(.minutes(1)))
    func aProposeFromTheAccountsOwnDeviceIsNotHandedOver() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await appAfterAnExtensionRead([proposal(sid: "mine", from: "alice@localhost/tablet")], store: store)
        #expect(store.handovers().isEmpty)
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
        await eventually("the stream") { app.isConnected && app.client.module(.streamManagement).snapshot != nil }
        let before = try #require(app.client.module(.streamManagement).snapshot).incoming
        server.duringStop = [element("message", "jabber:client", ["from": "bob@localhost/x", "to": "alice@localhost", "type": "chat", "id": "late"], [Element(name: "body", cdata: "hi")])]

        app.suspend()

        #expect(store.load()?.stream.incoming == before + 1)
        app.disconnect()
    }

    // MARK: The app coming back

    /// Suspends an app session holding `appStream` in memory, then lets `extensionWrites` happen to the ticket.
    private func suspendedApp(
        store: ResumeTicketStore, callMedia: (any CallMediaFactory)? = nil, extensionWrites: () -> Void,
    ) throws -> (XMPPSession, ServerScript) {
        let (app, server) = try session(.app, answering: .refuses, store: store, callMedia: callMedia)
        app.client.module(.streamManagement).seed(appStream)
        app.suspend()
        #expect(store.load()?.stream == app.client.module(.streamManagement).snapshot, "suspend left no ticket of its stream")
        extensionWrites()
        return (app, server)
    }

    @Test(.timeLimit(.minutes(1)))
    func theAppResumesFromMemoryWhenNobodyUsedTheStream() async throws {
        let (store, directory) = freshStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, server) = try suspendedApp(store: store) {}
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
        let (app, server) = try suspendedApp(store: store) {
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
        let (app, server) = try suspendedApp(store: store) { store.delete() }
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
