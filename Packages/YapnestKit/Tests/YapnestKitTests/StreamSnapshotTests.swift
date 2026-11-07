import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// A connector the test feeds stanzas to, as if they came off the wire.
private final class FeedConnector: Connector {
    static var supportedProtocols: [ConnectorProtocol] { [] }
    @Published var state: ConnectorState = .connected
    var statePublisher: Published<ConnectorState>.Publisher { $state }
    let events = PassthroughSubject<StreamEvent, Never>()
    var streamEventsPublisher: AnyPublisher<StreamEvent, Never> { events.eraseToAnyPublisher() }
    var availableFeatures: Set<ConnectorFeature> = []
    var activeFeatures: Set<ConnectorFeature> = [.TLS]
    var streamLogger: StreamLogger?
    var currentEndpoint: ConnectorEndpoint?

    init(context: Context) {}
    func activate(feature: ConnectorFeature) {}
    func start(endpoint: ConnectorEndpoint?) {}
    func stop(force: Bool, completionHandler: @escaping () -> Void) { completionHandler() }
    func restartStream() {}
    func send(_ data: StreamEvent, completion: WriteCompletion) {}
    func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? { nil }
    func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? { nil }
}

private final class RecordingWriter: PacketWriter {
    var module: StreamManagementModule?
    private let lock = NSLock()
    private var _written: [Stanza] = []
    var written: [Stanza] { lock.withLock { _written } }

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {
        module?.processOutgoing(stanza: stanza)
        lock.withLock { _written.append(stanza) }
        writeCompleted?(.success(()))
    }
}

/// Keeps the messages that reach the modules, and holds the session logic's queue on request.
private final class MessageRecorder: XmppModuleBase, XmppModule {
    static let ID = "test-snapshot-recorder"
    let criteria = Criteria.name("message")
    let features = [String]()
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func process(stanza: Stanza) throws { lock.withLock { _ids.append(stanza.id ?? "") } }
}

private final class QueueBlocker: XmppModuleBase, XmppModule {
    static let ID = "test-snapshot-blocker"
    let criteria = Criteria.name("block")
    let features = [String]()
    let gate = DispatchSemaphore(value: 0)
    func process(stanza: Stanza) throws { gate.wait() }
}

private func element(_ name: String, _ xmlns: String, _ attributes: [String: String] = [:], _ children: [Element] = []) -> Element {
    let e = Element(name: name, xmlns: xmlns)
    for (k, v) in attributes { e.setAttribute(k, value: v) }
    for c in children { e.addChild(c) }
    return e
}

private func chatMessage(_ id: String) -> Element {
    element("message", "jabber:client", ["id": id, "from": "bob@localhost/x", "type": "chat"], [Element(name: "body", cdata: "hi")])
}

private let earlier = StreamManagementModule.Snapshot(
    id: "app-stream", location: "other.example:5222", timeout: 600, incoming: 7, outgoing: 5, boundJid: "alice@localhost/yapnest-app", resumedH: 4,
)

/// A client that has not logged in, over SASL2, with a stream seeded from `earlier`.
private final class Harness {
    let client = XMPPClient()
    let connector: FeedConnector
    let writer = RecordingWriter()
    let logic: SocketSessionLogic
    let sm: StreamManagementModule
    let recorder = MessageRecorder()
    let blocker = QueueBlocker()
    private let statesLock = NSLock()
    private var _states: [XMPPClient.State] = []
    var states: [XMPPClient.State] { statesLock.withLock { _states } }
    private var subscription: AnyCancellable?

