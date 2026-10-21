import Combine
import Foundation
import Network
import Synchronization
import Testing
@testable import YapnestKit

/// A TCP proxy to the dev server whose link can be made to go silent without
/// closing, which is what a half-open connection looks like to the client.
/// It can also act at a precise point in the traffic: cut or hold the link
/// when a given piece of XML goes by, so a test can drop the connection right
/// before the server answers a particular request.
final class FreezableProxy: Sendable {
    enum Direction: Sendable { case toServer, toClient }

    private enum Action: Sendable { case cut, hold }

    private struct Trigger: Sendable {
        let direction: Direction
        let pattern: String
        let action: Action
    }

    private struct Held: @unchecked Sendable {
        let destination: NWConnection
        let data: Data
    }

    private struct Traffic: Sendable {
        var triggers: [Trigger] = []
        /// The end of what passed, per direction, so a pattern split across two reads is still found.
        var windows: [Direction: String] = [:]
        var toServer = ""
        var toClient = ""
        /// What the server had sent when the last cut went off.
        var toClientAtCut = ""
        var fired = 0
        var holding = false
        var held: [Held] = []
    }

    private let listener: NWListener
    private let frozen = Mutex(false)
    private let refusing = Mutex(false)
    private let connections = Mutex<[NWConnection]>([])
    private let traffic = Mutex(Traffic())
    private let queue = DispatchQueue(label: "proxy")

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var isFrozen: Bool {
        get { frozen.withLock { $0 } }
        set { frozen.withLock { $0 = newValue } }
    }

    /// While set, new connections are dropped at once.
    var isRefusing: Bool {
        get { refusing.withLock { $0 } }
        set { refusing.withLock { $0 = newValue } }
    }

    /// Closes every open connection, as a network drop would.
    func cut() {
        connections.withLock { $0.forEach { $0.cancel() }; $0 = [] }
    }

    /// The next time `pattern` goes by in `direction`, the read containing it
    /// is dropped and every connection is closed, once.
    func cutWhen(_ direction: Direction, sees pattern: String) {
        traffic.withLock { $0.triggers.append(Trigger(direction: direction, pattern: pattern, action: .cut)) }
    }

    /// The next time `pattern` goes by in `direction`, what the server sends
    /// from then on is kept back until `release()`, once. With `.toServer`, the read containing
    /// the pattern still goes through; with `.toClient` it is held too.
    func holdServerWhen(_ direction: Direction, sees pattern: String) {
        traffic.withLock { $0.triggers.append(Trigger(direction: direction, pattern: pattern, action: .hold)) }
    }

    /// How many triggers have gone off.
    var firedTriggers: Int { traffic.withLock { $0.fired } }

    /// Whether the server's traffic is being held back.
    var isHolding: Bool { traffic.withLock { $0.holding } }

    /// Passes on what `holdServerWhen` kept back, and everything after it.
    func release() {
        let held = traffic.withLock { traffic -> [Held] in
            traffic.holding = false
            defer { traffic.held = [] }
            return traffic.held
        }
        for chunk in held { chunk.destination.send(content: chunk.data, completion: .contentProcessed { _ in }) }
    }

    /// Everything the client has sent so far, for failure messages.
    var clientTraffic: String { traffic.withLock { $0.toServer } }

    /// Everything the server has sent so far, for failure messages.
    var serverTraffic: String { traffic.withLock { $0.toClient } }

    /// What the server had sent up to the last cut.
    var serverTrafficAtCut: String { traffic.withLock { $0.toClientAtCut } }

    /// How often `pattern` appears in what the client has sent so far.
    func clientSent(_ pattern: String) -> Int {
        traffic.withLock { $0.toServer.components(separatedBy: pattern).count - 1 }
    }

