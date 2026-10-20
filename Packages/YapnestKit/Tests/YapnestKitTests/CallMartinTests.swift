import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// Fixes made in our fork of Martin's Jingle and extdisco code, driven through
/// the paths the calls use.
struct CallMartinTests {
    private func sdp(fmtp: [String]) -> String {
        [
            "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 63",
            "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:Ab12", "a=ice-pwd:asd88fgpdd777uzjYhagZg0123",
            "a=fingerprint:sha-256 7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35", "a=setup:actpass",
            "a=mid:0", "a=sendrecv", "a=rtcp-mux",
            "a=rtpmap:111 opus/48000/2",
            "a=rtpmap:63 red/48000/2",
        ].joined(separator: "\r\n") + "\r\n" + fmtp.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: JMI

    @Test func aProposeWeHaveNoDescriptionForIsNotRejectedByTheModule() throws {
        let h = try CallSessionHarness()
        let jingle = try #require(h.session.client.modulesManager.moduleOrNil(JingleModule.IDENTIFIER))
        let before = h.wire.written.count
        let message: Martin.Message = parseStanza("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='p'><propose xmlns='urn:xmpp:jingle-message:0' id='s9'><description xmlns='urn:example:other' media='audio'/></propose></message>")
        try jingle.process(stanza: message)
        #expect(h.wire.written.count == before)
    }

    // MARK: SDP

    @Test func fmtpParametersSurviveTheRoundTrip() throws {
        let original = sdp(fmtp: ["a=fmtp:63 111/111", "a=fmtp:111 minptime=10;useinbandfec=1;sprop=YWJj=="])
        let negotiation = try #require(CallJingle.negotiation(fromSDP: original, localRole: .initiator))
        let description = try #require(negotiation.contents.first?.description as? Jingle.RTP.Description)
        let red = try #require(description.payloads.first { $0.id == 63 })
        #expect(red.parameters?.map(\.name) == ["111/111"])
        let opus = try #require(description.payloads.first { $0.id == 111 })
        #expect(opus.parameters?.map(\.value) == ["10", "1", "YWJj=="])
        // Through the XML a peer sees, too.
        let element = try #require(negotiation.contents.first).toElement()
        let reparsed = try #require(Jingle.Content(from: element, knownDescriptions: [Jingle.RTP.Description.self], knownTransports: [Jingle.Transport.ICEUDPTransport.self]))
        let redParameter = try #require((reparsed.description as? Jingle.RTP.Description)?.payloads.first { $0.id == 63 }?.parameters?.first)
        #expect(redParameter.name == "111/111" && redParameter.value == "")
        let out = try #require(CallJingle.sdp(from: .init(contents: [reparsed], bundle: negotiation.bundle), localRole: .responder))
        let lines = out.components(separatedBy: "\r\n")
        #expect(lines.contains("a=fmtp:63 111/111"))
        #expect(lines.contains("a=fmtp:111 minptime=10;useinbandfec=1;sprop=YWJj=="))
    }

    @Test func aTrickledCandidateWithoutAGenerationParses() throws {
        let candidate = try #require(Jingle.Transport.ICEUDPTransport.Candidate(fromSDP: "a=candidate:1467250027 1 udp 2122260223 192.168.0.196 46243 typ host"))
        #expect(candidate.generation == 0)
        let content = try #require(CallJingle.transportInfo(for: CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1 1 udp 2122260223 192.168.0.196 46243 typ host"), name: "0", creator: .initiator, ufrag: "u", pwd: "p"))
        #expect((content.transports.first as? Jingle.Transport.ICEUDPTransport)?.candidates.count == 1)
    }

    // MARK: Jingle

    @Test func aCandidateProtocolIsReadInAnyCaseAndKeptWhenUnusual() throws {
        let upper = try #require(Jingle.Transport.ICEUDPTransport.Candidate(from: Element.from(string: "<candidate component='1' foundation='1' generation='0' ip='192.0.2.1' port='1' priority='1' protocol='UDP' type='host'/>")!))
        #expect(upper.protocolType == "udp")
        #expect(upper.toSDP().contains(" UDP "))
        let odd = try #require(Jingle.Transport.ICEUDPTransport.Candidate(from: Element.from(string: "<candidate component='1' foundation='1' ip='192.0.2.1' port='1' priority='1' protocol='ssltcp' type='host'/>")!))
        #expect(odd.protocolType == "ssltcp")
        #expect(odd.generation == 0)
        let fromSDP = try #require(Jingle.Transport.ICEUDPTransport.Candidate(fromSDP: "a=candidate:1 1 SSLTCP 1 192.0.2.1 9 typ host"))
        #expect(fromSDP.toSDP().hasPrefix("a=candidate:1 1 SSLTCP 1 192.0.2.1 9 typ host"))
    }

    @Test func aFingerprintWithoutASetupDefaultsToActpass() throws {
        let el = Element.from(string: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256'>AB:CD</fingerprint>")
        #expect(Jingle.Transport.ICEUDPTransport.Fingerprint(from: el)?.setup == .actpass)
        let junk = Element.from(string: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='bogus'>AB:CD</fingerprint>")
        #expect(Jingle.Transport.ICEUDPTransport.Fingerprint(from: junk)?.setup == .actpass)

        let xml = """
        <iq from='alice@example.org/phone' to='me@example.org/tablet' type='set' id='i1'>
        <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='s1'>
        <content creator='initiator' name='audio' senders='both'>
        <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'><payload-type id='0' name='PCMU' clockrate='8000'/></description>
        <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Xy99' pwd='secretsecretsecretsecret'>
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256'>AB:CD:EF</fingerprint>
        </transport></content></jingle></iq>
        """.replacingOccurrences(of: "\n", with: "")
        let iq: Iq = parseStanza(xml)
        let content = try #require(iq.firstChild(name: "jingle")?.getChildren(name: "content").compactMap {
            Jingle.Content(from: $0, knownDescriptions: [Jingle.RTP.Description.self], knownTransports: [Jingle.Transport.ICEUDPTransport.self])
        }.first)
        let out = try #require(CallJingle.sdp(from: .init(contents: [content], bundle: nil), localRole: .responder))
        #expect(out.contains("a=fingerprint:sha-256 AB:CD:EF"))
        #expect(out.contains("a=setup:actpass"))
    }

    @Test func onlyABundleGroupNamesTheBundle() throws {
        let module = JingleModule(sessionManager: CallJingleBridge())
        let jingle = Element.from(string: """
        <jingle xmlns='urn:xmpp:jingle:1'>\
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='LS'><content name='audio'/><content name='video'/></group>\
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='audio'/></group></jingle>
        """)!
        #expect(module.bundle(from: jingle) == ["audio"])
        let none = Element.from(string: "<jingle xmlns='urn:xmpp:jingle:1'><group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='LS'><content name='audio'/></group></jingle>")!
        #expect(module.bundle(from: none) == nil)
    }

    // MARK: Extdisco

    @Test func extdiscoIsAvailableUntilTheServerSaysItIsNot() throws {
        let h = try CallSessionHarness()
        let module = try #require(h.session.client.modulesManager.moduleOrNil(ExternalServiceDiscoveryModule.IDENTIFIER))
        #expect(module.isAvailable)
        h.wire.answer { iq in
            iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil
                ? FakeWire.discoInfo(to: iq, category: "server", type: "im", features: ["urn:xmpp:mam:2"]) : FakeWire.result(to: iq)
        }
        h.session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
        #expect(!module.isAvailable)
    }

    // MARK: Foundations

    @Test func aNonNumericFoundationIsKeptThroughBothWays() throws {
        for foundation in ["Hc0a80001", "a+b/1"] {
            let xml = """
            <iq from='alice@example.org/phone' to='me@example.org/tablet' type='set' id='t1'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='s1'>\
            <content creator='initiator' name='audio'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Ab12' pwd='pw'>\
            <candidate component='1' foundation='\(foundation)' generation='0' id='c' ip='192.0.2.5' network='0' port='4000' priority='1' protocol='udp' type='host'/>\
            </transport></content></jingle></iq>
            """
            let iq: Iq = parseStanza(xml)
            let jingle = try #require(iq.firstChild(name: "jingle", xmlns: "urn:xmpp:jingle:1"))
            let contents = jingle.getChildren(name: "content").compactMap {
                Jingle.Content(from: $0, knownDescriptions: [Jingle.RTP.Description.self], knownTransports: [Jingle.Transport.ICEUDPTransport.self])
            }
            // Jingle to the SDP line WebRTC takes.
            let candidates = CallJingle.candidates(in: contents, mids: ["audio"])
            #expect(candidates.first?.sdp.hasPrefix("candidate:\(foundation) 1 UDP 1 192.0.2.5 4000 typ host") == true)
            // WebRTC's line to a transport-info, and its XML.
            let content = try #require(CallJingle.transportInfo(for: CallCandidate(sdpMid: "audio", sdpMLineIndex: 0, sdp: "candidate:\(foundation) 1 udp 1 192.0.2.5 4000 typ host"), name: "audio", creator: .initiator, ufrag: "u", pwd: "p"))
            let candidate = try #require((content.transports.first as? Jingle.Transport.ICEUDPTransport)?.candidates.first)
            #expect(candidate.foundation == foundation)
            #expect(content.toElement().firstChild(name: "transport")?.firstChild(name: "candidate")?.getAttribute("foundation") == foundation)
        }
    }

    // MARK: Relay credentials

    private func relayWire(_ h: CallSessionHarness, services: [[String: String]], credentials: @escaping @Sendable (Iq) -> Iq?, requests: Counter) {
        h.wire.answer { iq in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                return FakeWire.discoInfo(to: iq, category: "server", type: "im", features: ["urn:xmpp:extdisco:2"])
            }
            if iq.firstChild(name: "services", xmlns: "urn:xmpp:extdisco:2") != nil {
                let list = Element(name: "services", xmlns: "urn:xmpp:extdisco:2")
                for attributes in services { list.addChild(Element(name: "service", attributes: attributes)) }
                return FakeWire.result(to: iq, list)
            }
            if iq.firstChild(name: "credentials", xmlns: "urn:xmpp:extdisco:2") != nil {
                requests.increment()
                return credentials(iq)
            }
            return FakeWire.result(to: iq)
        }
        h.session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
    }

