import Combine
import Foundation
import Martin
import Network
import os
import Testing
@testable import Martin

/// Hands out a fixed list of records, and notes what the connector marks invalid.
private final class StubResolver: DNSSrvResolver, @unchecked Sendable {
    let records: [XMPPSrvRecord]
    private let lock = NSLock()
    private var _invalid: [Int] = []

    init(_ records: [XMPPSrvRecord]) { self.records = records }

    var invalidPorts: [Int] { lock.withLock { _invalid } }

    func resolve(domain: String, for jid: BareJID, completionHandler: @escaping (Result<XMPPSrvResult, DNSError>) -> Void) {
        completionHandler(.success(XMPPSrvResult(domain: domain, records: records)))
    }
    func markAsInvalid(for domain: String, record: XMPPSrvRecord, for: TimeInterval) {
        lock.withLock { _invalid.append(record.port) }
    }
    func markAsInvalid(for domain: String, host: String, port: Int, for: TimeInterval) {
        lock.withLock { _invalid.append(port) }
    }
}

/// A resolver that never calls back, like a DNS query that hangs.
private final class SilentResolver: DNSSrvResolver, @unchecked Sendable {
    func resolve(domain: String, for jid: BareJID, completionHandler: @escaping (Result<XMPPSrvResult, DNSError>) -> Void) {}
    func markAsInvalid(for domain: String, record: XMPPSrvRecord, for: TimeInterval) {}
    func markAsInvalid(for domain: String, host: String, port: Int, for: TimeInterval) {}
}

/// A server that answers the opening of a stream with features that don't offer STARTTLS.
private final class NoStartTLSServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yapnest.test.nostarttls")
    private let lock = NSLock()
    private var _accepted = 0
    private(set) var port: UInt16 = 0

    var accepted: Int { lock.withLock { _accepted } }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self, queue] connection in
            self?.lock.withLock { self?._accepted += 1 }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let reply = "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='localhost' version='1.0' id='x'><stream:features/>"
                connection.send(content: Data(reply.utf8), completion: .idempotent)
            }
        }
        port = try await startListening(listener, on: queue)
    }

    func stop() { listener.cancel() }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [ConnectorState] = []
    private var subscription: AnyCancellable?

    init(_ connector: SocketConnectorNetwork) {
        subscription = connector.statePublisher.sink { [weak self] state in
            guard let self else { return }
            lock.withLock { _states.append(state) }
        }
    }

    var states: [ConnectorState] { lock.withLock { _states } }
    var last: ConnectorState? { states.last }
    var disconnections: Int { states.filter { if case .disconnected = $0 { return true } else { return false } }.count }
}

struct ConnectorFallbackTests {
    private func connector(records: [XMPPSrvRecord], timeout: Double = 1, disableTLS: Bool = true, diagnostics: (@Sendable (SocketConnectorNetwork.ConnectEvent) -> Void)? = nil) -> (SocketConnectorNetwork, StubResolver, XMPPClient) {
        let resolver = StubResolver(records)
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.disableTLS = disableTLS
        var options = SocketConnectorNetwork.Options()
        options.connectionTimeout = timeout
        options.dnsResolver = resolver
        options.diagnostics = diagnostics
        client.connectionConfiguration.connectorOptions = options
        return (SocketConnectorNetwork(context: client), resolver, client)
    }

    private func record(_ port: UInt16, directTls: Bool = false, weight: Int = 10) -> XMPPSrvRecord {
        XMPPSrvRecord(port: Int(port), weight: weight, priority: 10, target: "127.0.0.1", directTls: directTls)
    }

