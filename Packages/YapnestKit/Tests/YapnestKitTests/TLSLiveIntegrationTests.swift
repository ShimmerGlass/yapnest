import Foundation
import GRDB
import Martin
import Network
import Security
import Synchronization
import Testing
@testable import YapnestKit

extension LiveServer {
    /// What the live suites don't exercise because they run without TLS: a
    /// whole session over STARTTLS (sign-in, OMEMO, a resumed stream), the
    /// certificate checks that a CA the client trusts doesn't excuse, and the
    /// sign-in mechanism the client picks.
    /// `YAPNEST_INTEGRATION=1 swift test --filter TLSLiveIntegration`
    @Suite
    struct TLSLiveIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func stored(_ body: String, in session: XMPPSession) throws -> YapnestKit.Message? {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("body") == body).fetchOne($0) }
        }

        private func isSent(_ body: String, in session: XMPPSession) throws -> Bool {
            try stored(body, in: session)?.status ?? .pending >= .sent
        }

        // MARK: A whole session over TLS

        /// Signs in over STARTTLS with the dev CA's certificate, exchanges an
        /// OMEMO message, loses the connection and resumes the stream, all on
        /// TLS. The relay in between can't read the encrypted stream, so the
        /// drop is a closed TCP connection, as `FreezableProxy.cut()` makes it,
        /// which is what a network drop looks like to TLS as well; the
        /// plaintext suites cut at precise points in the XML, which this can't.
        @Test func aSessionOverTLSSendsOMEMOAndResumes() async throws {
            let ca = try LiveServer.devCA()
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try XMPPSession(
                credentials: .init(jid: alice, password: "password", host: "127.0.0.1", port: proxy.port, disableTLS: false),
                resource: "tls-alice-\(UUID().uuidString.prefix(6))", database: try LiveServer.keptDevice("tls-alice"),
            )
            a.trustOnly([ca])
            let b = try LiveServer.makeSession(bob, resource: "tls-bob-\(UUID().uuidString.prefix(6))", database: try LiveServer.keptDevice("tls-bob"))
            let resumed = Mutex(0)
            // Martin's State compares equal whatever `resumed` says, so match the payload.
            let watch = a.client.$state.sink { state in
                if case .connected(let wasResumed) = state, wasResumed { resumed.withLock { $0 += 1 } }
            }
            defer { watch.cancel() }

            try await LiveServer.connected(b, a, encryptionReady: true, timeout: 60)
            defer { a.disconnect(); b.disconnect() }
            // Until each has heard the other announce its device, they don't encrypt for each other.
            // Without a cached list, sending fetches a fresh one.
            for (session, other) in [(a, b), (b, a)] {
                try await LiveServer.waitUntil("\(session.account) to hear of \(other.account)'s device", timeout: 60) {
                    let known = session.announcedDevices(of: other.account)
                    return known.isEmpty || known.contains(Int32(bitPattern: other.omemoDeviceId))
                }
            }
            try #require(a.client.connector?.activeFeatures.contains(.TLS) == true, "the session isn't encrypted")
            try await LiveServer.waitUntil("stream management", timeout: 60) { a.client.module(.streamManagement).resumptionEnabled }

            let first = "tls first \(UUID().uuidString.prefix(6))"
            let sent = try a.send(first, to: bob)
            #expect(sent.encryption == .omemo)
            try await LiveServer.waitUntil("bob to decrypt the first message", timeout: 60) { try stored(first, in: b)?.encryption == .omemo }
            try await LiveServer.waitUntil("the first message to be sent", timeout: 60) { try isSent(first, in: a) }

            // A message written while the link is down goes out, encrypted, when the stream is resumed.
            proxy.isRefusing = true
            proxy.cut()
            try await LiveServer.waitUntil("the drop", timeout: 60) { !a.isConnected }
            let second = "tls second \(UUID().uuidString.prefix(6))"
            try a.send(second, to: bob)
            proxy.isRefusing = false
            try await LiveServer.waitUntil("the stream to resume", timeout: 60) { resumed.withLock { $0 } >= 1 && a.state.value == .connected(isSyncing: false) }
            try await LiveServer.waitUntil("bob to decrypt the second message", timeout: 60) { try stored(second, in: b)?.encryption == .omemo }
            try await LiveServer.waitUntil("the second message to be sent", timeout: 60) { try isSent(second, in: a) }

            #expect(resumed.withLock { $0 } == 1, "the stream should have been resumed once")
            #expect(a.client.connector?.activeFeatures.contains(.TLS) == true, "the resumed stream isn't encrypted")
            let connector = try #require(a.client.connector as? SocketConnectorNetwork)
            #expect(connector.negotiatedTLSVersion == .TLSv13)
            #expect(try stored(first, in: a)?.encryption == .omemo)
        }

        // MARK: The sign-in mechanism

        /// The client signs in with SCRAM when the server offers it, even on a
        /// connection where PLAIN would be allowed (no TLS), and without a
        /// FAST token to use instead. Read off the wire through the relay;
        /// nothing in YapnestKit had to be exposed for it.
        @Test func signsInWithSCRAMWhenOffered() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try LiveServer.makeSession(alice, resource: "scram-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: proxy.port)
            session.connect()
            defer { session.disconnect() }
            try await LiveServer.waitUntil("the sign-in", timeout: 60) { session.state.value == .connected(isSyncing: false) }

            // Servers differ in which quote they write attributes with.
            let sent = proxy.clientTraffic.replacingOccurrences(of: "\"", with: "'")
            let offered = proxy.serverTraffic.replacingOccurrences(of: "\"", with: "'")
            guard offered.contains(">SCRAM-SHA-") else { try Test.cancel("\(LiveServer.target.name) doesn't offer SCRAM") }
            // The mechanism of the sign-in itself, not the token it asks for along with it (`<request-token mechanism='HT-...'/>`).
            let signIn = try Regex(#"<(?:authenticate|auth)\s[^>]*?mechanism='([^']+)'"#)
            let mechanism = try #require(sent.firstMatch(of: signIn)?.output[1].substring.map(String.init), "no sign-in on the wire: \(sent.prefix(600))")
            #expect(mechanism == "SCRAM-SHA-256" || mechanism == "SCRAM-SHA-1", "signed in with \(mechanism)")
            // PLAIN would put the password on the wire, in the clear or as base64 of \0alice\0password.
            #expect(!sent.contains("AGFsaWNlAHBhc3N3b3Jk"))
            #expect(!sent.contains(">password<"))
        }

        /// Over TLS a password sign-in is bound to the connection (SCRAM-*-PLUS,
        /// XEP-0440), which the server checks: a wrong exporter or certificate
        /// hash is a refused sign-in, so signing in at all proves the binding.
        /// ejabberd, Snikket and Openfire list binding types once the stream is
        /// encrypted; elsewhere a server that offers no -PLUS still has to take
        /// SCRAM's "y" (we could have bound, it didn't offer), which a stripped
        /// offer would make it refuse.
        @Test func aPasswordSignInOverTLSIsBoundToTheConnection() async throws {
            _ = try LiveServer.devCA()
            let session = try LiveServer.makeTLSSession(alice, resource: "bound-\(UUID().uuidString.prefix(6))")
            session.connect()
            defer { session.disconnect() }
            try await LiveServer.waitUntil("the sign-in over TLS", timeout: 60) { session.state.value == .connected(isSyncing: false) }
            let mechanism = session.client.module(.sasl2).lastMechanism ?? session.client.module(.sasl).lastMechanism
            if ["ejabberd", "snikket", "openfire", "openfire-bare"].contains(LiveServer.target.name) {
                #expect(mechanism?.hasSuffix("-PLUS") == true, "signed in with \(mechanism ?? "nothing")")
            }
        }

        // MARK: Certificates

        #if os(macOS)
        /// A server that offers STARTTLS with a certificate this test made, and
        /// records what the client does once the handshake is over.
        private final class FakeServer {
            let directory: URL
            let port: Int
            private let process: Process

            /// `Process` doesn't exist on iOS, where the package's tests also run.
            init(certificateFor subjectAlternativeName: String, from start: Date, until end: Date) throws {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("tls-certificates-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.makeCertificate(in: directory, subjectAlternativeName: subjectAlternativeName, from: start, until: end)
                try Self.script.write(to: directory.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
                process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = ["-I", "server.py", "port.txt", "log.jsonl"]
                process.currentDirectoryURL = directory
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                // The server picks its port and writes it once it listens.
                let deadline = Date().addingTimeInterval(10)
                var port: Int?
                while port == nil, Date() < deadline {
                    port = (try? String(contentsOf: directory.appendingPathComponent("port.txt"), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if port == nil { Thread.sleep(forTimeInterval: 0.05) }
                }
                guard let port else { process.terminate(); throw Failure("the test server didn't start") }
                self.port = port
            }

            struct Failure: Error, CustomStringConvertible {
                let description: String
                init(_ description: String) { self.description = description }
            }

            deinit {
                process.terminate()
                try? FileManager.default.removeItem(at: directory)
            }

            var authority: SecCertificate? {
                get throws {
                    let pem = try String(contentsOf: directory.appendingPathComponent("ca.pem"), encoding: .utf8)
                    let der = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())
                    return der.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                }
            }

            /// What the server saw, in order: `handshake-ok`, `handshake-fail`, `recv` (bytes after the handshake).
            var events: [String] {
                let text = (try? String(contentsOf: directory.appendingPathComponent("log.jsonl"), encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap { line in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) .flatMap { ($0 as? [String: Any])?["ev"] as? String }
                }
            }

            @discardableResult
            private static func run(_ path: String, _ arguments: [String], in directory: URL) throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Failure("\(path) \(arguments.first ?? "") exited with \(process.terminationStatus)") }
                return process.terminationStatus
            }

            /// A CA of its own and a server certificate it signs with the given validity. LibreSSL's `x509` can't
            /// set the dates; `ca` can.
            private static func makeCertificate(in directory: URL, subjectAlternativeName: String, from start: Date, until end: Date) throws {
                let openssl = "/usr/bin/openssl"
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyyMMddHHmmss'Z'"
                try run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=Yapnest test CA",
                                  "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                                  "-keyout", "ca.key", "-out", "ca.pem"], in: directory)
                try run(openssl, ["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", "leaf.key", "-out", "leaf.csr"], in: directory)
                try "".write(to: directory.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
                try "01\n".write(to: directory.appendingPathComponent("serial"), atomically: true, encoding: .utf8)
                try """
                [ca]
                default_ca = authority
                [authority]
                database = index.txt
                new_certs_dir = .
                serial = serial
                default_md = sha256
                policy = any
                x509_extensions = server
                [any]
                commonName = supplied
                [server]
                subjectAltName = \(subjectAlternativeName)
                basicConstraints = critical,CA:FALSE
                keyUsage = critical,digitalSignature,keyEncipherment
                extendedKeyUsage = serverAuth
                """.write(to: directory.appendingPathComponent("ca.cnf"), atomically: true, encoding: .utf8)
                try run(openssl, ["ca", "-batch", "-config", "ca.cnf", "-cert", "ca.pem", "-keyfile", "ca.key", "-in", "leaf.csr",
                                  "-startdate", formatter.string(from: start), "-enddate", formatter.string(from: end), "-notext", "-out", "leaf.pem"], in: directory)
            }

            private static let script = #"""
            import socket, ssl, sys, threading, json
            portfile, logfile = sys.argv[1], sys.argv[2]
            HDR = b"<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0' from='localhost' id='x1'>"
            TLSF = b"<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>"
            lock = threading.Lock()
            def log(ev, data=""):
                with lock, open(logfile, "a") as f:
                    f.write(json.dumps({"ev": ev, "data": data}) + "\n")
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain("leaf.pem", "leaf.key")
            def handle(sock):
                try:
                    sock.settimeout(5)
                    buf = b""
                    while b"<stream:stream" not in buf: buf += sock.recv(4096)
                    sock.sendall(HDR + TLSF)
                    while b"<starttls" not in buf: buf += sock.recv(4096)
                    sock.sendall(b"<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
                    try:
                        s = ctx.wrap_socket(sock, server_side=True)
                    except Exception as e:
                        log("handshake-fail", repr(e)); return
                    log("handshake-ok")
                    s.settimeout(2)
                    try:
                        data = s.recv(65536)
                        if data: log("recv", data.decode("utf8", "replace"))
                    except Exception as e:
                        log("end", repr(e))
                    s.close()
                except Exception as e:
                    log("error", repr(e))
            srv = socket.socket()
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", 0))
            srv.listen(8)
            open(portfile, "w").write(str(srv.getsockname()[1]))
            while True:
                client, _ = srv.accept()
                threading.Thread(target=handle, args=(client,), daemon=True).start()
            """#
        }

        /// What a client that trusts the test's own CA does when it meets the certificate.
        private func meet(certificateFor name: String, from start: Date, until end: Date) async throws -> (state: XMPPSession.State, events: [String]) {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl"), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
                try Test.cancel("needs /usr/bin/openssl and /usr/bin/python3 to make a certificate and a server for it")
            }
            let server: FakeServer
            do {
                server = try FakeServer(certificateFor: name, from: start, until: end)
            } catch {
                try Test.cancel("couldn't set up the certificate and server: \(error)")
            }
            let session = try XMPPSession(
                credentials: .init(jid: alice, password: "password", host: "127.0.0.1", port: server.port, disableTLS: false),
                resource: "cert-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(),
            )
            session.trustOnly([try #require(try server.authority)])
            session.connect()
            defer { session.disconnect() }
            // A refused certificate fails the session for good; an accepted one carries on to the stream, which the server logs.
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if case .failed = session.state.value { break }
                if server.events.contains("recv") { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            // A refusal can still be on its way to the server's log.
            try await Task.sleep(for: .milliseconds(500))
            return (session.state.value, server.events)
        }

        /// The control for the two below: with the right name and dates, the
        /// same CA, server and client carry on to the stream. Without it they
        /// could pass because the setup is wrong.
        @Test func aCertificateThatIsRightIsAccepted() async throws {
            let outcome = try await meet(certificateFor: "DNS:localhost", from: .now.addingTimeInterval(-86400), until: .now.addingTimeInterval(86400))
            #expect(outcome.events.contains("recv"), "the client never wrote to the server: \(outcome)")
            #expect(outcome.state != .failed("The server's certificate isn't trusted."))
        }

        /// A certificate from a CA the client trusts, for another host name, is refused.
        @Test func aCertificateForTheWrongHostNameIsRefused() async throws {
            let outcome = try await meet(certificateFor: "DNS:evil.example", from: .now.addingTimeInterval(-86400), until: .now.addingTimeInterval(86400))
            #expect(outcome.state == .failed("The server's certificate isn't trusted."))
            #expect(!outcome.events.contains("recv"), "the client wrote to a server whose certificate is for another name: \(outcome.events)")
        }

        /// A certificate for the right name, from a CA the client trusts, that expired, is refused.
        @Test func anExpiredCertificateIsRefused() async throws {
            let outcome = try await meet(certificateFor: "DNS:localhost", from: .now.addingTimeInterval(-10 * 86400), until: .now.addingTimeInterval(-86400))
            #expect(outcome.state == .failed("The server's certificate isn't trusted."))
            #expect(!outcome.events.contains("recv"), "the client wrote to a server whose certificate has expired: \(outcome.events)")
        }
        #endif
    }
}
