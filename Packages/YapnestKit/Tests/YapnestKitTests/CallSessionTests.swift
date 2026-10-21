import Foundation
import GRDB
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let aliceDevice = "alice@example.org/phone"

/// Media that does what the call asks without any audio: canned descriptions,
/// and a record of what it was told.
final class FakeCallMedia: CallMedia, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<CallMediaEvent>.Continuation
    let events: AsyncStream<CallMediaEvent>
    private(set) var iceServers: [CallIceServer]?
    private(set) var offers: [String] = []
    private(set) var answeredOffers: [String] = []
    private(set) var answersSet: [String] = []
    private(set) var remoteCandidates: [CallCandidate] = []
    private(set) var muted = false
    private(set) var startedWithVideo: Bool?
    private(set) var cameraEnabled: Bool?
    private(set) var cameraSwitches = 0
    private(set) var isClosed = false
    var failsToStart = false
    /// What `answer(offer:)` returns instead of the canned description, for tests of how we read WebRTC's.
    var answerOverride: String?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    static func sdp(setup: String, mid: String = "0") -> String {
        [
            "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE \(mid)",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 0", "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:FakeU", "a=ice-pwd:fakepasswordfakepassword12",
            "a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
            "a=setup:\(setup)", "a=mid:\(mid)", "a=sendrecv", "a=rtcp-mux",
            "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1", "a=rtpmap:0 PCMU/8000", "",
        ].joined(separator: "\r\n")
    }

    func start(iceServers: [CallIceServer], video: Bool) async throws {
        if failsToStart { throw CallRunError.closed }
        lock.withLock {
            self.iceServers = iceServers
            startedWithVideo = video
        }
    }

    func makeOffer() async throws -> String {
        let sdp = Self.sdp(setup: "actpass")
        lock.withLock { offers.append(sdp) }
        return sdp
    }

    func answer(offer: String) async throws -> String {
        lock.withLock { answeredOffers.append(offer) }
        if let answerOverride { return answerOverride }
        // As WebRTC's answer: the offer's sections, under the same names.
        let mid = offer.components(separatedBy: "\r\n").first { $0.hasPrefix("a=mid:") }.map { String($0.dropFirst(6)) } ?? "0"
        return Self.sdp(setup: "active", mid: mid)
    }

    func setAnswer(_ sdp: String) async throws {
        lock.withLock { answersSet.append(sdp) }
    }

    func addRemoteCandidate(_ candidate: CallCandidate) async throws {
        lock.withLock { remoteCandidates.append(candidate) }
    }

    func setMuted(_ muted: Bool) {
        lock.withLock { self.muted = muted }
    }

    func setCameraEnabled(_ on: Bool) {
        lock.withLock { cameraEnabled = on }
    }

    func switchCamera() {
        lock.withLock { cameraSwitches += 1 }
    }

    func close() {
        lock.withLock { isClosed = true }
        continuation.finish()
    }

    func emit(_ event: CallMediaEvent) { continuation.yield(event) }
}

final class FakeCallMediaFactory: CallMediaFactory, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var made: [FakeCallMedia] = []
    var failsToStart = false
    var answerOverride: String?

    func makeMedia() -> any CallMedia {
        let media = FakeCallMedia()
        media.failsToStart = failsToStart
        media.answerOverride = answerOverride
        lock.withLock { made.append(media) }
        return media
    }

    var last: FakeCallMedia? { lock.withLock { made.last } }
}

/// Polls until `condition` holds, for what the session does in the background.
func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// One session of ours, on a stand-in connection, with a roster of alice.
struct CallSessionHarness {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let factory = FakeCallMediaFactory()

    init(withMedia: Bool = true, connected: Bool = true) throws {
        database = try AppDatabase.inMemory()
        session = try XMPPSession(
            credentials: .init(jid: me, password: "x"), resource: "phone", database: database,
            callMedia: withMedia ? factory : nil,
        )
        try database.writer.write { try Contact(jid: alice, isInRoster: true).insert($0) }
        wire.answer { iq in
            // A server without relays refuses the request, as one without extdisco does.
            iq.firstChild(name: "services", xmlns: "urn:xmpp:extdisco:2") != nil ? FakeWire.error(to: iq, condition: "service-unavailable") : FakeWire.result(to: iq)
        }
        if connected {
            session.connectForTesting(wire)
            session.client.module(.resourceBind).bindedJid = Martin.JID("me@example.org/phone")
        }
    }

    func receive(_ xml: String, source: InboundMessage.Source = .live) {
        let stanza: Martin.Message = parseStanza(xml)
        switch source {
        case .carbon(let sent):
            let carbon = Element(name: sent ? "sent" : "received", xmlns: "urn:xmpp:carbons:2")
            carbon.addChild(Element(name: "forwarded", xmlns: "urn:xmpp:forward:0", children: [stanza.element]))
            let wrapper = Martin.Message()
            wrapper.from = Martin.JID("me@example.org")
            wrapper.to = Martin.JID("me@example.org/phone")
            wrapper.addChild(carbon)
            session.handleTopLevel(wrapper)
        case .archive:
            session.handle(stanza, source: source)
        case .live:
            session.handleTopLevel(stanza)
        }
    }

    func receive(iq xml: String) throws {
        let iq: Iq = parseStanza(xml)
        let jingle = try #require(session.client.modulesManager.moduleOrNil(JingleModule.IDENTIFIER))
        try jingle.process(stanza: iq)
    }

    func propose(sid: String = "s1", from: String = aliceDevice, extra: String = "", media: String = "audio") -> String {
        "<message from='\(from)' to='me@example.org' type='chat' id='p'><propose xmlns='urn:xmpp:jingle-message:0' id='\(sid)'><description xmlns='urn:xmpp:jingle:apps:rtp:1' media='\(media)'/></propose>\(extra)</message>"
    }

    func jmi(_ action: String, sid: String = "s1", from: String = aliceDevice, to: String = "me@example.org/phone", inner: String = "") -> String {
        "<message from='\(from)' to='\(to)' type='chat' id='j'><\(action) xmlns='urn:xmpp:jingle-message:0' id='\(sid)'>\(inner)</\(action)></message>"
    }

