import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let aliceDevice = "alice@example.org/phone"
private let alice = YapnestKit.JID("alice@example.org")!

/// Our fixes to Martin's Jingle and SDP code, pinned from the outside: a peer's
/// Jingle XML goes in through the session, and what the tests read is the SDP
/// WebRTC is given and the Jingle we send back. They name no Martin Jingle type,
/// so they hold for whichever Martin the package builds on. (`CallMartinTests`
/// drives the fork's own types.)
struct CallSDPRegressionTests {
    /// A session-initiate as a peer sends it. `payloads` and `transport` fill the audio content.
    private func initiate(
        groups: String = "<group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='audio'/></group>",
        payloads: String = "<payload-type id='111' name='opus' clockrate='48000' channels='2'/>",
        transport: String = "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89</fingerprint>",
    ) -> String {
        """
        <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='si'><jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='\(aliceDevice)' sid='s1'>\
        \(groups)\
        <content creator='initiator' name='audio' senders='both'>\
        <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>\(payloads)<rtcp-mux/></description>\
        <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Xy99' pwd='secretsecretsecretsecret'>\(transport)</transport>\
        </content></jingle></iq>
        """
    }

    /// An incoming call answered: the SDP the media was asked to answer, and the
    /// session-accept's `jingle` element we sent.
    private func answer(_ initiateXML: String, webRTCAnswer: String? = nil) async throws -> (offer: String, accept: Element) {
        let h = try CallSessionHarness()
        h.factory.answerOverride = webRTCAnswer
        h.receive(h.propose())
        h.session.answerCall()
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        try h.receive(iq: initiateXML)
        await eventually("the session-accept") { !h.jingleIqs("session-accept").isEmpty }
        let media = try #require(h.factory.last)
        let offer = try #require(media.answeredOffers.first)
        let accept = try #require(h.jingleIqs("session-accept").first?.firstChild(name: "jingle"))
        return (offer, accept)
    }

    private func lines(_ sdp: String) -> [String] { sdp.components(separatedBy: "\r\n") }

    /// WebRTC's answer to the offers above, with `extra` lines added to its audio section.
    private func webRTCAnswer(setup: String? = "active", extra: [String] = []) -> String {
        var sdp = [
            "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE audio",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 63", "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:FakeU", "a=ice-pwd:fakepasswordfakepassword12",
            "a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
        ]
        if let setup { sdp.append("a=setup:\(setup)") }
        sdp += ["a=mid:audio", "a=sendrecv", "a=rtcp-mux", "a=rtpmap:111 opus/48000/2", "a=rtpmap:63 red/48000/2"]
        sdp += extra
        sdp.append("")
        return sdp.joined(separator: "\r\n")
    }

    // MARK: fmtp

    @Test func aBareFmtpTokenFromThePeerStaysBare() async throws {
        // Chrome's RED: "a=fmtp:63 111/111". Conversations sends it as a parameter without a value.
        let (offer, _) = try await answer(initiate(payloads: """
        <payload-type id='111' name='opus' clockrate='48000' channels='2'/>\
        <payload-type id='63' name='red' clockrate='48000' channels='2'><parameter name='111/111'/></payload-type>
        """))
        #expect(lines(offer).contains("a=fmtp:63 111/111"))
        #expect(!offer.contains("111/111="))
    }

    @Test func anFmtpParameterWithAnEmptyValueIsWrittenAsTheBareToken() async throws {
        let (offer, _) = try await answer(initiate(payloads: """
        <payload-type id='111' name='opus' clockrate='48000' channels='2'><parameter name='minptime' value='10'/><parameter name='stereo' value=''/></payload-type>
        """))
        #expect(lines(offer).contains("a=fmtp:111 minptime=10;stereo"))
        #expect(!offer.contains("stereo="))
    }

    @Test func anFmtpValueWithEqualsSignsIsNotCutShort() async throws {
        let (offer, _) = try await answer(initiate(payloads: """
        <payload-type id='111' name='opus' clockrate='48000' channels='2'><parameter name='sprop' value='YWJj=='/><parameter name='useinbandfec' value='1'/></payload-type>
        """))
        #expect(lines(offer).contains("a=fmtp:111 sprop=YWJj==;useinbandfec=1"))
    }

