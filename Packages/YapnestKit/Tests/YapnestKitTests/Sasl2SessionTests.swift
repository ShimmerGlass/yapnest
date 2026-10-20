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
    }
}

/// Keeps the messages that reach the modules.
private final class MessageRecorder: XmppModuleBase, XmppModule {
    static let ID = "test-message-recorder"
    let criteria = Criteria.name("message")
    let features = [String]()
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func process(stanza: Stanza) throws { lock.withLock { _ids.append(stanza.id ?? "") } }
}

/// Holds the session logic's queue while a test sends it a read's worth of
/// stanzas: a module's `process` runs on that queue.
private final class QueueBlocker: XmppModuleBase, XmppModule {
    static let ID = "test-queue-blocker"
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

/// A client signing in with SASL2, driven by stanzas the test hands it.
private final class Harness {
    let client = XMPPClient()
    let connector: FeedConnector
    let writer = RecordingWriter()
    let logic: SocketSessionLogic
    let sm: StreamManagementModule
    let recorder = MessageRecorder()
    let blocker = QueueBlocker()
    var states: [XMPPClient.State] = []
    private var subscription: AnyCancellable?

    init() throws {
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.credentials = .password(password: "secret")
        // The stub connector has no TLS for PLAIN to be sent over.
        client.connectionConfiguration.disableTLS = true
        client.writer = writer
        let features = client.modulesManager.register(StreamFeaturesModule())
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
        subscription = logic.$state.sink { [weak self] in self?.states.append($0) }

        // Stream management from an earlier connection: three stanzas
        // went out, and the server will say it handled the first.
        sm.processEnabled(Stanza.from(element: element("enabled", "urn:xmpp:sm:3", ["id": "prev", "resume": "true"])))
        for id in ["A", "B", "C"] {
            let message = Message()
            message.id = id
            sm.processOutgoing(stanza: message)
        }

        let authentication = element("authentication", "urn:xmpp:sasl:2", [:], [
            Element(name: "mechanism", cdata: "PLAIN"),
            element("inline", "urn:xmpp:sasl:2", [:], [
                element("sm", "urn:xmpp:sm:3"),
                element("bind", "urn:xmpp:bind:0"),
            ]),
        ])
        let featuresElement = Element(name: "features", xmlns: "http://etherx.jabber.org/streams")
        featuresElement.addChild(authentication)
        features.setStreamFeatures(featuresElement)
        client.module(.auth).login()
    }

    func receive(_ element: Element) {
        connector.events.send(.stanza(Stanza.from(element: element)))
    }

    func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func iqResult(_ id: String) -> Element {
        let iq = element("iq", "jabber:client", ["type": "result", "id": id])
        return iq
    }

    var connectedCount: Int {
        states.filter { if case .connected = $0 { true } else { false } }.count
    }
}

struct Sasl2SessionTests {
    /// After an inline resumption the server sends no stream features, so
    /// waiting for them left the client "connecting" until the watchdog
    /// gave up. Its `<r/>` and the resent results came right after
    /// `<success>`, ahead of the session logic noticing it.
    @Test func resumptionConnectsWithoutFeatures() async throws {
        let h = try Harness()
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("resumed", "urn:xmpp:sm:3", ["h": "1", "previd": "prev"]),
        ]))
        for id in ["r1", "r2", "r3"] { h.receive(h.iqResult(id)) }
        h.receive(element("r", "urn:xmpp:sm:3"))

        await h.waitUntil("connected") {
            // State's == ignores whether it resumed.
            h.states.contains { if case .connected(let resumed) = $0 { resumed } else { false } }
        }
        #expect(h.connectedCount == 1)
        #expect(h.sm.ackEnabled)

        // What the server hadn't handled went out again, once.
        await h.waitUntil("the resend") { h.writer.written.filter { $0.name == "message" }.count == 2 }
        #expect(h.writer.written.filter { $0.name == "message" }.compactMap { $0.getAttribute("id") } == ["B", "C"])

        // The three results were counted, and the request was answered.
        await h.waitUntil("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "3")
    }

    /// Features that do follow a resumption mustn't set the session up
    /// again.
    @Test func featuresAfterResumptionAreIgnored() async throws {
        let h = try Harness()
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            element("resumed", "urn:xmpp:sm:3", ["h": "1", "previd": "prev"]),
        ]))
        await h.waitUntil("connected") { h.connectedCount == 1 }
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.connectedCount == 1)
        #expect(h.writer.written.filter { $0.name == "message" }.count == 2)
    }

    /// A new session is bound from `<success>`, and the features that
    /// follow it carry on from there once.
    @Test func bindingConnectsOnceWithFeatures() async throws {
        let h = try Harness()
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "new", "resume": "true"]),
            ]),
        ]))
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        await h.waitUntil("connected") { h.connectedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.states.contains(.connected(resumed: false)))
        #expect(h.connectedCount == 1)
        #expect(h.client.context.boundJid == JID("alice@localhost/phone"))
    }

    /// A server sends the features right after `<success>`, and what comes
    /// next can arrive in the same read. Bind 2's `<enabled>` must be
    /// applied before those stanzas are handled, or they go uncounted and
    /// the `<r/>` is answered with a count that's short.
    /// The four events are sent back to back, as the connector does for one
    /// read, through the session logic's own queue hops. The XML parsing and
    /// the socket are not exercised.
    @Test func bindingIsAppliedBeforeStanzasInTheSameRead() async throws {
        let h = try Harness()
        // A new connection: the earlier one's counting has stopped.
        h.sm.reset(scopes: [.stream])
        #expect(!h.sm.ackEnabled)
        // All four are queued before the first is handled, as in one read.
        h.receive(element("block", "test"))
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "x", "resume": "true"]),
            ]),
        ]))
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        let message = element("message", "jabber:client", ["id": "m1", "from": "bob@localhost/x", "type": "chat"], [
            Element(name: "body", cdata: "hi"),
        ])
        h.receive(message)
        h.receive(element("r", "urn:xmpp:sm:3"))
        h.blocker.gate.signal()

        await h.waitUntil("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "1")
        #expect(h.recorder.ids == ["m1"])
        await h.waitUntil("connected") { h.connectedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.connectedCount == 1)
        #expect(h.client.context.boundJid == JID("alice@localhost/phone"))
    }

    /// The usual outcome of a refused resumption: the server binds a new
    /// session instead. Clearing the old one must not undo what the new
    /// one's `<success>` brought, nor the stanzas counted before the session
    /// logic notices it.
    @Test func refusedResumptionKeepsTheNewBindingFromTheSameRead() async throws {
        let h = try Harness()
        h.sm.reset(scopes: [.stream])
        h.receive(element("block", "test"))
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("failed", "urn:xmpp:sm:3"),
            element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "y", "resume": "true"]),
            ]),
        ]))
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        h.receive(element("message", "jabber:client", ["id": "m1", "from": "bob@localhost/x", "type": "chat"], [
            Element(name: "body", cdata: "hi"),
        ]))
        h.receive(element("r", "urn:xmpp:sm:3"))
        h.blocker.gate.signal()

        await h.waitUntil("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "1")
        #expect(h.recorder.ids == ["m1"])
        await h.waitUntil("connected") { h.connectedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.connectedCount == 1)
        #expect(h.sm.ackEnabled)
        #expect(h.sm.resumptionEnabled)
        #expect(h.client.context.boundJid == JID("alice@localhost/phone"))
    }
}