    private func closedPort() async throws -> UInt16 {
        let server = try await LocalServer()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(150))
        return port
    }

    @Test func fallsBackAfterAServerThatNeverAnswersTheHandshake() async throws {
        let blackHole = try await LocalServer()
        let working = try await LocalServer()
        defer { blackHole.stop(); working.stop() }
        let (connector, resolver, client) = connector(records: [record(blackHole.port, directTls: true), record(working.port)])
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the second record to connect", timeout: 8) { log.last == .connected }
        #expect(blackHole.accepted == 1)
        #expect(working.accepted == 1)
        #expect(resolver.invalidPorts == [Int(blackHole.port)])
        #expect(log.disconnections == 1, "only the state before the attempt: \(log.states)")
        connector.stop(force: true) {}
    }

    @Test func fallsBackAfterARefusedPort() async throws {
        let closed = try await closedPort()
        let working = try await LocalServer()
        defer { working.stop() }
        let (connector, resolver, client) = connector(records: [record(closed), record(working.port)], timeout: 5)
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the second record to connect", timeout: 8) { log.last == .connected }
        #expect(resolver.invalidPorts == [Int(closed)])
        #expect(log.disconnections == 1, "states: \(log.states)")
        connector.stop(force: true) {}
    }

    @Test func reportsALookupThatNeverAnswers() async {
        let events = OSAllocatedUnfairLock(initialState: [SocketConnectorNetwork.ConnectEvent]())
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        var options = SocketConnectorNetwork.Options()
        options.connectionTimeout = 0.5
        options.dnsResolver = SilentResolver()
        options.diagnostics = { event in events.withLock { $0.append(event) } }
        client.connectionConfiguration.connectorOptions = options
        let connector = SocketConnectorNetwork(context: client)
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the attempt to end", timeout: 5) { log.disconnections == 2 }
        let seen = events.withLock { $0 }
        guard seen.count == 1, case .resolveTimedOut(let duration) = seen[0] else {
            Issue.record("events: \(seen)")
            return
        }
        #expect(duration >= 0.4)
    }

    @Test func reportsEachStepOfAFallbackAsEvents() async throws {
        let closed = try await closedPort()
        let working = try await LocalServer()
        defer { working.stop() }
        let events = OSAllocatedUnfairLock(initialState: [SocketConnectorNetwork.ConnectEvent]())
        let (connector, _, client) = connector(records: [record(closed), record(working.port)], timeout: 5) { event in
            events.withLock { $0.append(event) }
        }
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the second record to connect", timeout: 8) { log.last == .connected }
        let seen = events.withLock { $0 }
        guard seen.count == 5 else {
            Issue.record("events: \(seen)")
            return
        }
        guard case .resolved(let records, let fallback, _) = seen[0], records == 2, !fallback else {
            Issue.record("first: \(seen[0])")
            return
        }
        guard case .attempting(.srvStartTLS, let firstPort) = seen[1], firstPort == Int(closed) else {
            Issue.record("second: \(seen[1])")
            return
        }
        guard case .failed(.srvStartTLS, _, .network, .posix?, let code, _, true) = seen[2], code != 0 else {
            Issue.record("third: \(seen[2])")
            return
        }
        guard case .attempting(_, let nextPort) = seen[3], nextPort == Int(working.port) else {
            Issue.record("fourth: \(seen[3])")
            return
        }
        guard case .ready(_, _, .ipv4, _) = seen[4] else {
            Issue.record("fifth: \(seen[4])")
            return
        }
        // Nothing in an event names a host or an address.
        #expect(!seen.map { "\($0)" }.joined().contains("127.0.0.1"))
        connector.stop(force: true) {}
    }

    @Test func triesTheNextRecordAfterEachFailureInOrder() async throws {
        let first = try await LocalServer()
        let second = try await LocalServer()
        let third = try await LocalServer()
        defer { first.stop(); second.stop(); third.stop() }
        let (connector, resolver, client) = connector(records: [record(first.port, directTls: true), record(second.port, directTls: true), record(third.port)], timeout: 0.5)
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the third record to connect", timeout: 8) { log.last == .connected }
        #expect(resolver.invalidPorts == [Int(first.port), Int(second.port)])
        connector.stop(force: true) {}
    }

    @Test func exhaustingEveryRecordEndsOnceWithATimeout() async throws {
        let one = try await LocalServer()
        let two = try await LocalServer()
        defer { one.stop(); two.stop() }
        let (connector, resolver, client) = connector(records: [record(one.port, directTls: true), record(two.port, directTls: true)], timeout: 0.5, disableTLS: false)
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the attempt to end", timeout: 8) { log.disconnections == 2 }
        try await Task.sleep(for: .milliseconds(1200))
        guard case .disconnected(.timeout) = log.last else {
            Issue.record("ended with \(String(describing: log.last))")
            return
        }
        #expect(log.disconnections == 2, "the initial state and one end: \(log.states)")
        #expect(Set(resolver.invalidPorts) == [Int(one.port), Int(two.port)])
        #expect(one.accepted == 1 && two.accepted == 1)
    }

    @Test func aServerWithoutStartTLSEndsTheAttemptWithoutFallingBack() async throws {
        let plain = try await NoStartTLSServer()
        let other = try await LocalServer()
        defer { plain.stop(); other.stop() }
        let (connector, resolver, client) = connector(records: [record(plain.port), record(other.port)], timeout: 5, disableTLS: false)
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: nil)
        await eventually("the attempt to end", timeout: 8) { log.disconnections == 2 }
        guard case .disconnected(.xmlError(let message)) = log.last else {
            Issue.record("ended with \(String(describing: log.last))")
            return
        }
        #expect(message == SocketConnectorNetwork.startTLSNotOffered)
        #expect(other.accepted == 0)
        #expect(resolver.invalidPorts.isEmpty)
    }

    @Test func anExplicitEndpointIsTheOnlyCandidate() async throws {
        let closed = try await closedPort()
        let working = try await LocalServer()
        defer { working.stop() }
        let (connector, _, client) = connector(records: [record(working.port)], timeout: 5)
        let log = StateLog(connector)

        defer { withExtendedLifetime(client) {} }
        connector.start(endpoint: SocketConnectorNetwork.Endpoint(proto: .XMPP, host: "127.0.0.1", port: Int(closed)))
        await eventually("the attempt to end", timeout: 8) { log.disconnections == 2 }
        #expect(working.accepted == 0)
        guard case .disconnected(.noRouteToServer) = log.last else {
            Issue.record("ended with \(String(describing: log.last))")
            return
        }
    }
}