    /// The stanzas written with a JMI element, as (action, to, sid).
    var sentSignals: [(action: String, to: String, sid: String)] {
        wire.messages.compactMap { message in
            guard let element = message.element.children.first(where: { $0.xmlns == "urn:xmpp:jingle-message:0" }) else { return nil }
            return (element.name, message.to?.stringValue ?? "", element.getAttribute("id") ?? "")
        }
    }

    func jingleIqs(_ action: String) -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "jingle", xmlns: "urn:xmpp:jingle:1")?.getAttribute("action") == action }
    }

    var phase: CallPhase? { session.callState.value?.phase }

    func rows() throws -> [YapnestKit.Message] {
        try database.reader.read { try YapnestKit.Message.filter(Column("callOutcome") != nil).order(Column("id")).fetchAll($0) }
    }

    func sessionInitiate(sid: String = "s1", from: String = aliceDevice) -> String {
        """
        <iq from='\(from)' to='me@example.org/phone' type='set' id='si'><jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='\(from)' sid='\(sid)'>\
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='audio'/></group>\
        <content creator='initiator' name='audio' senders='both'>\
        <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'><payload-type id='111' name='opus' clockrate='48000' channels='2'/><rtcp-mux/></description>\
        <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Xy99' pwd='secretsecretsecretsecret'>\
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89</fingerprint></transport>\
        </content></jingle></iq>
        """
    }

    func sessionAccept(sid: String = "s1", from: String = aliceDevice) -> String {
        """
        <iq from='\(from)' to='me@example.org/phone' type='set' id='sa'><jingle xmlns='urn:xmpp:jingle:1' action='session-accept' responder='\(from)' sid='\(sid)'>\
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='0'/></group>\
        <content creator='initiator' name='0' senders='both'>\
        <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'><payload-type id='111' name='opus' clockrate='48000' channels='2'/><rtcp-mux/></description>\
        <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Yy11' pwd='anothersecretanothersecret'>\
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='active'>12:34:56:78</fingerprint></transport>\
        </content></jingle></iq>
        """
    }
}

struct CallSessionOutgoingTests {
    @Test func aCallRingsConnectsAndEnds() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let state = try #require(h.session.callState.value)
        let sid = state.sid
        #expect(state.phase == .proposing)
        #expect(state.direction == .outgoing)
        #expect(state.peer == alice)
        await eventually("the propose") { !h.sentSignals.isEmpty }
        let propose = try #require(h.sentSignals.first)
        #expect(propose.action == "propose")
        #expect(propose.to == "alice@example.org")
        #expect(propose.sid == sid)

        h.receive(h.jmi("ringing", sid: sid))
        #expect(h.phase == .ringing)

        h.receive(h.jmi("proceed", sid: sid))
        #expect(h.phase == .accepted)
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let initiate = try #require(h.jingleIqs("session-initiate").first)
        #expect(initiate.to?.stringValue == aliceDevice)
        let jingle = try #require(initiate.firstChild(name: "jingle"))
        #expect(jingle.getAttribute("sid") == sid)
        #expect(jingle.getAttribute("initiator") == "me@example.org/phone")
        #expect(jingle.firstChild(name: "group", xmlns: "urn:xmpp:jingle:apps:grouping:0") != nil)
        let content = try #require(jingle.firstChild(name: "content"))
        #expect(content.getAttribute("creator") == "initiator")
        #expect(content.firstChild(name: "description", xmlns: "urn:xmpp:jingle:apps:rtp:1") != nil)
        #expect(content.firstChild(name: "transport")?.getAttribute("ufrag") == "FakeU")

        try h.receive(iq: h.sessionAccept(sid: sid))
        #expect(h.phase == .connecting)
        let media = try #require(h.factory.last)
        await eventually("the answer to reach the media") { media.answersSet.count == 1 }
        #expect(media.answersSet.first?.contains("a=setup:active") == true)

        media.emit(.state(.connected))
        await eventually("the call to be active") { h.phase == .active }
        #expect(h.session.callState.value?.activeSince != nil)