    init(to upstreamPort: UInt16) async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] client in
            if isRefusing { client.cancel(); return }
            let server = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
            connections.withLock { $0 += [client, server] }
            pump(from: client, to: server, .toServer)
            pump(from: server, to: client, .toClient)
            client.start(queue: queue)
            server.start(queue: queue)
        }
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state, !resumed.withLock({ defer { $0 = true }; return $0 }) { continuation.resume() }
            }
            listener.start(queue: queue)
        }
    }

    private enum Verdict { case forward, hold, swallow }

    /// Looks at a read for the triggers, and decides what happens to it.
    private func inspect(_ data: Data, _ direction: Direction, to: NWConnection) -> Verdict {
        let text = String(decoding: data, as: UTF8.self)
        let (verdict, cuts): (Verdict, Bool) = traffic.withLock { traffic in
            if direction == .toServer { traffic.toServer += text } else { traffic.toClient += text }
            // Servers differ in which quote they write attributes with; the patterns use single ones.
            let window = (traffic.windows[direction] ?? "") + text.replacingOccurrences(of: "\"", with: "'")
            traffic.windows[direction] = String(window.suffix(512))
            var verdict = Verdict.forward
            var cuts = false
            if let index = traffic.triggers.firstIndex(where: { $0.direction == direction && window.contains($0.pattern) }) {
                let trigger = traffic.triggers.remove(at: index)
                traffic.fired += 1
                traffic.windows[direction] = ""
                switch trigger.action {
                case .cut:
                    (verdict, cuts) = (.swallow, true)
                    // What the client got: the read that fired the cut was
                    // swallowed whole, so anything else in it (Openfire sends
                    // `<enabled` along with the discovery answer) never arrived.
                    traffic.toClientAtCut = direction == .toClient ? String(traffic.toClient.dropLast(text.count)) : traffic.toClient
                case .hold: traffic.holding = true
                }
            }
            if direction == .toClient, traffic.holding, verdict == .forward {
                traffic.held.append(Held(destination: to, data: data))
                verdict = .hold
            }
            return (verdict, cuts)
        }
        if cuts { cut() }
        return verdict
    }

    private func pump(from: NWConnection, to: NWConnection, _ direction: Direction) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data, !isFrozen, inspect(data, direction, to: to) == .forward {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if error == nil, !done { pump(from: from, to: to, direction) }
        }
    }

    func stop() {
        listener.cancel()
        connections.withLock { $0.forEach { $0.cancel() } }
    }
}

extension LiveServer {
    /// What the client does when its connection dies without telling it.
    /// `YAPNEST_INTEGRATION=1 swift test --filter DeadConnection`
    @Suite
    struct DeadConnectionIntegrationTests {
        let alice = LiveServer.jid("alice")

        private func connected(_ proxy: FreezableProxy) async throws -> XMPPSession {
            let session = try LiveServer.makeSession(alice, resource: "dead-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: proxy.port)
            session.connect()
            try await wait(session, for: .connected(isSyncing: false), within: 60)
            return session
        }

        private func wait(_ session: XMPPSession, for state: XMPPSession.State, within seconds: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while session.state.value != state {
                if Date() > deadline { throw Timeout(state: session.state.value) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        struct Timeout: Error { let state: XMPPSession.State }

        /// Returning to the foreground on a dead link reconnects.
        @Test func foregroundReconnectsADeadLink() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try await connected(proxy)
            defer { session.disconnect() }

            let dropped = Mutex(false)
            let watch = session.state.sink { state in
                if case .disconnected = state { dropped.withLock { $0 = true } }
            }
            defer { watch.cancel() }

            proxy.isFrozen = true
            session.setActive(false)
            session.setActive(true)
            try await Task.sleep(for: .seconds(1))
            proxy.isFrozen = false
            // The check must find the link dead, and the reconnect must succeed on its own.
            try await Task.sleep(for: .seconds(8))
            try await wait(session, for: .connected(isSyncing: false), within: 60)
            #expect(dropped.withLock { $0 }, "the dead connection should have been dropped")
        }

        /// A silent link is dropped, rather than staying "connected".
        @Test func silentLinkIsDropped() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try await connected(proxy)
            defer { session.disconnect() }

            proxy.isFrozen = true
            session.setActive(true)
            try await wait(session, for: .disconnected(error: "The connection was lost."), within: 10)
        }

        /// A healthy link isn't mistaken for a dead one.
        @Test func healthyLinkIsKept() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try await connected(proxy)
            defer { session.disconnect() }

            session.setActive(true)
            try await Task.sleep(for: .seconds(8))
            #expect(session.state.value == .connected(isSyncing: false))
        }

        /// An attempt stuck on a dead path is replaced as soon as the network
        /// changes, rather than at the 30 second watchdog.
        @Test func pathChangeRestartsAStuckAttempt() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            proxy.isFrozen = true
            let session = try LiveServer.makeSession(alice, resource: "stuck-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: proxy.port)
            defer { session.disconnect() }
            session.connect()
            try await wait(session, for: .connecting, within: 5)
            try await Task.sleep(for: .seconds(2))
            #expect(session.state.value == .connecting)

            // The new path works.
            proxy.isFrozen = false
            session.pathBecameSatisfied()
            // The first sync isn't part of the reconnect, so any connected state will do.
            let deadline = Date().addingTimeInterval(10)
            while !session.isConnected {
                if Date() > deadline { throw Timeout(state: session.state.value) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
