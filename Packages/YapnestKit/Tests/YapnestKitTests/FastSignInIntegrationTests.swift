import Foundation
import Martin
import Network
import Security
import Testing
@testable import YapnestKit

extension LiveServer {
    /// The dev servers' CA (`dev/certs/make.sh` writes it), which the
    /// sessions here trust in place of the system's roots. `YAPNEST_DEV_CA`
    /// names another file.
    static func devCA() throws -> SecCertificate {
        let env = ProcessInfo.processInfo.environment["YAPNEST_DEV_CA"]
        // Five levels up from this file is the repository.
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = env.map { URL(fileURLWithPath: $0) } ?? repository.appending(path: "dev/certs/ca.pem")
        guard let pem = try? String(contentsOf: url, encoding: .utf8) else {
            try Test.cancel("No dev CA at \(url.path); run dev/certs/make.sh and restart the dev server")
        }
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return certificate
    }

    /// A session over STARTTLS, which trusts the dev CA unless `trustingDevCA`
    /// is off. TLS is on for the sessions the other suites open with it off.
    static func makeTLSSession(
        _ jid: YapnestKit.JID, resource: String, password: String = "password", fastTokens: FastTokenStore = MemoryFastTokenStore(), trustingDevCA: Bool = true,
    ) throws -> XMPPSession {
        let session = try XMPPSession(
            credentials: .init(jid: jid, password: password, host: "127.0.0.1", port: target.port, disableTLS: false),
            resource: resource, database: try AppDatabase.inMemory(), fastTokens: fastTokens,
        )
        if trustingDevCA { session.trustOnly([try devCA()]) }
        return session
    }

    /// Cancels the test unless the server offers SASL2 once the stream is
    /// encrypted. ejabberd and Openfire don't offer it before, so this
    /// signs in once over TLS and looks at whether SASL2 did it: a client uses it
    /// whenever the server offers it. Asked by every test, answered once.
    static func requireSASL2() async throws {
        if try await sasl2Probe.offersSASL2() { return }
        try Test.cancel("\(target.name) doesn't offer SASL2 (urn:xmpp:sasl:2) over TLS")
    }

    private static let sasl2Probe = SASL2Probe()

    private actor SASL2Probe {
        private var answer: Task<Bool, Error>?

        func offersSASL2() async throws -> Bool {
            if answer == nil {
                answer = Task {
                    let session = try LiveServer.makeTLSSession(LiveServer.jid("alice"), resource: "probe-\(UUID().uuidString.prefix(6))")
                    session.connect()
                    defer { session.disconnect() }
                    // Openfire, emulated, takes a while.
                    let deadline = Date().addingTimeInterval(60)
                    while Date() < deadline {
                        switch session.state.value {
                        case .connected: return session.client.module(.sasl2).state == .authorized
                        case .failed(let reason): throw ProbeFailure(reason: reason)
                        default: try await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    throw ProbeFailure(reason: "no sign-in within 60 s")
                }
            }
            return try await answer!.value
        }
    }

    struct ProbeFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { "Signing in over TLS failed: \(reason)" }
    }
}

extension LiveServer {
    /// SASL2 (XEP-0388), Bind 2 (XEP-0386) and FAST (XEP-0484), over TLS
    /// with the dev CA's certificate. Prosody and Snikket offer SASL2
    /// without it too; the others only once the stream is encrypted, and a
    /// server without it at all cancels the tests.
    @Suite
    struct FastSignInIntegrationTests {
        let alice = LiveServer.jid("alice")

