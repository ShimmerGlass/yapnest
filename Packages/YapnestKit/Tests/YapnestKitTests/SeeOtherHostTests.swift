import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// A connector that records where it was told to connect, and finds its way
/// to the test through its context.
private final class RecordingConnector: Connector {
    private static let registry = ConnectorRegistry<RecordingConnector>()
    static func connectors(of context: Context) -> [RecordingConnector] { registry.connectors(of: context) }

    static var supportedProtocols: [ConnectorProtocol] { [] }
    @Published var state: ConnectorState = .disconnected()
    var statePublisher: Published<ConnectorState>.Publisher { $state }
    var streamEventsPublisher: AnyPublisher<StreamEvent, Never> { Empty().eraseToAnyPublisher() }
    var availableFeatures: Set<ConnectorFeature> = [.TLS]
    var activeFeatures: Set<ConnectorFeature> = []
    var streamLogger: StreamLogger?
    var currentEndpoint: ConnectorEndpoint?
    private let startsLock = NSLock()
    private var _starts: [String?] = []
    var starts: [String?] { startsLock.withLock { _starts } }

    required init(context: Context) {
        Self.registry.add(self, of: context)
    }
    func activate(feature: ConnectorFeature) {}
    func start(endpoint: ConnectorEndpoint?) {
        startsLock.withLock { _starts.append((endpoint as? SocketConnectorNetwork.Endpoint)?.host) }
    }
    func stop(force: Bool, completionHandler: @escaping () -> Void) { completionHandler() }
    func restartStream() {}
    func send(_ data: StreamEvent, completion: WriteCompletion) {}
    func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? { nil }
    func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? {
        SocketConnector.preprocessConnectionDetails(string: seeOtherHost).map {
            SocketConnectorNetwork.Endpoint(proto: .XMPP, host: $0.0, port: $0.1 ?? 5222)
        }
    }
}

private struct RecordingOptions: ConnectorOptions {
    var connector: Connector.Type { RecordingConnector.self }
}

/// A server's `see-other-host` redirect (RFC 6120 §4.9.3.19).
struct SeeOtherHostTests {
    /// A port outside the range used to trap where the endpoint is made, on
    /// every launch, as each one met the same redirect.
    @Test(arguments: ["example.org:70000", "example.org:-1", "example.org:0", "example.org:abc", "example.org:"])
    func anAddressWhosePortIsntOneIsIgnored(address: String) {
        #expect(SocketConnector.preprocessConnectionDetails(string: address) == nil)
    }

    @Test func anAddressWithOrWithoutAPortIsRead() throws {
        let withPort = try #require(SocketConnector.preprocessConnectionDetails(string: "example.org:5223"))
        #expect(withPort.0 == "example.org" && withPort.1 == 5223)
        let without = try #require(SocketConnector.preprocessConnectionDetails(string: "example.org"))
        #expect(without.0 == "example.org" && without.1 == nil)
        #expect(SocketConnector.preprocessConnectionDetails(string: "example.org:65535")?.1 == 65535)
    }

    private func redirect(to address: String) -> ConnectorState {
        let error = Element(name: "error", xmlns: "http://etherx.jabber.org/streams")
        error.addChild(Element(name: "see-other-host", cdata: address, xmlns: "urn:ietf:params:xml:ns:xmpp-streams"))
        return .disconnected(.streamError(error))
    }

    private func connectedClient(disableTLS: Bool = false) async throws -> (XMPPClient, RecordingConnector) {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@example.org")
        client.connectionConfiguration.disableTLS = disableTLS
        client.connectionConfiguration.connectorOptions = RecordingOptions()
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        client.login()
        // The newest: a client of an earlier test may have had the same address.
        let connector = try #require(RecordingConnector.connectors(of: client).last)
        connector.state = .connecting
        await eventually("the client to be connecting") { client.state == .connecting }
        return (client, connector)
    }

    /// Before STARTTLS anyone on the network path can write one.
    @Test func aRedirectBeforeTLSIsNotFollowed() async throws {
        let (client, connector) = try await connectedClient()
        connector.state = redirect(to: "evil.example:5222")
        await eventually("the stream to end") { client.state == .disconnected() }
        #expect(!connector.starts.contains("evil.example"))
    }

    @Test func aRedirectOverTLSIsFollowed() async throws {
        let (client, connector) = try await connectedClient()
        connector.activeFeatures = [.TLS]
        connector.state = redirect(to: "other.example.org:5223")
        await eventually("the redirect to be followed") { connector.starts.contains("other.example.org") }
        withExtendedLifetime(client) {}
    }

    @Test func anAccountWithoutTLSFollowsItsServersRedirect() async throws {
        let (client, connector) = try await connectedClient(disableTLS: true)
        connector.state = redirect(to: "other.example.org:5223")
        await eventually("the redirect to be followed") { connector.starts.contains("other.example.org") }
        withExtendedLifetime(client) {}
    }
}
