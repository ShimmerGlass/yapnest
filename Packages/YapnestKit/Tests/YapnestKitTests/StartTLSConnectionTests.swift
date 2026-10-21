import Foundation
import Network
import os
import Testing
@testable import Martin
@testable import YapnestKit

/// The connector's STARTTLS handling against a server that doesn't do it
/// properly. A server that does is the live suites' (`TLSIntegrationTests`);
/// what only a broken one shows is here, and needs no TLS on the
/// server's side: in each case but the last the client must stop before the handshake.
@Suite(.serialized)
struct StartTLSConnectionTests {
    private static let header = "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0' from='localhost' id='x1'>"
    private static let starttls = "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>"
    private static let plain = "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>"
    private static let proceed = "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
    private static let failure = "<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"

    /// What a client with TLS required says before it hears a proceed.
    private static let hello = String(decoding: StartTLSPreamble.streamHeader(to: "localhost"), as: UTF8.self)
    private static let request = String(decoding: StartTLSPreamble.request, as: UTF8.self)

    /// Says `first` to the stream header and, if there is more, `second` to
    /// the request for STARTTLS. Keeps what each connection sent.
    private final class FakeServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "yapnest.test.fake-xmpp")
        private let received = OSAllocatedUnfairLock(initialState: [String]())
        private let first: String
        private let second: String?
        private(set) var port: UInt16 = 0

        init(first: String, second: String? = nil) async throws {
            self.first = first
            self.second = second
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            port = try await startListening(listener, on: queue)
        }

        func stop() { listener.cancel() }

        /// What the first connection sent, in all.
        var firstConnectionReceived: String { received.withLock { $0.first ?? "" } }

        private func accept(_ connection: NWConnection) {
            let index = received.withLock { received -> Int in
                received.append("")
                return received.count - 1
            }
            connection.start(queue: queue)
            read(connection, index: index, answered: 0)
        }

        private func read(_ connection: NWConnection, index: Int, answered: Int) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var answered = answered
                if let data {
                    let text = received.withLock { received -> String in
                        received[index] += String(decoding: data, as: UTF8.self)
                        return received[index]
                    }
                    if answered == 0, text.contains("<stream:stream") {
                        answered = 1
                        connection.send(content: Data((StartTLSConnectionTests.header + first).utf8), completion: .idempotent)
                    }
                    if answered == 1, text.contains("<starttls"), let second {
                        answered = 2
                        connection.send(content: Data(second.utf8), completion: .idempotent)
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, index: index, answered: answered)
                }
            }
        }
    }

    /// The state the session settles on after the server has said its piece.
    private func outcome(of server: FakeServer) async throws -> XMPPSession.State {
        let session = try XMPPSession(
            credentials: .init(jid: JID("test@localhost")!, password: "hunter2-canary", host: "127.0.0.1", port: Int(server.port)),
            resource: "starttls-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(),
        )
        session.connect()
        defer { session.disconnect() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            switch session.state.value {
            case .connecting, .disconnected(error: nil): try await Task.sleep(for: .milliseconds(20))
            case let state: return state
            }
        }
        Issue.record("The session never settled")
        return session.state.value
    }

    @Test func aServerWithoutStartTLSIsRefusedWithoutSigningIn() async throws {
        let server = try await FakeServer(first: Self.plain)
        defer { server.stop() }
        let state = try await outcome(of: server)
        // Fatal, as retrying won't make the server offer it.
        #expect(state == .failed("The server doesn't support encryption."))
        // Only the stream header went out: no password, no fallback to plaintext.
        #expect(server.firstConnectionReceived == Self.hello)
    }

    @Test func aRefusedStartTLSIsAnErrorNotAFallback() async throws {
        let server = try await FakeServer(first: Self.starttls, second: Self.failure)
        defer { server.stop() }
        let state = try await outcome(of: server)
        #expect(state == .disconnected(error: "The server sent something unexpected."))
        #expect(server.firstConnectionReceived == Self.hello + Self.request)
    }

    @Test func dataAfterProceedEndsTheConnectionBeforeTLS() async throws {
        let server = try await FakeServer(first: Self.starttls, second: Self.proceed + Self.plain)
        defer { server.stop() }
        let state = try await outcome(of: server)
        #expect(state == .disconnected(error: "The server sent something unexpected."))
        // No handshake bytes: the client never started TLS.
        #expect(server.firstConnectionReceived == Self.hello + Self.request)
    }

    @Test func aStreamErrorBeforeTheFeaturesEndsTheConnection() async throws {
        let server = try await FakeServer(first: "<stream:error><host-unknown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error></stream:stream>")
        defer { server.stop() }
        let state = try await outcome(of: server)
        #expect(state == .disconnected(error: "The server sent something unexpected."))
        #expect(server.firstConnectionReceived == Self.hello)
    }

    @Test func tlsStartsAfterAProceed() async throws {
        // After a clean proceed the client starts the handshake on the same
        // connection. The server doesn't speak TLS, so it goes nowhere; what
        // matters is that the client's first bytes after the request are TLS's.
        let server = try await FakeServer(first: Self.starttls, second: Self.proceed)
        defer { server.stop() }
        let session = try XMPPSession(
            credentials: .init(jid: JID("test@localhost")!, password: "hunter2-canary", host: "127.0.0.1", port: Int(server.port)),
            resource: "starttls-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(),
        )
        session.connect()
        defer { session.disconnect() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, server.firstConnectionReceived.count <= (Self.hello + Self.request).count {
            try await Task.sleep(for: .milliseconds(20))
        }
        let extra = server.firstConnectionReceived.dropFirst((Self.hello + Self.request).count)
        #expect(!extra.isEmpty, "TLS didn't start after a proceed")
        #expect(!server.firstConnectionReceived.contains("hunter2"))
    }
}