        private func session(resource: String, tokens: FastTokenStore, password: String = "password") async throws -> XMPPSession {
            try await LiveServer.requireSASL2()
            return try LiveServer.makeTLSSession(alice, resource: resource, password: password, fastTokens: tokens)
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        @Test func passwordOnceThenToken() async throws {
            let tokens = MemoryFastTokenStore()
            let resource = "fast-\(UUID().uuidString.prefix(6))"
            let first = try await session(resource: resource, tokens: tokens)
            first.connect()
            try await waitUntil("the first sign-in") { first.state.value == .connected(isSyncing: false) }
            #expect(first.client.module(.sasl2).signedInWithToken == false)
            // Bound while signing in: the server picked the resource from our tag.
            #expect(first.client.context.boundJid?.resource?.hasPrefix("Yapnest") == true)
            let token = try #require(tokens.load())
            #expect(token.mechanism == "HT-SHA-256-NONE")
            first.disconnect()

            let second = try await session(resource: resource, tokens: tokens)
            second.connect()
            defer { second.disconnect() }
            try await waitUntil("signing in with the token") { second.state.value == .connected(isSyncing: false) }
            #expect(second.client.module(.sasl2).signedInWithToken)
        }

        @Test func refusedTokenFallsBackToThePassword() async throws {
            let tokens = MemoryFastTokenStore()
            tokens.save(.init(mechanism: "HT-SHA-256-NONE", token: "not-a-real-token", expiry: .distantFuture))
            let s = try await session(resource: "fast-\(UUID().uuidString.prefix(6))", tokens: tokens)
            s.connect()
            defer { s.disconnect() }
            try await waitUntil("signing in with the password") { s.state.value == .connected(isSyncing: false) }
            #expect(s.client.module(.sasl2).signedInWithToken == false)
            // And it got a token that works.
            #expect(tokens.load()?.token != "not-a-real-token")
            #expect(tokens.load() != nil)
        }

        @Test func wrongPasswordStillSaysSo() async throws {
            let s = try await session(resource: "fast-\(UUID().uuidString.prefix(6))", tokens: MemoryFastTokenStore(), password: "wrong")
            s.connect()
            defer { s.disconnect() }
            try await waitUntil("the refusal") { if case .failed = s.state.value { true } else { false } }
            #expect(s.state.value == .failed("Wrong address or password."))
        }

        @Test func resumesInline() async throws {
            let s = try await session(resource: "fast-\(UUID().uuidString.prefix(6))", tokens: MemoryFastTokenStore())
            s.connect()
            defer { s.disconnect() }
            try await waitUntil("connecting") { s.state.value == .connected(isSyncing: false) }
            try await waitUntil("stream management") { s.client.module(.streamManagement).resumptionEnabled }
            let bound = s.client.context.boundJid

            s.suspend()
            try await waitUntil("the connection to drop") { if case .disconnected = s.client.state { true } else { false } }
            s.connect()
            // Prosody sends features after resuming and ejabberd doesn't, so
            // this passed even when a client waited for them. The unit tests
            // in Sasl2SessionTests cover the version without. Quickly, too:
            // a stalled resumption otherwise sits until the watchdog.
            try await waitUntil("resuming", timeout: 5) {
                // State's == ignores whether it resumed.
                if case .connected(let resumed) = s.client.state { resumed } else { false }
            }
            #expect(s.client.context.boundJid == bound)
            #expect(s.client.module(.sasl2).signedInWithToken)
        }
    }
}

extension LiveServer {
    /// Signing in over STARTTLS, which every dev server offers with the dev
    /// CA's certificate, whichever sign-in the server speaks. The other
    /// suites run on plaintext.
    @Suite
    struct TLSIntegrationTests {
        let alice = LiveServer.jid("alice")

        private func waitUntil(_ what: String, timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        @Test func passwordSignInIsEncrypted() async throws {
            let s = try LiveServer.makeTLSSession(alice, resource: "tls-\(UUID().uuidString.prefix(6))")
            s.connect()
            defer { s.disconnect() }
            try await waitUntil("signing in") { s.state.value == .connected(isSyncing: false) }
            #expect(s.client.connector?.activeFeatures.contains(.TLS) == true)
            let connector = try #require(s.client.connector as? SocketConnectorNetwork)
            let version = try #require(connector.negotiatedTLSVersion)
            print("TLSVERSION \(LiveServer.target.name) \(String(version.rawValue, radix: 16))")
            // Every dev server offers 1.3, and Snikket's default profile offers nothing else.
            #expect(version == .TLSv13)
        }

        @Test func aCertificateFromAnUnknownCAIsRefused() async throws {
            _ = try LiveServer.devCA()
            let s = try LiveServer.makeTLSSession(alice, resource: "tls-\(UUID().uuidString.prefix(6))", trustingDevCA: false)
            s.connect()
            defer { s.disconnect() }
            try await waitUntil("the refusal") {
                switch s.state.value {
                case .connected, .failed: true
                default: false
                }
            }
            if case .connected = s.state.value { Issue.record("Signed in to a server whose certificate no trusted CA signed") }
            #expect(s.state.value == .failed("The server's certificate isn't trusted."))
        }
    }
}