        h.session.hangUpCall()
        #expect(h.phase == .ended(.completed))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        let row = try #require(try h.rows().first)
        #expect(row.callOutcome == .answered)
        #expect(row.direction == .outgoing)
        #expect(row.remoteId == sid)
        #expect(row.callDuration != nil)
        #expect(h.jingleIqs("session-terminate").count == 1)
        #expect(h.sentSignals.contains { $0.action == "finish" && $0.to == aliceDevice })
        await eventually("the media to close") { media.isClosed }
    }

    @Test func candidatesAreTrickledBothWays() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let media = try #require(h.factory.last)

        media.emit(.candidate(CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1 1 udp 2122260223 10.0.0.2 40000 typ host generation 0 ufrag FakeU network-id 1")))
        await eventually("the transport-info") { !h.jingleIqs("transport-info").isEmpty }
        let info = try #require(h.jingleIqs("transport-info").first)
        #expect(info.to?.stringValue == aliceDevice)
        let transport = try #require(info.firstChild(name: "jingle")?.firstChild(name: "content")?.firstChild(name: "transport"))
        #expect(transport.getAttribute("ufrag") == "FakeU")
        #expect(transport.getAttribute("pwd") == "fakepasswordfakepassword12")
        #expect(transport.firstChild(name: "candidate")?.getAttribute("ip") == "10.0.0.2")

        try h.receive(iq: h.sessionAccept(sid: sid))
        try h.receive(iq: """
            <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='t'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
            <content creator='initiator' name='0'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Yy11' pwd='anothersecretanothersecret'>\
            <candidate component='1' foundation='3' generation='0' id='c' ip='198.51.100.7' network='0' port='4242' priority='1' protocol='udp' type='host'/>\
            </transport></content></jingle></iq>
            """)
        await eventually("the candidate to reach the media") { media.remoteCandidates.count == 1 }
        #expect(media.remoteCandidates.first?.sdp.contains("198.51.100.7 4242") == true)
        // After the answer was set.
        #expect(media.answersSet.count == 1)
    }

    @Test func aCandidateFromAStrangerIsRefused() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let info = """
            <iq from='mallory@example.org/x' to='me@example.org/phone' type='set' id='t'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
            <content creator='initiator' name='0'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='u' pwd='p'/></content></jingle></iq>
            """
        #expect(throws: (any Error).self) { try h.receive(iq: info) }
    }

    @Test func hangingUpWhileItRingsRetracts() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.session.hangUpCall()
        #expect(h.phase == .ended(.cancelled))
        await eventually("the retract") { h.sentSignals.contains { $0.action == "retract" } }
        let retract = try #require(h.sentSignals.first { $0.action == "retract" })
        #expect(retract.to == "alice@example.org")
        #expect(retract.sid == sid)
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .cancelled)
        #expect(try h.rows().first?.isRead == true)
    }

    @Test func aReceiptForTheProposeMakesItRing() throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='r'><received xmlns='urn:xmpp:receipts' id='jm-propose-\(sid)'/></message>")
        #expect(h.phase == .ringing)
    }

    @Test func aDeclineEndsItAsDeclined() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("reject", sid: sid, inner: "<reason xmlns='urn:xmpp:jingle:1'><decline/></reason>"))
        #expect(h.phase == .ended(.declined))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .declined)
    }

    @Test func aBusyPeerEndsItAsBusy() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("reject", sid: sid, inner: "<reason xmlns='urn:xmpp:jingle:1'><busy/></reason>"))
        #expect(h.phase == .ended(.busy))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .busy)
    }

    @Test func mediaThatCannotStartEndsTheCall() async throws {
        let h = try CallSessionHarness()
        h.factory.failsToStart = true
        try h.session.startCall(to: alice)
        await eventually("the call to fail") { h.phase == .ended(.failed) }
        await eventually("the retract") { h.sentSignals.contains { $0.action == "retract" } }
    }

    @Test func theMediaFailingEndsTheSession() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        try h.receive(iq: h.sessionAccept(sid: sid))
        await eventually("the media") { h.factory.last != nil }
        let media = try #require(h.factory.last)
        await eventually("the answer") { media.answersSet.count == 1 }
        media.emit(.state(.failed))
        await eventually("the call to fail") { h.phase == .ended(.failed) }
        await eventually("the session to be ended") { h.jingleIqs("session-terminate").count == 1 }
        let reason = h.jingleIqs("session-terminate").first?.firstChild(name: "jingle")?.firstChild(name: "reason")
        #expect(reason?.firstChild(name: "connectivity-error") != nil)
        await eventually("the finish") { h.sentSignals.contains { $0.action == "finish" } }
    }

    @Test func theRemoteTerminatingEndsTheCall() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        try h.receive(iq: h.sessionAccept(sid: sid))
        await eventually("the media") { h.factory.last != nil }
        let media = try #require(h.factory.last)
        media.emit(.state(.connected))
        await eventually("the call to be active") { h.phase == .active }
        try h.receive(iq: """
            <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='x'><jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'>\
            <reason><success/></reason></jingle></iq>
            """)
        #expect(h.phase == .ended(.completed))
        // The terminate was answered.
        let result = h.wire.written.compactMap { $0 as? Iq }.last { $0.type == .result && $0.id == "x" }
        #expect(result != nil)
        await eventually("the media to close") { media.isClosed }
    }

    @Test func aTerminateForNoCallIsAnError() throws {
        let h = try CallSessionHarness()
        #expect(throws: (any Error).self) {
            try h.receive(iq: "<iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='x'><jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='nope'><reason><success/></reason></jingle></iq>")
        }
    }

    @Test func theRelaysOfTheServerReachTheMedia() async throws {
        let h = try CallSessionHarness()
        h.wire.answer { iq in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                return FakeWire.discoInfo(to: iq, category: "server", type: "im", features: ["urn:xmpp:extdisco:2"])
            }
            if iq.firstChild(name: "services", xmlns: "urn:xmpp:extdisco:2") != nil {
                let services = Element(name: "services", xmlns: "urn:xmpp:extdisco:2")
                services.addChild(Element(name: "service", attributes: ["type": "stun", "host": "198.51.100.1", "port": "3478", "transport": "udp"]))
                services.addChild(Element(name: "service", attributes: ["type": "turn", "host": "198.51.100.1", "port": "3478", "transport": "udp", "username": "u", "password": "p"]))
                return FakeWire.result(to: iq, services)
            }
            return FakeWire.result(to: iq)
        }
        // The server says it has the service.
        h.session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
        try h.session.startCall(to: alice)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(h.factory.last?.iceServers == [
            CallIceServer(urls: ["stun:198.51.100.1:3478"]),
            CallIceServer(urls: ["turn:198.51.100.1:3478?transport=udp"], username: "u", credential: "p"),
        ])
    }

    @Test func aServerWithoutRelaysIsNoReasonNotToCall() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(h.factory.last?.iceServers == [])
        #expect(h.phase == .proposing)
    }

    @Test func mutingReachesTheMediaAndTheState() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        h.session.setCallMuted(true)
        #expect(h.session.callState.value?.isMuted == true)
        await eventually("the media to be muted") { h.factory.last?.muted == true }
        h.session.setCallMuted(false)
        #expect(h.session.callState.value?.isMuted == false)
    }

    @Test func oneCallAtATime() throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        #expect(throws: CallError.busy) { try h.session.startCall(to: alice) }
    }

    @Test func aCallNeedsAConnectionAndMedia() throws {
        let offline = try CallSessionHarness(connected: false)
        #expect(throws: CallError.notConnected) { try offline.session.startCall(to: alice) }
        let plain = try CallSessionHarness(withMedia: false)
        #expect(throws: CallError.unavailable) { try plain.session.startCall(to: alice) }
    }

    @Test func aNewCallCanFollowAnEndedOne() throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        h.session.hangUpCall()
        try h.session.startCall(to: alice)
        #expect(h.phase == .proposing)
    }
}

