import Foundation
import Martin
import Testing
@testable import YapnestKit

// `Process` doesn't exist on iOS, where the package's tests also run.
#if os(macOS)

/// A server whose certificate doesn't validate (self-signed, for the wrong
/// name), then whatever a scenario makes it say. The client must not write a byte
/// to it, nor parse or act on anything it says, once TLS has started but the
/// certificate hasn't been accepted. Needs python3 and openssl, so it only
/// runs with YAPNEST_TLS_HARNESS=1 (YAPNEST_TLS_HARNESS_N sets how many
/// connections each scenario makes, YAPNEST_TLS_HARNESS_HOG the longest the
/// main thread is stalled, in ms, to vary the timing).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAPNEST_TLS_HARNESS"] == "1"))
struct BadCertificateServerTests {
    private struct Record: Decodable { let c: Int; let phase: String; let ev: String; let data: String }

    private struct Outcome {
        var connections = 0
        var bytesAfterHandshake = 0
        var credentialLeaks = 0
        var handshakes = 0
        var featuresParsed = 0
        var loginStarted = 0
    }

    private let scenarios = ["plain", "plain_wait", "sasl2plain", "scram", "fast", "inject", "inject_success", "earlysuccess", "direct"]

    private func run(_ mode: String, trusting: Bool = false) async throws -> Outcome {
        let env = ProcessInfo.processInfo.environment
        let count = Int(env["YAPNEST_TLS_HARNESS_N"] ?? "") ?? 8
        let hog = Int(env["YAPNEST_TLS_HARNESS_HOG"] ?? "") ?? 150
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tls-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func launch(_ path: String, _ arguments: [String], in directory: URL) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        let openssl = try launch("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=evil.example", "-keyout", "key.pem", "-out", "cert.pem"], in: dir)
        openssl.waitUntilExit()
        try Self.serverScript.write(to: dir.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
        let port = mode == "direct" ? 5223 : Int.random(in: 20000..<30000)
        let log = dir.appendingPathComponent("log.jsonl")
        let server = try launch("/usr/bin/python3", ["-I", "server.py", mode, String(port), log.path], in: dir)
        defer { server.terminate() }
        try await Task.sleep(for: .milliseconds(700))

        var outcome = Outcome()
        for i in 0..<count {
            // A busy main thread is what a loaded app has, and what makes
            // main deliver the stream events late.
            if hog > 0 {
                let ms = [hog / 2, hog, hog / 3][i % 3]
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
            }
            let session = try XMPPSession(
                credentials: .init(jid: YapnestKit.JID("test@localhost")!, password: "hunter2-canary", host: "127.0.0.1", port: port),
                resource: "harness", database: try AppDatabase.inMemory(),
            )
            if trusting {
                session.client.connectionConfiguration.modifyConnectorOptions(type: SocketConnectorNetwork.Options.self) { $0.sslCertificateValidation = .customValidator { _ in true } }
            }
            session.connect()
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if session.client.module(.streamFeatures).streamFeatures.element?.findChild(name: "mechanisms") != nil
                    || session.client.module(.streamFeatures).streamFeatures.element?.findChild(name: "authentication") != nil {
                    outcome.featuresParsed += 1
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            if session.client.module(.auth).state != .notAuthorized { outcome.loginStarted += 1 }
            session.disconnect()
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .milliseconds(500))

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let records = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
        outcome.connections = Set(records.map(\.c)).count
        outcome.handshakes = records.filter { $0.ev == "handshake-ok" }.count
        let afterHandshake = records.filter { $0.phase == "tls" && $0.ev == "recv" && !$0.data.isEmpty }
        outcome.bytesAfterHandshake = Set(afterHandshake.map(\.c)).count
        outcome.credentialLeaks = afterHandshake.filter { $0.data.contains("hunter2") || $0.data.contains("canary") || $0.data.contains("AHRlc3QAaHVudGVy") }.count
        print("TLSHARNESS \(mode) hog=\(hog) \(outcome)")
        return outcome
    }

    @Test(arguments: ["plain", "plain_wait", "sasl2plain", "scram", "fast", "inject", "inject_success", "earlysuccess", "direct"])
    func nothingIsWrittenOrActedOnBeforeTheCertificateIsAccepted(mode: String) async throws {
        let outcome = try await run(mode)
        #expect(outcome.bytesAfterHandshake == 0)
        #expect(outcome.credentialLeaks == 0)
        #expect(outcome.featuresParsed == 0)
        #expect(outcome.loginStarted == 0)
    }

    /// The check must not cost the connections that pass it: with the
    /// certificate accepted, the client carries on and signs in.
    @Test(arguments: ["plain", "plain_wait", "sasl2plain", "direct"])
    func anAcceptedCertificateSignsIn(mode: String) async throws {
        let outcome = try await run(mode, trusting: true)
        #expect(outcome.bytesAfterHandshake == outcome.handshakes)
        #expect(outcome.handshakes > 0)
    }

    private static let serverScript = #"""
import socket, ssl, sys, threading, time, json, base64
fullmode, port, logf = sys.argv[1], int(sys.argv[2]), sys.argv[3]
mode = fullmode.replace("_wait","")
waitfirst = fullmode.endswith("_wait") or fullmode == "plain_delay"
T0 = time.time()
lock = threading.Lock()
cid = [0]
def log(c, phase, ev, data=b""):
    with lock, open(logf, "a") as f:
        f.write(json.dumps({"c": c, "t": round(time.time()-T0, 3), "phase": phase, "ev": ev, "data": data.decode("utf8", "replace")}) + "\n")
HDR = b"<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0' from='localhost' id='x1'>"
NS = "xmlns='urn:ietf:params:xml:ns:xmpp-sasl'"
TLSF = b"<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>"
PLAINF = ("<stream:features><mechanisms %s><mechanism>PLAIN</mechanism></mechanisms></stream:features>" % NS).encode()
SASL2PLAIN = b"<stream:features><authentication xmlns='urn:xmpp:sasl:2'><mechanism>PLAIN</mechanism></authentication></stream:features>"
SCRAMF = ("<stream:features><mechanisms %s><mechanism>SCRAM-SHA-1</mechanism></mechanisms></stream:features>" % NS).encode()
FASTF = b"<stream:features><authentication xmlns='urn:xmpp:sasl:2'><mechanism>SCRAM-SHA-256</mechanism><inline><fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast></inline></authentication></stream:features>"
FAKESUCCESS = ("<success %s/>" % NS).encode()
feat = {"plain": PLAINF, "plain_delay": PLAINF, "sasl2plain": SASL2PLAIN, "scram": SCRAMF, "fast": FASTF,
        "inject": PLAINF, "earlysuccess": PLAINF, "inject_success": PLAINF, "direct": PLAINF}[mode]
delay = 0.05 if mode == "plain_delay" else 0
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("cert.pem", "key.pem")

def pump(c, s, phase, secs):
    s.settimeout(0.1); end = time.time() + secs
    while time.time() < end:
        try:
            d = s.recv(65536)
        except socket.timeout: continue
        except Exception as e:
            log(c, phase, "end", repr(e).encode()); return
        if not d: log(c, phase, "eof"); return
        log(c, phase, "recv", d)

def handle(sock):
    cid[0] += 1; c = cid[0]
    try:
        if mode != "direct":
            sock.settimeout(5)
            buf = b""
            while b"<stream:stream" not in buf: buf += sock.recv(4096)
            log(c, "plain", "recv", buf)
            sock.sendall(HDR + TLSF + (FAKESUCCESS if mode == "earlysuccess" else b""))
            while b"<starttls" not in buf: buf += sock.recv(4096)
            if mode.startswith("inject"):
                inj = HDR[HDR.index(b"<stream:stream"):] if False else b""
                inj = feat + (FAKESUCCESS if mode == "inject_success" else b"")
                sock.sendall(b"<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" + inj)
                log(c, "plain", "sent-proceed+inject", inj)
            else:
                sock.sendall(b"<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        try:
            s = ctx.wrap_socket(sock, server_side=True)
        except Exception as e:
            log(c, "tls", "handshake-fail", repr(e).encode()); return
        log(c, "tls", "handshake-ok")
        s.settimeout(3)
        if waitfirst:
            first = s.recv(65536); log(c, "tls", "recv", first)
            if delay: time.sleep(delay)
        s.sendall(HDR + feat); log(c, "tls", "sent-features")
        pump(c, s, "tls", 1.0)
        try: s.close()
        except: pass
    except Exception as e:
        log(c, "?", "exc", repr(e).encode())
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(50)
while True:
    cl, _ = srv.accept()
    threading.Thread(target=handle, args=(cl,), daemon=True).start()
"""#
}
#endif
