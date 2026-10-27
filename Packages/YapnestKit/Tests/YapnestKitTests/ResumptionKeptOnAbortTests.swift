import Combine
import Foundation
import Martin
import Testing
@testable import Martin

private struct Location: ConnectorEndpoint {
    var proto: ConnectorProtocol { .XMPP }
}

/// A connector the test drives, which accepts any resumption location the server names.
private final class ScriptedConnector: Connector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [ObjectIdentifier: [ScriptedConnector]] = [:]
    static func connectors(of context: Context) -> [ScriptedConnector] {
        lock.withLock { made[ObjectIdentifier(context)] ?? [] }
    }

    static var supportedProtocols: [ConnectorProtocol] { [] }
    @Published var state: ConnectorState = .disconnected()
    var statePublisher: Published<ConnectorState>.Publisher { $state }
    var streamEventsPublisher: AnyPublisher<StreamEvent, Never> { Empty().eraseToAnyPublisher() }
    var availableFeatures: Set<ConnectorFeature> = []
    var activeFeatures: Set<ConnectorFeature> = []
    var streamLogger: StreamLogger?
    var currentEndpoint: ConnectorEndpoint?

    required init(context: Context) {
        Self.lock.withLock { Self.made[ObjectIdentifier(context), default: []].append(self) }
    }
    func activate(feature: ConnectorFeature) {}
    func start(endpoint: ConnectorEndpoint?) {}
    func stop(force: Bool, completionHandler: @escaping () -> Void) { completionHandler() }
    func restartStream() {}
    func send(_ data: StreamEvent, completion: WriteCompletion) {}
    func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? { location == nil ? nil : Location() }
    func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? { nil }
}

private struct ScriptedOptions: ConnectorOptions {
    var connector: Connector.Type { ScriptedConnector.self }
}

struct ResumptionKeptOnAbortTests {
    /// A client with a stream management session the server named a location for, and an attempt to sign in underway.
    private func connecting() async throws -> (XMPPClient, StreamManagementModule, ScriptedConnector) {
        let client = XMPPClient(eventBus: nil)
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.connectorOptions = ScriptedOptions()
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        _ = client.modulesManager.register(ResourceBinderModule())
        let sm = client.modulesManager.register(StreamManagementModule())

        client.login()
        let connector = try #require(ScriptedConnector.connectors(of: client).first)
        let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
        enabled.setAttribute("id", value: "session-1")
        enabled.setAttribute("resume", value: "true")
        enabled.setAttribute("location", value: "other.example:5222")
        sm.processEnabled(enabled)
        #expect(sm.resumptionEnabled && sm.resumptionLocation != nil)

        connector.state = .connecting
        await eventually("the attempt to be connecting") { client.state == .connecting }
        return (client, sm, connector)
    }

    /// The disconnect of an attempt we abort carries no reason. Martin compared only the case of the state,
    /// so it took every disconnect during a sign-in for an unreachable server, and a session the server
    /// would have resumed started again from nothing.
    @Test(.timeLimit(.minutes(1)))
    func anAttemptWeAbortKeepsTheSessionAndItsLocation() async throws {
        let (client, sm, connector) = try await connecting()
        connector.state = .disconnected()
        await eventually("the client to read disconnected") { client.state == .disconnected() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(sm.resumptionEnabled, "the abort threw the resumption id away")
        #expect(sm.resumptionLocation != nil, "the abort threw the location away")
    }

    /// A location that can't be reached must not be tried again and again, but the session can still be
    /// resumed at the normal host.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func anUnreachableLocationIsForgottenAndTheSessionKept(noRoute: Bool) async throws {
        let (client, sm, connector) = try await connecting()
        connector.state = .disconnected(noRoute ? .noRouteToServer : .timeout)
        await eventually("the client to read disconnected") { client.state == .disconnected() }
        await eventually("the location to be forgotten") { sm.resumptionLocation == nil }
        #expect(sm.resumptionEnabled, "the session can't be resumed any more")
    }
}