struct CallSessionIncomingTests {
    @Test func aCallRingsIsAnsweredAndEnded() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        let state = try #require(h.session.callState.value)
        #expect(state.phase == .incoming)
        #expect(state.direction == .incoming)
        #expect(state.peer == alice)
        #expect(state.sid == "s1")
        await eventually("ringing") { h.sentSignals.contains { $0.action == "ringing" } }
        #expect(h.sentSignals.first { $0.action == "ringing" }?.to == aliceDevice)
        // No call media is made, the microphone included, until the user answers.
        #expect(h.factory.made.isEmpty)

        h.session.answerCall()
        #expect(h.phase == .accepted)
        await eventually("proceed and accept") { h.sentSignals.contains { $0.action == "proceed" } && h.sentSignals.contains { $0.action == "accept" } }
        #expect(h.sentSignals.first { $0.action == "proceed" }?.to == aliceDevice)
        #expect(h.sentSignals.first { $0.action == "accept" }?.to == "me@example.org")
        await eventually("the media to start") { h.factory.last?.iceServers != nil }

        try h.receive(iq: h.sessionInitiate())
        #expect(h.phase == .connecting)
        // The initiate was acknowledged.
        let result = h.wire.written.compactMap { $0 as? Iq }.last { $0.type == .result && $0.id == "si" }
        #expect(result != nil)
        let media = try #require(h.factory.last)
        await eventually("the answer") { !h.jingleIqs("session-accept").isEmpty }
        #expect(media.answeredOffers.count == 1)
        let offer = try #require(media.answeredOffers.first)
        #expect(offer.contains("a=ice-ufrag:Xy99"))
        #expect(offer.contains("a=rtpmap:111 opus/48000/2"))
        #expect(offer.contains("a=group:BUNDLE audio"))
        let accept = try #require(h.jingleIqs("session-accept").first)
        #expect(accept.to?.stringValue == aliceDevice)
        let jingle = try #require(accept.firstChild(name: "jingle"))
        #expect(jingle.getAttribute("sid") == "s1")
        #expect(jingle.getAttribute("responder") == "me@example.org/phone")
        #expect(jingle.firstChild(name: "content")?.getAttribute("creator") == "initiator")
        #expect(jingle.firstChild(name: "content")?.firstChild(name: "transport")?.firstChild(name: "fingerprint")?.getAttribute("setup") == "active")

