import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// A connector that only records being stopped.
private final class StubConnector: Connector {
    static var supportedProtocols: [ConnectorProtocol] { [] }
    @Published var state: ConnectorState = .connected
    var statePublisher: Published<ConnectorState>.Publisher { $state }
    var streamEventsPublisher: AnyPublisher<StreamEvent, Never> { Empty().eraseToAnyPublisher() }
    var availableFeatures: Set<ConnectorFeature> = []
    var activeFeatures: Set<ConnectorFeature> = []
    var streamLogger: StreamLogger?
    var currentEndpoint: ConnectorEndpoint?
    var stops: [Bool] = []

    init(context: Context) {}
    func activate(feature: ConnectorFeature) {}
    func start(endpoint: ConnectorEndpoint?) {}
    func stop(force: Bool, completionHandler: @escaping () -> Void) {
        stops.append(force)
        completionHandler()
    }
    func restartStream() {}
    func send(_ data: StreamEvent, completion: WriteCompletion) {}
    func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? { nil }
    func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? { nil }
}

/// Answers every iq the way a server, or a dead link, would.
private final class ReplyWriter: PacketWriter {
    let reply: Result<Iq, XMPPError>
    init(_ reply: Result<Iq, XMPPError>) { self.reply = reply }

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {
        switch reply {
        case .success(let iq): completionHandler?(.success(iq))
        case .failure(let error): completionHandler?(.failure(error as! Failure))
        }
    }
    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

struct KeepaliveTests {
    private func keepalive(answering reply: Result<Iq, XMPPError>) -> [Bool] {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.writer = ReplyWriter(reply)
        _ = client.modulesManager.register(PingModule())
        let connector = StubConnector(context: client)
        let logic = SocketSessionLogic(connector: connector, responseManager: ResponseManager(), context: client, seeOtherHost: nil)
        logic.keepalive()
        return connector.stops
    }

    /// A half-open connection never answers, and never reports itself dead.
    @Test func unansweredPingDropsTheConnection() {
        #expect(keepalive(answering: .failure(.remote_server_timeout)) == [true])
    }

    /// An error reply still came from the server, so the link works.
    @Test func errorReplyKeepsTheConnection() {
        #expect(keepalive(answering: .failure(.service_unavailable())).isEmpty)
    }

    @Test func answeredPingKeepsTheConnection() {
        #expect(keepalive(answering: .success(Iq())).isEmpty)
    }
}