    init(seeding snapshot: StreamManagementModule.Snapshot?) throws {
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.credentials = .password(password: "secret")
        client.connectionConfiguration.disableTLS = true
        client.writer = writer
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        _ = client.modulesManager.register(Sasl2Module())
        _ = client.modulesManager.register(ResourceBinderModule())
        sm = client.modulesManager.register(StreamManagementModule())
        writer.module = sm
        _ = client.modulesManager.register(recorder)
        _ = client.modulesManager.register(blocker)
        connector = FeedConnector(context: client)
        logic = SocketSessionLogic(connector: connector, responseManager: ResponseManager(), context: client, seeOtherHost: nil)
        logic.bind()
        subscription = logic.$state.sink { [weak self] state in self?.statesLock.withLock { self?._states.append(state) } }
        if let snapshot { sm.seed(snapshot) }

        let authentication = element("authentication", "urn:xmpp:sasl:2", [:], [
            Element(name: "mechanism", cdata: "PLAIN"),
            element("inline", "urn:xmpp:sasl:2", [:], [element("sm", "urn:xmpp:sm:3"), element("bind", "urn:xmpp:bind:0")]),
        ])
        let featuresElement = Element(name: "features", xmlns: "http://etherx.jabber.org/streams")
        featuresElement.addChild(authentication)
        connector.events.send(.stanza(Stanza.from(element: featuresElement)))
        let deadline = Date().addingTimeInterval(defaultWait)
        while client.module(.auth).state != .inProgress, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }

    func receive(_ element: Element) {
        connector.events.send(.stanza(Stanza.from(element: element)))
    }
}

/// A module holds its client weakly, so a helper that returns only the module would lose it.
private final class Clients: @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var all: [XMPPClient] = []
    static func keep(_ client: XMPPClient) { lock.withLock { all.append(client) } }
}

struct StreamSnapshotTests {
    private func module(bound: String? = nil) -> StreamManagementModule {
        let client = XMPPClient(eventBus: nil)
        Clients.keep(client)
        _ = client.modulesManager.register(StreamFeaturesModule())
        let binder = client.modulesManager.register(ResourceBinderModule())
        if let bound { binder.bindedJid = JID(bound) }
        let module = client.modulesManager.register(StreamManagementModule())
        module.context = client
        return module
    }