        media.emit(.state(.connected))
        await eventually("the call to be active") { h.phase == .active }
        try h.receive(iq: """
            <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='x'><jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='s1'><reason><success/></reason></jingle></iq>
            """)
        #expect(h.phase == .ended(.completed))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        let row = try #require(try h.rows().first)
        #expect(row.callOutcome == .answered)
        #expect(row.direction == .incoming)
        #expect(row.isRead)
    }

    @Test func decliningRejectsAndRecordsIt() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.session.declineCall()
        #expect(h.phase == .ended(.declined))
        await eventually("the reject") { h.sentSignals.contains { $0.action == "reject" } }
        #expect(h.sentSignals.first { $0.action == "reject" }?.to == aliceDevice)
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .declined)
        #expect(h.factory.made.isEmpty)
    }

    @Test func theCallerHangingUpIsAMissedCall() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.receive(h.jmi("retract", inner: "<reason xmlns='urn:xmpp:jingle:1'><cancel/></reason>"))
        #expect(h.phase == .ended(.missed))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        let row = try #require(try h.rows().first)
        #expect(row.callOutcome == .missed)
        #expect(!row.isRead)
    }

    @Test func aMissedCallNotifiesTheApp() async throws {
        let h = try CallSessionHarness()
        let received = OSAllocatedCounter()
        let cancellable = h.session.events.sink { event in
            if case .newMessage(let message) = event, message.callOutcome == .missed { _ = received.next() }
        }
        defer { cancellable.cancel() }
        h.receive(h.propose())
        h.receive(h.jmi("retract"))
        await eventually("the event") { received.next() >= 1 }
    }

    @Test func aProposeFromAContactWhoIsNotInTheRosterIsIgnored() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose(from: "mallory@example.org/x"))
        #expect(h.session.callState.value == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.sentSignals.isEmpty)
        #expect(try h.rows().isEmpty)
    }

    @Test func aProposeThatWaitedTooLongNeverRings() async throws {
        let h = try CallSessionHarness()
        let delay = "<delay xmlns='urn:xmpp:delay' from='example.org' stamp='\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)))'/>"
        h.receive(h.propose(extra: delay))
        #expect(h.session.callState.value == nil)
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        let row = try #require(try h.rows().first)
        #expect(row.callOutcome == .missed)
        #expect(!row.isRead)
        #expect(h.sentSignals.isEmpty)
    }

    @Test func aSecondCallFromSomeoneElseWhileOneIsGoingOnIsRefusedAsBusy() async throws {
        let h = try CallSessionHarness()
        let bob = YapnestKit.JID("bob@example.org")!
        try await h.database.writer.write { try Contact(jid: bob, isInRoster: true).insert($0) }
        try h.session.startCall(to: alice)
        let own = try #require(h.session.callState.value?.sid)
        h.receive(h.propose(sid: "other", from: "bob@example.org/desktop"))
        await eventually("the reject") { h.sentSignals.contains { $0.action == "reject" } }
        let reject = try #require(h.wire.messages.first { $0.firstChild(name: "reject", xmlns: "urn:xmpp:jingle-message:0") != nil })
        #expect(reject.to?.stringValue == "bob@example.org/desktop")
        #expect(reject.firstChild(name: "reject")?.getAttribute("id") == "other")
        #expect(reject.firstChild(name: "reject")?.firstChild(name: "reason")?.firstChild(name: "busy") != nil)
        #expect(reject.firstChild(name: "reject")?.firstChild(name: "tie-break") == nil)
        await eventually("the missed call") { (try? h.rows().count) == 1 }
        let row = try #require(try h.rows().first)
        #expect(row.remoteId == "other")
        #expect(row.callOutcome == .missed)
        #expect(!row.isRead)
        // The call we were in is untouched.
        #expect(h.session.callState.value?.sid == own)
        #expect(h.phase == .proposing)
    }

    // MARK: Tie-break (XEP-0353 section 4.1)

    @Test func aLowerSessionIdFromThePeerWinsAndOursGivesWay() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let own = try #require(h.session.callState.value?.sid)
        h.receive(h.propose(sid: "!theirs"))
        // Ours is retracted with the tie-break, and theirs rings.
        await eventually("the retract") { h.sentSignals.contains { $0.action == "retract" && $0.sid == own } }
        let retract = try #require(h.wire.messages.first { $0.firstChild(name: "retract", xmlns: "urn:xmpp:jingle-message:0") != nil })
        #expect(retract.firstChild(name: "retract")?.firstChild(name: "tie-break") != nil)
        #expect(retract.firstChild(name: "retract")?.firstChild(name: "reason")?.firstChild(name: "expired") != nil)
        let state = try #require(h.session.callState.value)
        #expect(state.sid == "!theirs")
        #expect(state.phase == .incoming)
        #expect(!h.sentSignals.contains { $0.action == "reject" })
        // Neither a busy nor a cancelled call is logged for ours.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.rows().isEmpty)
        // Answering theirs works as for any call.
        h.session.answerCall()
        #expect(h.phase == .accepted)
    }

    @Test func aHigherSessionIdFromThePeerIsRejectedAndOursKeepsRinging() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let own = try #require(h.session.callState.value?.sid)
        h.receive(h.propose(sid: "~theirs"))
        await eventually("the reject") { h.sentSignals.contains { $0.action == "reject" } }
        let reject = try #require(h.wire.messages.first { $0.firstChild(name: "reject", xmlns: "urn:xmpp:jingle-message:0") != nil })
        #expect(reject.to?.stringValue == aliceDevice)
        #expect(reject.firstChild(name: "reject")?.getAttribute("id") == "~theirs")
        #expect(reject.firstChild(name: "reject")?.firstChild(name: "tie-break") != nil)
        #expect(reject.firstChild(name: "reject")?.firstChild(name: "reason")?.firstChild(name: "expired") != nil)
        #expect(h.session.callState.value?.sid == own)
        #expect(h.phase == .proposing)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.rows().isEmpty)
        // The retract that comes back for theirs is no call of ours either.
        h.receive(h.jmi("retract", sid: "~theirs", inner: "<tie-break/>"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.rows().isEmpty)
        #expect(h.phase == .proposing)
    }

    @Test func theSameSessionIdIsSettledByTheLowerAddress() async throws {
        // alice@... sorts before me@..., so she wins.
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let own = try #require(h.session.callState.value?.sid)
        h.receive(h.propose(sid: own))
        await eventually("our retract") { h.sentSignals.contains { $0.action == "retract" } }
        #expect(h.phase == .incoming)

        // zed@... sorts after me@..., so we win.
        let g = try CallSessionHarness()
        let zed = YapnestKit.JID("zed@example.org")!
        try await g.database.writer.write { try Contact(jid: zed, isInRoster: true).insert($0) }
        try g.session.startCall(to: zed)
        let sid = try #require(g.session.callState.value?.sid)
        g.receive(g.propose(sid: sid, from: "zed@example.org/x"))
        await eventually("our reject") { g.sentSignals.contains { $0.action == "reject" } }
        #expect(g.phase == .proposing)
        #expect(g.session.callState.value?.sid == sid)
    }

    @Test func aTieBreakRejectEndsOurCallWithoutBeingDeclinedOrBusy() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let own = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("reject", sid: own, inner: "<reason xmlns='urn:xmpp:jingle:1'><expired/></reason><tie-break/>"))
        #expect(h.phase == .ended(.tieBreak))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.rows().isEmpty)
    }

    @Test func aProposeAfterTheCallWasAnsweredIsBusyNotATie() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let own = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: own))
        #expect(h.phase == .accepted)
        h.receive(h.propose(sid: "!theirs", from: "alice@example.org/desktop"))
        await eventually("the reject") { h.sentSignals.contains { $0.action == "reject" } }
        let reject = try #require(h.wire.messages.first { $0.firstChild(name: "reject", xmlns: "urn:xmpp:jingle-message:0") != nil })
        #expect(reject.firstChild(name: "reject")?.firstChild(name: "tie-break") == nil)
        #expect(h.session.callState.value?.sid == own)
    }

    // MARK: Dismissing

    @Test func dismissingARingingCallSendsNothingAndLogsItMissed() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        await eventually("ringing") { h.sentSignals.contains { $0.action == "ringing" } }
        let before = h.sentSignals.count
        h.session.dismissIncomingCall()
        #expect(h.phase == .ended(.dismissed))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .missed)
        #expect(h.sentSignals.count == before)
        #expect(!h.sentSignals.contains { $0.action == "reject" })
    }

    @Test func aCallDismissedHereIsAnsweredElsewhereInTheLog() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.session.dismissIncomingCall()
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        h.receive(h.jmi("proceed", from: "me@example.org/tablet", to: aliceDevice), source: .carbon(sent: true))
        await eventually("the row to be answered") { (try? h.rows().first?.callOutcome) == .answered }
    }

    @Test func aCallCanOnlyBeDismissedWhileItRingsHere() throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        h.session.dismissIncomingCall()
        #expect(h.phase == .proposing)
    }

    @Test func anotherDeviceOfOursAnsweringStopsTheRing() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.receive(h.jmi("proceed", from: "me@example.org/tablet", to: aliceDevice), source: .carbon(sent: true))
        #expect(h.phase == .ended(.answeredElsewhere))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .answered)
        #expect(try h.rows().first?.isRead == true)
    }

    @Test func theAcceptOfAnotherDeviceStopsTheRingToo() throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.receive(h.jmi("accept", from: "me@example.org/tablet", to: "me@example.org"))
        #expect(h.phase == .ended(.answeredElsewhere))
    }

    @Test func anotherDeviceOfOursDecliningStopsTheRing() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.receive(h.jmi("reject", from: "me@example.org/tablet", to: aliceDevice), source: .carbon(sent: true))
        #expect(h.phase == .ended(.declinedElsewhere))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .declined)
    }

    @Test func aSessionInitiateFromTheWrongDeviceIsRefused() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.session.answerCall()
        #expect(throws: (any Error).self) { try h.receive(iq: h.sessionInitiate(from: "alice@example.org/other")) }
        #expect(throws: (any Error).self) { try h.receive(iq: h.sessionInitiate(sid: "different")) }
        #expect(h.phase == .accepted)
        // A refused offer leaves nothing for the answer to read.
        #expect(h.session.lock.withLock { $0.call?.run.remote } == nil)
        try h.receive(iq: h.sessionInitiate())
        #expect(h.phase == .connecting)
    }

    @Test func aSessionInitiateBeforeWeAnsweredIsRefused() throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        #expect(throws: (any Error).self) { try h.receive(iq: h.sessionInitiate()) }
        #expect(h.phase == .incoming)
    }

    @Test func anOfferWithoutUsableAudioFailsTheCall() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.session.answerCall()
        try h.receive(iq: h.sessionInitiate().replacingOccurrences(of: " ufrag='Xy99' pwd='secretsecretsecretsecret'", with: ""))
        await eventually("the call to fail") { h.phase == .ended(.failed) }
    }

    @Test func aVideoCallRingsAndIsMarkedVideo() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose().replacingOccurrences(of: "media='audio'/>", with: "media='audio'/><description xmlns='urn:xmpp:jingle:apps:rtp:1' media='video'/>"))
        #expect(h.session.callState.value?.isVideo == true)
        #expect(h.session.callState.value?.isCameraOn == true)
        #expect(h.phase == .incoming)
    }

    @Test func aVideoCallProposesBothAndStartsTheMediaWithVideo() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice, video: true)
        let state = try #require(h.session.callState.value)
        #expect(state.isVideo)
        #expect(state.isCameraOn)
        await eventually("the propose") { h.sentSignals.contains { $0.action == "propose" } }
        let propose = try #require(h.wire.messages.first { $0.firstChild(name: "propose", xmlns: "urn:xmpp:jingle-message:0") != nil })
        let media = propose.firstChild(name: "propose")?.getChildren(name: "description").compactMap { $0.getAttribute("media") }
        #expect(media == ["audio", "video"])
        await eventually("the media to start") { h.factory.last?.startedWithVideo != nil }
        #expect(h.factory.last?.startedWithVideo == true)
    }

    @Test func anAudioCallStartsTheMediaWithoutVideo() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        #expect(h.session.callState.value?.isVideo == false)
        #expect(h.session.callState.value?.isCameraOn == false)
        await eventually("the media to start") { h.factory.last?.startedWithVideo != nil }
        #expect(h.factory.last?.startedWithVideo == false)
    }

    @Test func theCameraFollowsTheCallsSwitchesEvenBeforeTheMediaIsMade() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice, video: true)
        h.session.setCallCameraEnabled(false)
        #expect(h.session.callState.value?.isCameraOn == false)
        let sid = try #require(h.session.callState.value?.sid)
        let ready = await h.session.callMedia(sid: sid)
        let media = try #require(ready as? FakeCallMedia)
        await eventually("the camera to be told") { media.cameraEnabled == false }
        h.session.setCallCameraEnabled(true)
        #expect(h.session.callState.value?.isCameraOn == true)
        #expect(media.cameraEnabled == true)
        h.session.switchCallCamera()
        #expect(media.cameraSwitches == 1)
        #expect(await h.session.callMedia(sid: "other") == nil)
    }

    @Test func aVideoOnlyProposeIsRefusedAndLoggedAsMissed() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose(media: "video"))
        #expect(h.session.callState.value == nil)
        await eventually("the reject") { h.sentSignals.contains { $0.action == "reject" } }
        let reject = try #require(h.wire.messages.first { $0.firstChild(name: "reject", xmlns: "urn:xmpp:jingle-message:0") != nil })
        #expect(reject.to?.stringValue == aliceDevice)
        #expect(reject.firstChild(name: "reject")?.firstChild(name: "reason")?.firstChild(name: "unsupported-applications") != nil)
        await eventually("the missed call") { (try? h.rows().count) == 1 }
        let row = try #require(try h.rows().first)
        #expect(row.callOutcome == .missed)
        #expect(row.callIsVideo)
    }

    @Test func aRetractThatCrossedOurProceedEndsItAsMissed() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        h.session.answerCall()
        h.receive(h.jmi("retract"))
        #expect(h.phase == .ended(.missed))
        await eventually("the call to be recorded") { (try? h.rows().count) == 1 }
        #expect(try h.rows().first?.callOutcome == .missed)
    }

    @Test func theArchiveCopyOfACallInProgressAddsNoRow() async throws {
        let h = try CallSessionHarness()
        h.receive(h.propose())
        // A catch-up reads the propose back, however old it looks.
        h.receive(h.propose(), source: .archive(serverId: "a1", timestamp: Date().addingTimeInterval(-3600)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.rows().isEmpty)
        #expect(h.phase == .incoming)
    }
}

