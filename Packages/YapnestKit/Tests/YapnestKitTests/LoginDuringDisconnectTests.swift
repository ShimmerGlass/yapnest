import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// A connector that is driven by the test, and finds its way to it through its context.
private final class DrivenConnector: Connector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [ObjectIdentifier: [DrivenConnector]] = [:]
    static func connectors(of context: Context) -> [DrivenConnector] {
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
    func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? { nil }
    func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? { nil }
}

private struct DrivenOptions: ConnectorOptions {
    var connector: Connector.Type { DrivenConnector.self }
}

/// Runs something when the stream state is reset, which is the middle of the clean-up after a drop.
private final class ProbeClient: XMPPClient {
    var onReset: (() -> Void)?
    var resets = 0
    init() { super.init(eventBus: nil) }
    override func reset(scopes: Set<ResetableScope>) {
        resets += 1
        onReset?()
        super.reset(scopes: scopes)
    }
}

struct LoginDuringDisconnectTests {
    /// A login from another thread, made the moment `state` says disconnected, used to land between that
    /// and the clean-up, which then threw the new session logic away and reset the stream it needed.
    @Test func loginAsTheConnectionDropsSurvivesTheCleanUp() async throws {
        let client = ProbeClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.connectorOptions = DrivenOptions()
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        _ = client.modulesManager.register(ResourceBinderModule())
        _ = client.modulesManager.register(StreamManagementModule())

        var states: [XMPPClient.State] = []
        let stateLock = NSLock()
        let subscription = client.$state.sink { state in stateLock.withLock { states.append(state) } }
        defer { subscription.cancel() }

        client.login()
        let first = try #require(DrivenConnector.connectors(of: client).first)
        first.state = .connecting
        await eventually("the first attempt to be connecting") { client.state == .connecting }

        let loggedIn = DispatchSemaphore(value: 0)
        let thread = Thread {
            // As the app's reconnect does, once the state allows it.
            let deadline = Date().addingTimeInterval(5)
            while client.state != .disconnected(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            client.login()
            loggedIn.signal()
        }
        // Holds the clean-up open long enough for that login to be made inside it, if it can be.
        client.onReset = { _ = loggedIn.wait(timeout: .now() + 0.3) }
        thread.start()
        first.state = .disconnected()

        await eventually("the second attempt to start") { DrivenConnector.connectors(of: client).count == 2 }
        await eventually("the clean-up to finish") { client.resets == 1 }
        try await Task.sleep(for: .milliseconds(300))

        let second = try #require(DrivenConnector.connectors(of: client).last)
        #expect(client.connector === second, "the clean-up threw away the new session logic")
        second.state = .connecting
        await eventually("the second attempt to be connecting") { client.state == .connecting }
        #expect(client.resets == 1, "the new attempt's stream state was reset")
        let seen = stateLock.withLock { states }
        #expect(seen.filter { $0 == .disconnected() }.count == 2, "states: \(seen)")
        #expect(seen == [.disconnected(), .connecting, .disconnected(), .connecting], "states: \(seen)")
    }

    /// A request the drop left unanswered is failed by the clean-up. It used to be failed before the state
    /// changed, so the session, which asks the client whether it's connected, took a catch-up query cut
    /// off by the drop for an answer on a live stream, and reported the sync finished
    /// (`SessionResilienceIntegrationTests.aDropDuringCatchUpNeverReadsConnectedAndSyncsAfterTheResume`).
    @Test func aRequestTheDropLeftUnansweredFailsOnceTheClientReadsDisconnected() async throws {
        let client = ProbeClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.connectorOptions = DrivenOptions()
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        _ = client.modulesManager.register(ResourceBinderModule())
        _ = client.modulesManager.register(StreamManagementModule())

        client.login()
        let connector = try #require(DrivenConnector.connectors(of: client).first)
        connector.state = .connecting
        await eventually("the attempt to be connecting") { client.state == .connecting }

        let seen = NSLock()
        nonisolated(unsafe) var stateWhenFailed: XMPPClient.State?
        let iq = Iq()
        iq.type = .get
        iq.to = JID("localhost")
        client.context.writer.write(iq, timeout: 30) { _ in
            seen.withLock { stateWhenFailed = client.state }
        }
        // The request is sent, and so waits for an answer, rather than refused.
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.withLock { stateWhenFailed } == nil)

        connector.state = .disconnected()
        await eventually("the request to fail") { seen.withLock { stateWhenFailed } != nil }
        #expect(seen.withLock { stateWhenFailed } == .disconnected())
    }
}
