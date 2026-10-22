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

/// What a call leaves in the log: where its time went, and nothing of who it
/// was with or where they are.
extension DiagnosticsInstrumentationTests {
    @Test func aCallLogsItsPhasesCandidatesAndTimingsButNoSessionIdOrAddress() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
        DiagLog.use(store)
        defer { DiagLog.use(nil) }

        let h = try CallSessionHarness()
        try h.session.startCall(to: YapnestKit.JID("alice@example.org")!)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let media = try #require(h.factory.last)
        media.emit(.candidate(CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1 1 udp 2122260223 10.0.0.2 40000 typ host generation 0 ufrag FakeU network-id 1")))
        // One candidate comes inside the answer, which reaches the media with
        // the description, and one as transport-info.
        try h.receive(iq: h.sessionAccept(sid: sid).replacingOccurrences(of: "</transport>", with: """
            <candidate component='1' foundation='2' generation='0' id='b' ip='203.0.113.9' network='0' port='4141' priority='1' protocol='udp' type='host'/></transport>
            """))
        try h.receive(iq: """
            <iq from='alice@example.org/phone' to='me@example.org/phone' type='set' id='t'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
            <content creator='initiator' name='0'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Yy11' pwd='anothersecretanothersecret'>\
            <candidate component='1' foundation='3' generation='0' id='c' ip='198.51.100.7' network='0' port='4242' priority='1' protocol='udp' type='relay'/>\
            </transport></content></jingle></iq>
            """)
        await eventually("the candidate to reach the media") { media.remoteCandidates.count == 1 && media.answersSet.count == 1 }
        media.emit(.state(.connected))
        await eventually("the call to be active") { h.phase == .active }
        h.session.hangUpCall()
        await eventually("the media to close") { media.isClosed }

        let text = try String(contentsOf: DiagnosticsExport.make(store: store), encoding: .utf8)
        // Other suites' calls log into the same store while this one runs.
        let mine = text.split(separator: "\n").filter { $0.contains("sid=\(Redacted.id(sid).hex)") }.joined(separator: "\n")
        for line in ["Call phase", "Call local candidate", "Call remote candidate", "Call media sid", "Call media started"] {
            #expect(mine.contains(line), "\(line)")
        }
        #expect(mine.contains("phase=active"))
        #expect(mine.contains("phase=ended reason=completed"))
        #expect(mine.contains("type=relay"))
        #expect(mine.contains("state=connected"))
        #expect(mine.contains("localHost=1"))
        #expect(mine.contains("remoteHost=1"))
        #expect(mine.contains("remoteRelay=1"))
        #expect(mine.contains("sinceAnswered="))
        #expect(text.contains("Call relays ready"))
        for secret in [sid, "alice", "example.org", "10.0.0.2", "198.51.100.7", "203.0.113.9", "FakeU", "anothersecret"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }
}
