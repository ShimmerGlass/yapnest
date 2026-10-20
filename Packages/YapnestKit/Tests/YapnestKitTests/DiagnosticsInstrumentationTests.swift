import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("tester@secret-domain.example")!
private let alice = YapnestKit.JID("alice@secret-domain.example")!

/// The log a send leaves behind: what happened, and nothing of who or what.
@Suite(.serialized)
struct DiagnosticsInstrumentationTests {
    private func withStore(_ body: (DiagnosticsStore) throws -> Void) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
        DiagLog.use(store)
        defer { DiagLog.use(nil) }
        try body(store)
        let url = try DiagnosticsExport.make(store: store)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aSendThatIsAcknowledgedThenOneThatIsDroppedAndOneOffline() throws {
        let text = try withStore { _ in
            let wire = FakeWire()
            let session = try makeSession(me)
            session.connectForTesting(wire)
            try session.setEncrypted(false, with: alice)
            session.enableAcknowledgementsForTesting()

            let first = try session.send("body canary one", to: alice)
            session.drainSendQueue(alice)
            let written = try #require(wire.messages.first { $0.id == first.remoteId })
            session.acknowledged(written)

            wire.failsWrites = true
            _ = try session.send("body canary two", to: alice)
            session.drainSendQueue(alice)
            wire.failsWrites = false
            session.sendUnclaimedPending()
            session.drainSendQueue(alice)

            let offline = try makeSession(me)
            _ = try offline.send("body canary three", to: alice)
        }
        for event in ["Send queued", "Written to the stream", "Server acknowledged", "Write dropped by the session", "Sending unclaimed pending messages", "Send waits"] {
            #expect(text.contains(event), "\(event)")
        }
        #expect(text.contains("reason=offline"))
        for secret in ["secret-domain", "tester", "alice", "canary", "body"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func connectionEventsLogKindsAndPortsButNoHost() throws {
        let text = try withStore { _ in
            XMPPSession.logConnect(.resolved(candidates: 0, fallback: true, duration: 0.12))
            XMPPSession.logConnect(.attempting(kind: .fallbackHost, port: 5222))
            XMPPSession.logConnect(.failed(kind: .fallbackHost, port: 5222, reason: .network, error: .posix, code: 61, duration: 1.5, triesNext: false))
            XMPPSession.logConnect(.ready(kind: .srvDirectTLS, port: 5223, family: .ipv6, duration: 0.3))
        }
        #expect(text.contains("fallbackHost=true"))
        #expect(text.contains("kind=fallbackHost port=5222 reason=network took=1.500s triesNext=false errorKind=posix errorCode=61"))
        #expect(text.contains("kind=srvDirectTLS port=5223 family=ipv6"))
    }

    @Test func aDisconnectionIsLoggedByKindAndNeverByText() throws {
        let text = try withStore { _ in
            let stream = Element(name: "error", xmlns: "http://etherx.jabber.org/streams")
            stream.addChild(Element(name: "host-unknown", xmlns: "urn:ietf:params:xml:ns:xmpp-streams"))
            stream.addChild(Element(name: "text", cdata: "secret-domain is not ours"))
            let session = try makeSession(me)
            session.logDisconnection(.streamError(stream), failure: nil)
        }
        #expect(text.contains("reason=streamError"))
        #expect(text.contains("condition=host-unknown"))
        #expect(!text.contains("secret-domain"))
    }
}