struct CallSessionHistoryTests {
    @Test func aSessionWithoutMediaOnlyKeepsTheLog() async throws {
        let h = try CallSessionHarness(withMedia: false)
        h.receive(h.propose())
        h.receive(h.jmi("retract"))
        #expect(h.session.callState.value == nil)
        #expect(h.sentSignals.isEmpty)
        #expect(try h.rows().first?.callOutcome == .missed)
    }

    @Test func aSessionWithoutMediaOffersNoCalls() throws {
        let h = try CallSessionHarness(withMedia: false)
        let features = h.session.client.modulesManager.availableFeatures
        // The app's session still has Jingle, for file transfers.
        #expect(!features.contains("urn:xmpp:jingle-message:0"))
        #expect(!features.contains("urn:xmpp:jingle:apps:rtp:audio"))
        #expect(!features.contains("urn:xmpp:jingle:transports:ice-udp:1"))
        #expect(!h.session.canCall(alice))
    }

    @Test func aSessionWithMediaOffersAudioCalls() throws {
        let h = try CallSessionHarness()
        let features = h.session.client.modulesManager.availableFeatures
        for feature in [
            "urn:xmpp:jingle:1", "urn:xmpp:jingle-message:0", "urn:xmpp:jingle:apps:rtp:1", "urn:xmpp:jingle:apps:rtp:audio",
            "urn:xmpp:jingle:transports:ice-udp:1", "urn:xmpp:jingle:apps:dtls:0",
        ] {
            #expect(features.contains(feature), "\(feature)")
        }
        #expect(features.contains("urn:xmpp:jingle:apps:rtp:video"))
        #expect(!XMPPSession.messageFeatures.contains("urn:xmpp:jingle-message:0"))
    }