struct SrvResolverMemoryTests {
    private func result() -> XMPPSrvResult {
        XMPPSrvResult(domain: "example.org", records: [
            XMPPSrvRecord(port: 5223, weight: 10, priority: 10, target: "xmpp.example.org", directTls: true),
            XMPPSrvRecord(port: 5222, weight: 10, priority: 10, target: "xmpp.example.org", directTls: false),
        ])
    }

    @Test func aFailedEndpointSortsAfterTheValidOneInLaterResults() {
        let resolver = XMPPDNSSrvResolver(directTlsEnabled: true)
        resolver.markAsInvalid(for: "example.org", host: "xmpp.example.org", port: 5223, for: 900)

        let later = result()
        resolver.applyInvalid(to: later, domain: "example.org")
        #expect(later.record()?.port == 5222)
        #expect(later.candidates().map(\.port) == [5222, 5223])
        #expect(later.hasValid)
    }

    @Test func theRecordOverloadAndOtherDomainsBehave() {
        let resolver = XMPPDNSSrvResolver(directTlsEnabled: true)
        resolver.markAsInvalid(for: "example.org", record: result().records[0], for: 900)

        let same = result()
        resolver.applyInvalid(to: same, domain: "example.org")
        #expect(same.candidates().map(\.port) == [5222, 5223])

        let other = result()
        resolver.applyInvalid(to: other, domain: "example.net")
        #expect(other.candidates().map(\.port) == [5223, 5222])
    }

    @Test func anExpiredEntryIsForgotten() async throws {
        let resolver = XMPPDNSSrvResolver(directTlsEnabled: true)
        resolver.markAsInvalid(for: "example.org", host: "xmpp.example.org", port: 5223, for: 0.05)
        try await Task.sleep(for: .milliseconds(120))

        let later = result()
        resolver.applyInvalid(to: later, domain: "example.org")
        #expect(later.candidates().map(\.port) == [5223, 5222])
    }
}

/// A TCP listener that accepts and never says anything.
private final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yapnest.test.silent")
    private let lock = NSLock()
    private var _accepted = 0
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var accepted: Int { lock.withLock { _accepted } }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self, queue] connection in
            guard let self else { return }
            lock.withLock { _accepted += 1; held.append(connection) }
            connection.start(queue: queue)
        }
        port = try await startListening(listener, on: queue)
    }

    func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() }; held = [] }
    }
}