    /// What resuming needs survives being written down and read back, in a client that has never been
    /// connected.
    @Test func aSnapshotSeedsAnotherClientToTheSameState() throws {
        let source = module(bound: "alice@localhost/yapnest-app")
        let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
        enabled.setAttribute("id", value: "app-stream")
        enabled.setAttribute("resume", value: "true")
        enabled.setAttribute("location", value: "other.example:5222")
        enabled.setAttribute("max", value: "600")
        source.processEnabled(enabled)
        for _ in 0..<3 { _ = source.processIncoming(stanza: Stanza.from(element: chatMessage("m"))) }
        for id in ["A", "B"] {
            let message = Message()
            message.id = id
            source.processOutgoing(stanza: message)
        }
        let snapshot = try #require(source.snapshot)
        #expect(snapshot == StreamManagementModule.Snapshot(
            id: "app-stream", location: "other.example:5222", timeout: 600, incoming: 3, outgoing: 2, boundJid: "alice@localhost/yapnest-app", resumedH: nil,
        ))

        let decoded = try JSONDecoder().decode(StreamManagementModule.Snapshot.self, from: JSONEncoder().encode(snapshot))
        let target = module()
        #expect(target.snapshot == nil)
        target.seed(decoded)
        #expect(target.snapshot == snapshot)
        #expect(target.resumptionEnabled)
        #expect(target.resumptionTime == 600)
        #expect(target.context?.boundJid == JID("alice@localhost/yapnest-app"))
    }

    @Test func aStreamThatCannotBeResumedHasNoSnapshot() {
        let plain = module()
        plain.processEnabled(Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3"))
        #expect(plain.snapshot == nil)
    }

    /// A snapshot is the stream's, so a graceful close that ends it takes it away, and a forced one doesn't.
    @Test func resetEndsTheSnapshot() {
        let seeded = module()
        seeded.seed(earlier)
        #expect(seeded.snapshot != nil)
        seeded.reset()
        #expect(seeded.snapshot == nil)
    }

    /// How many of our stanzas the server had handled, as it said when it resumed the stream: what a
    /// process that takes the stream over after this one needs to tell its own count from the server's.
    @Test func theServersCountFromResumedIsKeptUntilANewStream() {
        let seeded = module()
        seeded.seed(StreamManagementModule.Snapshot(id: "s", incoming: 1, outgoing: 5))
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "4")
        seeded.processResumed(resumed)
        #expect(seeded.snapshot?.resumedH == 4)
        seeded.reset()
        seeded.processEnabled({
            let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
            enabled.setAttribute("id", value: "new")
            enabled.setAttribute("resume", value: "true")
            return enabled
        }())
        #expect(seeded.snapshot?.resumedH == nil)
    }

    /// The SASL1 way: `<resume>` goes out with the seeded id and incoming count, and the JID is known
    /// without a bind.
    @Test func aSeededClientSendsResumeAndKnowsItsJid() {
        let client = XMPPClient(eventBus: nil)
        let writer = RecordingWriter()
        client.writer = writer
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(ResourceBinderModule())
        let sm = client.modulesManager.register(StreamManagementModule())
        sm.context = client
        writer.module = sm
        sm.seed(earlier)
        #expect(client.context.boundJid == JID("alice@localhost/yapnest-app"))

        sm.resume { _ in }
        let resume = writer.written.first { $0.name == "resume" }
        #expect(resume?.getAttribute("previd") == "app-stream")
        #expect(resume?.getAttribute("h") == "7")
    }

    /// What the server replays right after `<resumed>` is counted, whichever way the stream was resumed:
    /// the `<resumed>` makes the module count, and each stanza after it is seen in order.
    @Test func stanzasReplayedAfterResumedAreCounted() {
        let sm = module()
        sm.seed(earlier)
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "5")
        #expect(sm.processIncoming(stanza: resumed))
        #expect(!sm.processIncoming(stanza: Stanza.from(element: chatMessage("r1"))))
        #expect(!sm.processIncoming(stanza: Stanza.from(element: chatMessage("r2"))))
        #expect(sm.snapshot?.incoming == 9)
    }

    /// Over SASL2 the seeded id and count ride in the `<authenticate>`, and the replayed stanzas that
    /// arrive with `<success>` in the same read are counted and answered.
    @Test func aSeededClientResumesOverSasl2AndCountsTheReplay() async throws {
        let h = try Harness(seeding: earlier)
        let authenticate = try #require(h.writer.written.first { $0.name == "authenticate" })
        let resume = try #require(authenticate.findChild(name: "resume", xmlns: "urn:xmpp:sm:3"))
        #expect(resume.getAttribute("previd") == "app-stream")
        #expect(resume.getAttribute("h") == "7")

        h.receive(element("block", "test"))
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/yapnest-app"),
            element("resumed", "urn:xmpp:sm:3", ["h": "5", "previd": "app-stream"]),
        ]))
        h.receive(chatMessage("r1"))
        h.receive(chatMessage("r2"))
        h.receive(element("r", "urn:xmpp:sm:3"))
        h.blocker.gate.signal()

        await eventually("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "9")
        #expect(h.recorder.ids == ["r1", "r2"])
        await eventually("connected") { h.states.contains { if case .connected(let resumed) = $0 { resumed } else { false } } }
        #expect(h.client.context.boundJid == JID("alice@localhost/yapnest-app"))
        #expect(h.sm.snapshot?.resumedH == 5)
    }

    /// The final acknowledgement is written before `acknowledge()` returns, once, and not again when the
    /// server has been told everything.
    @Test func acknowledgeWritesTheCountOnce() async {
        let client = XMPPClient(eventBus: nil)
        let writer = RecordingWriter()
        client.writer = writer
        _ = client.modulesManager.register(StreamFeaturesModule())
        let sm = client.modulesManager.register(StreamManagementModule())
        sm.context = client
        writer.module = sm
        sm.processEnabled(Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3"))
        _ = sm.processIncoming(stanza: Stanza.from(element: chatMessage("m1")))
        await sm.acknowledge()
        #expect(writer.written.filter { $0.name == "a" }.map { $0.getAttribute("h") } == ["1"])
        await sm.acknowledge()
        #expect(writer.written.filter { $0.name == "a" }.count == 1)
    }
}