    private func credentialsResult(_ iq: Iq, host: String, user: String) -> Iq {
        let credentials = Element(name: "credentials", xmlns: "urn:xmpp:extdisco:2")
        credentials.addChild(Element(name: "service", attributes: ["type": "turn", "host": host, "username": user, "password": "pw-" + user]))
        return FakeWire.result(to: iq, credentials)
    }

    @Test func aRestrictedRelayGetsItsCredentialsAsked() async throws {
        let h = try CallSessionHarness()
        let requests = Counter()
        relayWire(h, services: [
            ["type": "stun", "host": "198.51.100.1", "port": "3478"],
            ["type": "turn", "host": "198.51.100.1", "port": "3478", "transport": "udp", "restricted": "true"],
        ], credentials: { iq in
            let service = iq.firstChild(name: "credentials")?.firstChild(name: "service")
            #expect(service?.getAttribute("host") == "198.51.100.1")
            #expect(service?.getAttribute("type") == "turn")
            #expect(service?.getAttribute("port") == "3478")
            return self.credentialsResult(iq, host: "198.51.100.1", user: "u1")
        }, requests: requests)
        try h.session.startCall(to: YapnestKit.JID("alice@example.org")!)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(requests.value == 1)
        #expect(h.factory.last?.iceServers == [
            CallIceServer(urls: ["stun:198.51.100.1:3478"]),
            CallIceServer(urls: ["turn:198.51.100.1:3478?transport=udp"], username: "u1", credential: "pw-u1"),
        ])
    }

    @Test func aRelayWhoseCredentialsFailAreDroppedAlone() async throws {
        let h = try CallSessionHarness()
        let requests = Counter()
        relayWire(h, services: [
            ["type": "turn", "host": "bad.example.org", "restricted": "1"],
            ["type": "turn", "host": "good.example.org", "restricted": "1"],
            ["type": "turn", "host": "inline.example.org", "restricted": "1", "username": "iu", "password": "ip"],
        ], credentials: { iq in
            iq.firstChild(name: "credentials")?.firstChild(name: "service")?.getAttribute("host") == "bad.example.org"
                ? FakeWire.error(to: iq, condition: "item-not-found") : self.credentialsResult(iq, host: "good.example.org", user: "g")
        }, requests: requests)
        try h.session.startCall(to: YapnestKit.JID("alice@example.org")!)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        // The one with credentials of its own needed no request.
        #expect(requests.value == 2)
        #expect(h.factory.last?.iceServers == [
            CallIceServer(urls: ["turn:good.example.org:3478?transport=udp"], username: "g", credential: "pw-g"),
            CallIceServer(urls: ["turn:inline.example.org:3478?transport=udp"], username: "iu", credential: "ip"),
        ])
    }

    @Test func relaysWithTheirOwnCredentialsAskForNone() async throws {
        let h = try CallSessionHarness()
        let requests = Counter()
        relayWire(h, services: [["type": "turn", "host": "198.51.100.1", "username": "u", "password": "p"]], credentials: { FakeWire.result(to: $0) }, requests: requests)
        try h.session.startCall(to: YapnestKit.JID("alice@example.org")!)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(requests.value == 0)
        #expect(h.factory.last?.iceServers?.count == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