    @Test func aCarbonOfACallFromAnotherDeviceMakesARow() async throws {
        let h = try CallSessionHarness()
        // Our tablet called alice five minutes ago and gave up, past the ring window.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        let delay = "<delay xmlns='urn:xmpp:delay' from='example.org' stamp='\(old)'/>"
        h.receive("<message from='me@example.org/tablet' to='alice@example.org' type='chat' id='p'><propose xmlns='urn:xmpp:jingle-message:0' id='t1'><description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/></propose>\(delay)</message>", source: .carbon(sent: true))
        #expect(h.session.callState.value == nil)
        let row = try #require(try h.rows().first)
        #expect(row.direction == .outgoing)
        #expect(row.callOutcome == .cancelled)
    }

    @Test func archiveCopiesBuildTheRowsWithoutRinging() throws {
        let h = try CallSessionHarness()
        let at = Date().addingTimeInterval(-7200)
        h.receive(h.propose(sid: "a1"), source: .archive(serverId: "s1", timestamp: at))
        h.receive(h.jmi("retract", sid: "a1"), source: .archive(serverId: "s2", timestamp: at.addingTimeInterval(9)))
        // Held until the page ends.
        #expect(try h.rows().isEmpty)
        #expect(h.session.flushArchive())
        #expect(h.session.callState.value == nil)
        #expect(h.sentSignals.isEmpty)
        let rows = try h.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.callOutcome == .missed)
        #expect(abs((rows.first?.timestamp.timeIntervalSince(at) ?? 99)) < 0.01)
    }

    @Test func aPageOfArchivedSignalsIsStoredTogether() throws {
        let h = try CallSessionHarness()
        let at = Date().addingTimeInterval(-7200)
        func archived(_ xml: String, _ id: String, _ offset: TimeInterval) {
            h.receive(xml, source: .archive(serverId: id, timestamp: at.addingTimeInterval(offset)))
        }
        // One call answered and finished, one missed.
        archived(h.propose(sid: "a1"), "1", 0)
        archived(h.jmi("proceed", sid: "a1", from: "me@example.org/tablet", to: aliceDevice), "2", 5)
        archived(h.jmi("finish", sid: "a1", inner: "<reason xmlns='urn:xmpp:jingle:1'><success/></reason>"), "3", 65)
        archived(h.propose(sid: "a2"), "4", 100)
        #expect(try h.rows().isEmpty)

        var changes = 0
        let observation = ValueObservation.tracking { try YapnestKit.Message.filter(Column("callOutcome") != nil).fetchCount($0) }
        let cancellable = observation.publisher(in: h.database.reader).sink(receiveCompletion: { _ in }, receiveValue: { _ in changes += 1 })
        defer { cancellable.cancel() }
        #expect(h.session.flushArchive())

        let rows = try h.rows()
        #expect(rows.map(\.remoteId) == ["a1", "a2"])
        #expect(rows.map(\.callOutcome) == [.answered, .missed])
        #expect(abs((rows.first?.callDuration ?? 0) - 60) < 0.01)
        // The count before, and once for the whole page.
        #expect(changes <= 2)
        // Nothing is left to store.
        #expect(h.session.flushArchive())
        #expect(try h.rows().count == 2)
    }

    @Test func aReadableMessageStillGoesThroughTheNormalPath() throws {
        let h = try CallSessionHarness()
        h.receive("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='m1'><body>hello</body></message>")
        let bodies = try h.database.reader.read { try YapnestKit.Message.fetchAll($0).map(\.body) }
        #expect(bodies == ["hello"])
    }
}