    @Test func fmtpFromWebRTCGoesOutAsParametersWithAValueAttribute() async throws {
        // A bare token must reach the peer as value="" (XEP-0167 needs the attribute), and
        // a value containing "=" must keep everything after the first one.
        let (_, accept) = try await answer(
            initiate(),
            webRTCAnswer: webRTCAnswer(extra: ["a=fmtp:63 111/111", "a=fmtp:111 minptime=10;useinbandfec=1;sprop=YWJj=="]),
        )
        let description = try #require(accept.firstChild(name: "content")?.firstChild(name: "description"))
        let payloads = description.getChildren(name: "payload-type")
        let red = try #require(payloads.first { $0.getAttribute("id") == "63" })
        let redParameter = try #require(red.getChildren(name: "parameter").first)
        #expect(redParameter.getAttribute("name") == "111/111")
        #expect(redParameter.getAttribute("value") == "")
        let opus = try #require(payloads.first { $0.getAttribute("id") == "111" })
        let pairs = opus.getChildren(name: "parameter").map { ($0.getAttribute("name") ?? "?", $0.getAttribute("value") ?? "?") }
        #expect(pairs.map(\.0) == ["minptime", "useinbandfec", "sprop"])
        #expect(pairs.map(\.1) == ["10", "1", "YWJj=="])
    }

    // MARK: candidates

    @Test func aCandidateWithoutAGenerationInTheInitiateReachesWebRTC() async throws {
        let (offer, _) = try await answer(initiate(transport: """
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD</fingerprint>\
        <candidate component='1' foundation='1' id='c1' ip='192.0.2.9' network='0' port='50000' priority='2122260223' protocol='udp' type='host'/>
        """))
        let candidate = try #require(lines(offer).first { $0.hasPrefix("a=candidate:") })
        #expect(candidate.contains("192.0.2.9 50000 typ host"))
    }

