import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// A connector the test feeds stanzas to, as if they came off the wire.
final class FeedConnector: Connector {
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

final class FeedWriter: PacketWriter {
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

/// Keeps the messages that reach the modules.
final class MessageRecorder: XmppModuleBase, XmppModule {
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
final class QueueBlocker: XmppModuleBase, XmppModule {
    static let ID = "test-queue-blocker"
    let criteria = Criteria.name("block")
    let features = [String]()
    let gate = DispatchSemaphore(value: 0)
    func process(stanza: Stanza) throws { gate.wait() }
}

func element(_ name: String, _ xmlns: String, _ attributes: [String: String] = [:], _ children: [Element] = []) -> Element {
    let e = Element(name: name, xmlns: xmlns)
    for (k, v) in attributes { e.setAttribute(k, value: v) }
    for c in children { e.addChild(c) }
    return e
}

/// Stream management a test starts from.
enum StreamSeed {
    /// From an earlier connection: three stanzas went out, and the server
    /// will say it handled the first.
    case previousSession
    case snapshot(StreamManagementModule.Snapshot)
    case none
}

/// A client signing in with SASL2, driven by stanzas the test hands it.
final class Sasl2Harness {
    let client = XMPPClient()
    let connector: FeedConnector
    let writer = FeedWriter()
    let logic: SocketSessionLogic
    let sm: StreamManagementModule
    let recorder = MessageRecorder()
    let blocker = QueueBlocker()
    /// Appended on the session logic's queue and read by the test, so under a lock.
    private let statesLock = NSLock()
    private var _states: [XMPPClient.State] = []
    var states: [XMPPClient.State] { statesLock.withLock { _states } }
    private var subscription: AnyCancellable?

    init(seeding seed: StreamSeed = .previousSession) throws {
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.credentials = .password(password: "secret")
        // The stub connector has no TLS for PLAIN to be sent over.
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

        switch seed {
        case .previousSession:
            sm.processEnabled(Stanza.from(element: element("enabled", "urn:xmpp:sm:3", ["id": "prev", "resume": "true"])))
            for id in ["A", "B", "C"] {
                let message = Message()
                message.id = id
                sm.processOutgoing(stanza: message)
            }
        case .snapshot(let snapshot):
            sm.seed(snapshot)
        case .none:
            break
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
        // As the stream delivers them, on the session logic's queue, which then signs in by itself.
        // Setting them and calling `login()` from here instead raced the logic's own reaction to
        // them: when it saw the sign-in already under way it set the session up at once, and sent a
        // `<resume>` before the server had answered.
        connector.events.send(.stanza(Stanza.from(element: featuresElement)))
        let deadline = Date().addingTimeInterval(defaultWait)
        while client.module(.auth).state != .inProgress, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }

    func receive(_ element: Element) {
        connector.events.send(.stanza(Stanza.from(element: element)))
    }

    func iqResult(_ id: String) -> Element {
        let iq = element("iq", "jabber:client", ["type": "result", "id": id])
        return iq
    }

    var connectedCount: Int {
        states.filter { if case .connected = $0 { true } else { false } }.count
    }
}