struct CallCapabilitiesTests {
    @Test func aContactCanBeCalledWhenADeviceAdvertisesBothFeatures() throws {
        let h = try CallSessionHarness()
        #expect(!h.session.canCall(alice))
        let caps = try #require(h.session.client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER))
        let presence = Presence()
        presence.from = Martin.JID(aliceDevice)
        presence.addChild(Element(name: "c", attributes: ["xmlns": "http://jabber.org/protocol/caps", "hash": "sha-1", "node": "https://example.org/client", "ver": "abc"]))
        let presenceModule = h.session.client.module(.presence)
        presenceModule.store.update(presence: presence, for: h.session.client)
        #expect(!h.session.canCall(alice))

        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: ["urn:xmpp:jingle-message:0", "urn:xmpp:jingle:apps:rtp:audio"])
        #expect(h.session.canCall(alice))

        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: ["urn:xmpp:jingle-message:0"])
        #expect(!h.session.canCall(alice))
    }

    @Test func callablePeersFollowPresenceAndCapabilities() async throws {
        let h = try CallSessionHarness()
        let caps = try #require(h.session.client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER))
        #expect(h.session.callablePeers.value.isEmpty)

        func arrive(_ type: String? = nil) {
            let presence = Presence()
            presence.from = Martin.JID(aliceDevice)
            if let type { presence.type = StanzaType(rawValue: type) } else {
                presence.addChild(Element(name: "c", attributes: ["xmlns": "http://jabber.org/protocol/caps", "hash": "sha-1", "node": "https://example.org/client", "ver": "abc"]))
            }
            h.session.client.module(.presence).store.update(presence: presence, for: h.session.client)
            h.session.presenceChanged(presence)
        }
        arrive()
        // Online, but what the device does isn't known yet.
        #expect(h.session.callablePeers.value.isEmpty)

        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: XMPPSession.callFeatures)
        await eventually("alice to be callable") { h.session.callablePeers.value == [alice] }

        arrive("unavailable")
        await eventually("alice to be no longer callable") { h.session.callablePeers.value.isEmpty }
    }

    @Test func aPeerWithoutRtpVideoIsCallableButNotForVideo() async throws {
        let h = try CallSessionHarness()
        let caps = try #require(h.session.client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER))
        let presence = Presence()
        presence.from = Martin.JID(aliceDevice)
        presence.addChild(Element(name: "c", attributes: ["xmlns": "http://jabber.org/protocol/caps", "hash": "sha-1", "node": "https://example.org/client", "ver": "abc"]))
        h.session.client.module(.presence).store.update(presence: presence, for: h.session.client)
        h.session.presenceChanged(presence)

        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: XMPPSession.callFeatures)
        await eventually("alice to be callable") { h.session.callablePeers.value == [alice] }
        #expect(h.session.videoCallablePeers.value.isEmpty)
        #expect(h.session.canCall(alice))
        #expect(!h.session.canCall(alice, video: true))

        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: XMPPSession.videoCallFeatures)
        h.session.updateCallablePeers()
        #expect(h.session.callablePeers.value == [alice])
        #expect(h.session.videoCallablePeers.value == [alice])
        #expect(h.session.canCall(alice, video: true))
    }

    /// Caps of many contacts land together after sign-in. Each store tells the
    /// session, which reads the cache, and must not wait behind the next store.
    @Test func manyCapsStoredTogetherStillMakeAContactCallable() async throws {
        let h = try CallSessionHarness()
        let caps = try #require(h.session.client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER))
        let presence = Presence()
        presence.from = Martin.JID(aliceDevice)
        presence.addChild(Element(name: "c", attributes: ["xmlns": "http://jabber.org/protocol/caps", "hash": "sha-1", "node": "https://example.org/client", "ver": "abc"]))
        h.session.client.module(.presence).store.update(presence: presence, for: h.session.client)
        h.session.presenceChanged(presence)

        for i in 0..<200 { caps.cache.store(node: "https://example.org/other#\(i)", identity: nil, features: []) }
        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: XMPPSession.callFeatures)
        for i in 200..<400 { caps.cache.store(node: "https://example.org/other#\(i)", identity: nil, features: []) }
        await eventually("alice to be callable") { h.session.callablePeers.value == [alice] }
    }

    @Test func aSessionWithoutMediaHasNoCallablePeers() async throws {
        let h = try CallSessionHarness(withMedia: false)
        let presence = Presence()
        presence.from = Martin.JID(aliceDevice)
        h.session.presenceChanged(presence)
        #expect(h.session.callablePeers.value.isEmpty)
    }

    @Test func theResourcesAreIntersected() {
        let a = Martin.JID("alice@example.org/a")!, b = Martin.JID("alice@example.org/b")!
        #expect(XMPPSession.supportsAll([.all, .all]))
        #expect(XMPPSession.supportsAll([.all, .some([a])]))
        #expect(XMPPSession.supportsAll([.some([a, b]), .some([b])]))
        #expect(!XMPPSession.supportsAll([.some([a]), .some([b])]))
        #expect(!XMPPSession.supportsAll([.all, .none]))
        #expect(!XMPPSession.supportsAll([.none, .some([a])]))
    }
}


struct IceServerCacheTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    private func server(_ n: Int) -> CallIceServer { CallIceServer(urls: ["stun:relay\(n).example.org:3478"]) }

    @Test func serversAreReusedUntilTheyExpireThenFound_again() async {
        let clock = Clock(), counter = Counter()
        let cache = IceServerCache()
        let discover: @Sendable () async -> IceServerCache.Discovered? = { [self] in
            IceServerCache.Discovered(servers: [server(counter.next())], expires: clock.now.addingTimeInterval(300))
        }
        let first = await cache.servers(now: { clock.now }, discover: discover)
        clock.advance(200)
        let second = await cache.servers(now: { clock.now }, discover: discover)
        #expect(first == second)
        #expect(counter.value == 1)
        // Less than the margin is left.
        clock.advance(80)
        let third = await cache.servers(now: { clock.now }, discover: discover)
        #expect(third != first)
        #expect(counter.value == 2)
    }

    @Test func serversWithoutAnExpiryAreKeptForTheDefaultLifetime() async {
        let clock = Clock(), counter = Counter()
        let cache = IceServerCache()
        let discover: @Sendable () async -> IceServerCache.Discovered? = { [self] in .init(servers: [server(counter.next())], expires: nil) }
        _ = await cache.servers(now: { clock.now }, discover: discover)
        clock.advance(IceServerCache.defaultLifetime - 1)
        _ = await cache.servers(now: { clock.now }, discover: discover)
        #expect(counter.value == 1)
        clock.advance(2)
        _ = await cache.servers(now: { clock.now }, discover: discover)
        #expect(counter.value == 2)
    }

    @Test func aFailureIsNotKept() async {
        let counter = Counter()
        let cache = IceServerCache()
        let discover: @Sendable () async -> IceServerCache.Discovered? = { _ = counter.next(); return nil }
        #expect(await cache.servers(discover: discover).isEmpty)
        #expect(await cache.servers(discover: discover).isEmpty)
        #expect(counter.value == 2)
    }

    @Test func askersMeanwhileShareTheDiscovery() async {
        let counter = Counter()
        let cache = IceServerCache()
        let discover: @Sendable () async -> IceServerCache.Discovered? = { [self] in
            let n = counter.next()
            try? await Task.sleep(for: .milliseconds(100))
            return .init(servers: [server(n)], expires: nil)
        }
        async let a = cache.servers(discover: discover)
        async let b = cache.servers(discover: discover)
        let (x, y) = await (a, b)
        #expect(x == y)
        #expect(counter.value == 1)
    }

    @Test func resettingForgetsTheServers() async {
        let counter = Counter()
        let cache = IceServerCache()
        let discover: @Sendable () async -> IceServerCache.Discovered? = { [self] in .init(servers: [server(counter.next())], expires: nil) }
        _ = await cache.servers(discover: discover)
        cache.reset()
        _ = await cache.servers(discover: discover)
        #expect(counter.value == 2)
    }
}