    @Test func aTrickledCandidateWithoutAGenerationIsSentAndReceived() async throws {
        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let media = try #require(h.factory.last)

        // As libwebrtc trickles it: no "generation".
        media.emit(.candidate(CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1467250027 1 udp 2122260223 10.0.0.2 40000 typ host")))
        await eventually("the transport-info") { !h.jingleIqs("transport-info").isEmpty }
        let sent = try #require(h.jingleIqs("transport-info").first?.firstChild(name: "jingle")?.firstChild(name: "content")?.firstChild(name: "transport")?.firstChild(name: "candidate"))
        #expect(sent.getAttribute("ip") == "10.0.0.2")
        #expect(sent.getAttribute("generation") == "0")

        try h.receive(iq: h.sessionAccept(sid: sid))
        try h.receive(iq: """
        <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='t'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
        <content creator='initiator' name='0'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Yy11' pwd='anothersecretanothersecret'>\
        <candidate component='1' foundation='3' id='c' ip='198.51.100.7' network='0' port='4242' priority='1' protocol='udp' type='host'/>\
        </transport></content></jingle></iq>
        """)
        await eventually("the candidate to reach the media") { media.remoteCandidates.count == 1 }
        #expect(media.remoteCandidates.first?.sdp.contains("198.51.100.7 4242 typ host") == true)
    }

    @Test func aTextFoundationIsKeptInBothDirections() async throws {
        // pjnath's "Hc0a80001". The protocol is written in upper case, and SDP does not mind.
        let (offer, _) = try await answer(initiate(transport: """
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD</fingerprint>\
        <candidate component='1' foundation='Hc0a80001' generation='0' id='c1' ip='192.0.2.9' network='0' port='50000' priority='2122260223' protocol='udp' type='host'/>
        """))
        #expect(lines(offer).contains { $0.lowercased().hasPrefix("a=candidate:hc0a80001 1 udp 2122260223 192.0.2.9 50000 typ host") })

        let h = try CallSessionHarness()
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let media = try #require(h.factory.last)
        media.emit(.candidate(CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:Hc0a80001 1 udp 2122260223 10.0.0.2 40000 typ host generation 0")))
        await eventually("the transport-info") { !h.jingleIqs("transport-info").isEmpty }
        let sent = try #require(h.jingleIqs("transport-info").first?.firstChild(name: "jingle")?.firstChild(name: "content")?.firstChild(name: "transport")?.firstChild(name: "candidate"))
        #expect(sent.getAttribute("foundation") == "Hc0a80001")
    }

    @Test func aCandidateProtocolIsReadInAnyCase() async throws {
        // Dino and Monal differ on case; "ssltcp" is a token RFC 8445 allows.
        let (offer, _) = try await answer(initiate(transport: """
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD</fingerprint>\
        <candidate component='1' foundation='1' generation='0' id='c1' ip='192.0.2.1' network='0' port='1111' priority='3' protocol='UDP' type='host'/>\
        <candidate component='1' foundation='2' generation='0' id='c2' ip='192.0.2.2' network='0' port='2222' priority='2' protocol='ssltcp' type='host'/>
        """))
        let candidates = lines(offer).filter { $0.hasPrefix("a=candidate:") }
        #expect(candidates.count == 2)
        #expect(candidates.contains { $0.lowercased().hasPrefix("a=candidate:1 1 udp 3 192.0.2.1 1111 typ host") })
        #expect(candidates.contains { $0.lowercased().hasPrefix("a=candidate:2 1 ssltcp 2 192.0.2.2 2222 typ host") })
    }

    // MARK: DTLS setup

    @Test func aFingerprintWithoutASetupSurvivesAsActpass() async throws {
        for fingerprint in [
            "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256'>AB:CD:EF</fingerprint>",
            "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='bogus'>AB:CD:EF</fingerprint>",
        ] {
            let (offer, _) = try await answer(initiate(transport: fingerprint))
            #expect(lines(offer).contains("a=fingerprint:sha-256 AB:CD:EF"))
            #expect(lines(offer).contains("a=setup:actpass"))
        }
    }

    @Test func anAnswerWithoutASetupStillCarriesItsFingerprint() async throws {
        let (_, accept) = try await answer(initiate(), webRTCAnswer: webRTCAnswer(setup: nil))
        let fingerprint = try #require(accept.firstChild(name: "content")?.firstChild(name: "transport")?.firstChild(name: "fingerprint"))
        #expect(fingerprint.getAttribute("hash") == "sha-256")
        #expect(fingerprint.getAttribute("setup") == "actpass")
    }

    // MARK: BUNDLE

    @Test func theBundleGroupIsFoundAfterAnotherGroup() async throws {
        let (offer, accept) = try await answer(initiate(groups: """
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='LS'><content name='video'/><content name='other'/></group>\
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='audio'/></group>
        """))
        #expect(lines(offer).contains("a=group:BUNDLE audio"))
        #expect(!offer.contains("video"))
        let group = try #require(accept.getChildren(name: "group").first { $0.getAttribute("semantics") == "BUNDLE" })
        #expect(group.getChildren(name: "content").compactMap { $0.getAttribute("name") } == ["audio"])
    }

    // MARK: A realistic offer

    @Test func aConversationsOfferRoundTrips() async throws {
        let (offer, accept) = try await answer("""
        <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='si'><jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='\(aliceDevice)' sid='s1'>\
        <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='audio'/></group>\
        <content creator='initiator' name='audio' senders='both'>\
        <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>\
        <payload-type id='111' name='opus' clockrate='48000' channels='2'><parameter name='minptime' value='10'/><parameter name='useinbandfec' value='1'/><rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='transport-cc'/></payload-type>\
        <payload-type id='63' name='red' clockrate='48000' channels='2'><parameter name='111/111'/></payload-type>\
        <payload-type id='0' name='PCMU' clockrate='8000'/>\
        <rtcp-mux/><rtp-hdrext xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0' id='1' uri='urn:ietf:params:rtp-hdrext:ssrc-audio-level'/>\
        </description>\
        <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Xy99' pwd='secretsecretsecretsecret'>\
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89</fingerprint>\
        <candidate component='1' foundation='1' generation='0' id='c1' ip='192.168.1.5' network='0' port='50000' priority='2122260223' protocol='udp' type='host'/>\
        <candidate component='1' foundation='Hc0a80001' id='c2' ip='203.0.113.5' network='0' port='50001' priority='1686052607' protocol='udp' type='srflx' rel-addr='192.168.1.5' rel-port='50000'/>\
        </transport></content></jingle></iq>
        """, webRTCAnswer: webRTCAnswer(extra: ["a=fmtp:63 111/111", "a=fmtp:111 minptime=10;useinbandfec=1"]))
        let sdp = lines(offer)
        for expected in [
            "a=group:BUNDLE audio", "a=ice-ufrag:Xy99", "a=ice-pwd:secretsecretsecretsecret", "a=setup:actpass",
            "a=fingerprint:sha-256 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89", "a=mid:audio", "a=rtcp-mux",
            "a=rtpmap:111 opus/48000/2", "a=rtpmap:63 red/48000/2", "a=rtpmap:0 PCMU/8000",
            "a=fmtp:111 minptime=10;useinbandfec=1", "a=fmtp:63 111/111", "a=rtcp-fb:111 transport-cc",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
        ] {
            #expect(sdp.contains(expected), "missing \(expected)")
        }
        #expect(sdp.first { $0.hasPrefix("m=audio") }?.contains("111 63 0") == true)
        #expect(sdp.contains { $0.lowercased().hasPrefix("a=candidate:1 1 udp 2122260223 192.168.1.5 50000 typ host") })
        #expect(sdp.contains { $0.lowercased().hasPrefix("a=candidate:hc0a80001 1 udp 1686052607 203.0.113.5 50001 typ srflx raddr 192.168.1.5 rport 50000") })

        let content = try #require(accept.firstChild(name: "content"))
        #expect(content.getAttribute("name") == "audio")
        #expect(content.firstChild(name: "transport")?.getAttribute("ufrag") == "FakeU")
        #expect(content.firstChild(name: "transport")?.firstChild(name: "fingerprint")?.getAttribute("setup") == "active")
        #expect(content.firstChild(name: "description")?.getChildren(name: "payload-type").compactMap { $0.getAttribute("id") } == ["111", "63"])
    }
}
