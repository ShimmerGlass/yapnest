import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// A Chrome-shaped audio offer: opus, BUNDLE, DTLS, rtcp-mux, extmap.
private let webRTCOffer = [
    "v=0",
    "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
    "s=-",
    "t=0 0",
    "a=group:BUNDLE 0",
    "a=extmap-allow-mixed",
    "a=msid-semantic: WMS stream1",
    "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 110 126",
    "c=IN IP4 0.0.0.0",
    "a=rtcp:9 IN IP4 0.0.0.0",
    "a=candidate:1467250027 1 udp 2122260223 192.168.0.196 46243 typ host generation 0 ufrag Ab12 network-id 1",
    "a=ice-ufrag:Ab12",
    "a=ice-pwd:asd88fgpdd777uzjYhagZg0123",
    "a=ice-options:trickle",
    "a=fingerprint:sha-256 7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08",
    "a=setup:actpass",
    "a=mid:0",
    "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
    "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
    "a=sendrecv",
    "a=msid:stream1 track1",
    "a=rtcp-mux",
    "a=rtpmap:111 opus/48000/2",
    "a=rtcp-fb:111 transport-cc",
    "a=fmtp:111 minptime=10;useinbandfec=1",
    "a=rtpmap:63 red/48000/2",
    "a=rtpmap:9 G722/8000",
    "a=rtpmap:0 PCMU/8000",
    "a=rtpmap:8 PCMA/8000",
    "a=rtpmap:110 telephone-event/48000",
    "a=rtpmap:126 telephone-event/8000",
    "a=ssrc:3735928559 cname:user1@host",
    "a=ssrc:3735928559 msid:stream1 track1",
    "",
].joined(separator: "\r\n")

/// The same with video: VP8 and its retransmission payload, as WebRTC offers it.
private let webRTCVideoOffer = webRTCOffer.replacingOccurrences(of: "a=group:BUNDLE 0", with: "a=group:BUNDLE 0 1") + [
    "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
    "c=IN IP4 0.0.0.0",
    "a=rtcp:9 IN IP4 0.0.0.0",
    "a=ice-ufrag:Ab12",
    "a=ice-pwd:asd88fgpdd777uzjYhagZg0123",
    "a=ice-options:trickle",
    "a=fingerprint:sha-256 7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08",
    "a=setup:actpass",
    "a=mid:1",
    "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
    "a=sendrecv",
    "a=msid:stream1 track2",
    "a=rtcp-mux",
    "a=rtcp-rsize",
    "a=rtpmap:96 VP8/90000",
    "a=rtcp-fb:96 goog-remb",
    "a=rtcp-fb:96 transport-cc",
    "a=rtcp-fb:96 ccm fir",
    "a=rtcp-fb:96 nack",
    "a=rtcp-fb:96 nack pli",
    "a=rtpmap:97 rtx/90000",
    "a=fmtp:97 apt=96",
    "a=ssrc-group:FID 1111 2222",
    "a=ssrc:1111 cname:user1@host",
    "a=ssrc:1111 msid:stream1 track2",
    "a=ssrc:2222 cname:user1@host",
    "a=ssrc:2222 msid:stream1 track2",
    "",
].joined(separator: "\r\n")

/// A session-initiate as Conversations sends it (XEP-0167, 0176, 0320).
private let conversationsInitiate = """
<iq from='alice@example.org/phone' to='me@example.org/tablet' type='set' id='i1'>
<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='alice@example.org/phone' sid='s1'>
<group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'><content name='audio'/></group>
<content creator='initiator' name='audio' senders='both'>
<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
<payload-type id='111' name='opus' clockrate='48000' channels='2'>
<parameter name='minptime' value='10'/><parameter name='useinbandfec' value='1'/>
<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='transport-cc'/>
</payload-type>
<payload-type id='0' name='PCMU' clockrate='8000'/>
<rtcp-mux/>
<rtp-hdrext xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0' id='1' uri='urn:ietf:params:rtp-hdrext:ssrc-audio-level'/>
</description>
<transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Xy99' pwd='secretsecretsecretsecret'>
<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89</fingerprint>
<candidate component='1' foundation='1' generation='0' id='c1' ip='192.168.1.5' network='0' port='50000' priority='2122260223' protocol='udp' type='host'/>
</transport>
</content>
</jingle>
</iq>
"""

private func negotiation(of iqXML: String) throws -> CallJingle.Negotiation {
    let iq: Iq = parseStanza(iqXML.replacingOccurrences(of: "\n", with: ""))
    let jingle = try #require(iq.firstChild(name: "jingle", xmlns: "urn:xmpp:jingle:1"))
    let contents = jingle.getChildren(name: "content").compactMap {
        Jingle.Content(from: $0, knownDescriptions: [Jingle.RTP.Description.self], knownTransports: [Jingle.Transport.ICEUDPTransport.self])
    }
    let bundle = jingle.firstChild(name: "group", xmlns: "urn:xmpp:jingle:apps:grouping:0")?.children.compactMap { $0.getAttribute("name") }
    return CallJingle.Negotiation(contents: contents, bundle: bundle)
}

struct CallJingleTests {
    @Test func aWebRTCOfferBecomesJingle() throws {
        let negotiation = try #require(CallJingle.negotiation(fromSDP: webRTCOffer, localRole: .initiator))
        #expect(negotiation.bundle == ["0"])
        let content = try #require(negotiation.contents.first)
        #expect(negotiation.contents.count == 1)
        #expect(content.name == "0")
        #expect(content.creator == .initiator)
        let description = try #require(content.description as? Jingle.RTP.Description)
        #expect(description.media == "audio")
        #expect(description.rtcpMux)
        let opus = try #require(description.payloads.first)
        #expect(opus.id == 111)
        #expect(opus.name == "opus")
        #expect(opus.clockrate == 48000)
        #expect(opus.channels == 2)
        #expect(opus.parameters?.map(\.name) == ["minptime", "useinbandfec"])
        #expect(opus.rtcpFeedbacks?.first?.type == "transport-cc")
        #expect(description.payloads.map(\.id) == [111, 63, 9, 0, 8, 110, 126])
        #expect(description.hdrExts.map(\.id) == ["1", "2"])
        let transport = try #require(content.transports.first as? Jingle.Transport.ICEUDPTransport)
        #expect(transport.ufrag == "Ab12")
        #expect(transport.pwd == "asd88fgpdd777uzjYhagZg0123")
        #expect(transport.fingerprint?.hash == "sha-256")
        #expect(transport.fingerprint?.setup == .actpass)
        #expect(transport.candidates.count == 1)
        #expect(transport.candidates.first?.ip == "192.168.0.196")
    }

    @Test func theOfferSurvivesTheTripThroughJingleAndBack() throws {
        let negotiation = try #require(CallJingle.negotiation(fromSDP: webRTCOffer, localRole: .initiator))
        let sdp = try #require(CallJingle.sdp(from: negotiation, localRole: .responder))
        let lines = Set(sdp.components(separatedBy: "\r\n"))
        for expected in [
            "a=group:BUNDLE 0", "a=mid:0", "a=ice-ufrag:Ab12", "a=ice-pwd:asd88fgpdd777uzjYhagZg0123", "a=setup:actpass",
            "a=fingerprint:sha-256 7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08",
            "a=rtcp-mux", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1", "a=rtcp-fb:111 transport-cc",
            "a=rtpmap:0 PCMU/8000", "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level", "a=sendrecv",
            "a=candidate:1467250027 1 UDP 2122260223 192.168.0.196 46243 typ host generation 0",
        ] {
            #expect(lines.contains(expected), "\(expected)")
        }
        #expect(sdp.contains("m=audio 1 RTP/SAVPF 111 63 9 0 8 110 126\r\n"))
        // The origin is whole numbers, which WebRTC needs.
        #expect(lines.contains("o=- 1 2 IN IP4 0.0.0.0"))
        // And parsing it again gives the same contents.
        let again = try #require(CallJingle.negotiation(fromSDP: sdp, localRole: .initiator))
        #expect(again.bundle == negotiation.bundle)
        #expect(again.contents.map(\.name) == negotiation.contents.map(\.name))
        let first = try #require(negotiation.contents.first?.description as? Jingle.RTP.Description)
        let second = try #require(again.contents.first?.description as? Jingle.RTP.Description)
        #expect(first.payloads.map(\.id) == second.payloads.map(\.id))
        #expect(first.payloads.map(\.name) == second.payloads.map(\.name))
    }

    @Test func theJingleElementKeepsItsShape() throws {
        let negotiation = try #require(CallJingle.negotiation(fromSDP: webRTCOffer, localRole: .initiator))
        let element = try #require(negotiation.contents.first).toElement()
        #expect(element.getAttribute("creator") == "initiator")
        #expect(element.getAttribute("name") == "0")
        #expect(element.firstChild(name: "description", xmlns: "urn:xmpp:jingle:apps:rtp:1")?.getAttribute("media") == "audio")
        let transport = try #require(element.firstChild(name: "transport", xmlns: "urn:xmpp:jingle:transports:ice-udp:1"))
        #expect(transport.getAttribute("ufrag") == "Ab12")
        let fingerprint = try #require(transport.firstChild(name: "fingerprint", xmlns: "urn:xmpp:jingle:apps:dtls:0"))
        #expect(fingerprint.getAttribute("setup") == "actpass")
        #expect(fingerprint.getAttribute("hash") == "sha-256")
    }

    @Test func aConversationsSessionInitiateBecomesAnOffer() throws {
        let initiate = try negotiation(of: conversationsInitiate)
        #expect(initiate.contents.count == 1)
        #expect(initiate.bundle == ["audio"])
        let sdp = try #require(CallJingle.sdp(from: initiate, localRole: .responder))
        let lines = Set(sdp.components(separatedBy: "\r\n"))
        for expected in [
            "a=group:BUNDLE audio", "a=mid:audio", "a=ice-ufrag:Xy99", "a=ice-pwd:secretsecretsecretsecret", "a=setup:actpass",
            "a=rtcp-mux", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1", "a=rtcp-fb:111 transport-cc",
            "a=rtpmap:0 PCMU/8000", "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
            "a=candidate:1 1 UDP 2122260223 192.168.1.5 50000 typ host generation 0", "a=sendrecv",
        ] {
            #expect(lines.contains(expected), "\(expected)")
        }
        #expect(sdp.hasPrefix("v=0\r\n"))
        #expect(sdp.hasSuffix("\r\n"))
    }

    @Test func theAnswerBecomesJingleWithTheOffersCreator() throws {
        let offer = try negotiation(of: conversationsInitiate)
        var answerSDP = webRTCOffer.replacingOccurrences(of: "a=setup:actpass", with: "a=setup:active")
        answerSDP = answerSDP.replacingOccurrences(of: "a=mid:0", with: "a=mid:audio").replacingOccurrences(of: "BUNDLE 0", with: "BUNDLE audio")
        let creators = Dictionary(uniqueKeysWithValues: offer.contents.map { ($0.name, $0.creator) })
        let answer = try #require(CallJingle.negotiation(fromSDP: answerSDP, localRole: .responder, creators: creators))
        let content = try #require(answer.contents.first)
        #expect(content.creator == .initiator)
        #expect(content.senders == .both)
        #expect((content.transports.first as? Jingle.Transport.ICEUDPTransport)?.fingerprint?.setup == .active)
    }

    @Test func aVideoContentIsKeptAlongsideAudio() throws {
        var offer = try negotiation(of: conversationsInitiate)
        let videoContent = Jingle.Content(
            name: "video", creator: .initiator, senders: .both,
            description: Jingle.RTP.Description(media: "video", payloads: [.init(id: 96, name: "VP8", clockrate: 90000, parameters: nil, rtcpFeedbacks: nil)], rtcpMux: true, ssrcs: [], ssrcGroups: [], hdrExts: []),
            transports: offer.contents[0].transports,
        )
        offer = CallJingle.Negotiation(contents: offer.contents + [videoContent], bundle: ["audio", "video"])
        let sdp = try #require(CallJingle.sdp(from: offer, localRole: .responder))
        #expect(sdp.contains("m=audio"))
        #expect(sdp.contains("m=video"))
        #expect(sdp.contains("a=rtpmap:96 VP8/90000"))
        #expect(sdp.contains("a=group:BUNDLE audio video\r\n"))
        let onlyVideo = CallJingle.Negotiation(contents: [videoContent], bundle: ["video"])
        #expect(CallJingle.sdp(from: onlyVideo, localRole: .responder) != nil)
    }

    @Test func aContentThatIsNeitherAudioNorVideoIsLeftOut() throws {
        let offer = try negotiation(of: conversationsInitiate)
        let application = Jingle.Content(
            name: "data", creator: .initiator, senders: .both,
            description: Jingle.RTP.Description(media: "application", payloads: [.init(id: 96, name: "VP8", clockrate: 90000, parameters: nil, rtcpFeedbacks: nil)], rtcpMux: true, ssrcs: [], ssrcGroups: [], hdrExts: []),
            transports: offer.contents[0].transports,
        )
        let mixed = CallJingle.Negotiation(contents: offer.contents + [application], bundle: ["audio", "data"])
        let sdp = try #require(CallJingle.sdp(from: mixed, localRole: .responder))
        #expect(!sdp.contains("m=application"))
        #expect(sdp.contains("a=group:BUNDLE audio\r\n"))
        #expect(CallJingle.sdp(from: CallJingle.Negotiation(contents: [application], bundle: nil), localRole: .responder) == nil)
    }

    @Test func aVideoOfferSurvivesTheTripThroughJingleAndBack() throws {
        let negotiation = try #require(CallJingle.negotiation(fromSDP: webRTCVideoOffer, localRole: .initiator))
        #expect(negotiation.contents.compactMap { ($0.description as? Jingle.RTP.Description)?.media } == ["audio", "video"])
        #expect(negotiation.bundle == ["0", "1"])
        let sdp = try #require(CallJingle.sdp(from: negotiation, localRole: .responder))
        let mLines = sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("m=") }
        #expect(mLines.count == 2)
        #expect(mLines[0].hasPrefix("m=audio"))
        #expect(mLines[1].hasPrefix("m=video"))
        #expect(sdp.contains("a=rtpmap:96 VP8/90000"))
        #expect(sdp.contains("a=rtcp-fb:96 nack pli"))
        #expect(sdp.contains("a=group:BUNDLE 0 1"))
    }

    @Test func aPayloadWithoutANameOrClockRateIsDropped() throws {
        // Martin writes both with force unwraps.
        let xml = conversationsInitiate.replacingOccurrences(of: "<payload-type id='0' name='PCMU' clockrate='8000'/>", with: "<payload-type id='8'/>")
        let sdp = try #require(CallJingle.sdp(from: try negotiation(of: xml), localRole: .responder))
        #expect(!sdp.contains("m=audio 1 RTP/SAVPF 111 8"))
        #expect(sdp.contains("m=audio 1 RTP/SAVPF 111\r\n"))
    }

    @Test func aSessionWithoutIceCredentialsIsRefused() throws {
        let xml = conversationsInitiate.replacingOccurrences(of: " ufrag='Xy99' pwd='secretsecretsecretsecret'", with: "")
        #expect(CallJingle.sdp(from: try negotiation(of: xml), localRole: .responder) == nil)
    }

    @Test func aValueWithALineBreakCannotAddLinesToTheDescription() throws {
        let xml = conversationsInitiate.replacingOccurrences(of: "ufrag='Xy99'", with: "ufrag='Xy99&#10;a=ice-lite'")
        #expect(CallJingle.sdp(from: try negotiation(of: xml), localRole: .responder) == nil)
        let name = conversationsInitiate.replacingOccurrences(of: "name='opus'", with: "name='opus&#13;&#10;a=sendonly'")
        #expect(CallJingle.sdp(from: try negotiation(of: name), localRole: .responder) == nil)
    }

    @Test func aTrickledCandidateBecomesTransportInfo() throws {
        let candidate = CallCandidate(
            sdpMid: "0", sdpMLineIndex: 0,
            sdp: "candidate:842163049 1 udp 1677729535 203.0.113.9 52000 typ srflx raddr 192.168.0.196 rport 46243 generation 0 ufrag Ab12 network-id 1",
        )
        let content = try #require(CallJingle.transportInfo(for: candidate, name: "0", creator: .initiator, ufrag: "other", pwd: "pw"))
        #expect(content.name == "0")
        #expect(content.description == nil)
        let transport = try #require(content.transports.first as? Jingle.Transport.ICEUDPTransport)
        // The candidate's own ufrag wins; WebRTC states it.
        #expect(transport.ufrag == "Ab12")
        #expect(transport.pwd == "pw")
        let parsed = try #require(transport.candidates.first)
        #expect(parsed.type == .srflx)
        #expect(parsed.ip == "203.0.113.9")
        #expect(parsed.port == 52000)
        #expect(parsed.relAddr == "192.168.0.196")
        #expect(parsed.relPort == 46243)
        #expect(parsed.foundation == "842163049")
        let element = content.toElement()
        #expect(element.firstChild(name: "transport")?.firstChild(name: "candidate")?.getAttribute("type") == "srflx")
    }

    @Test func aCandidateWithoutAGenerationGetsOne() throws {
        let candidate = CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1 1 udp 2122260223 10.0.0.2 40000 typ host")
        let content = try #require(CallJingle.transportInfo(for: candidate, name: "0", creator: .initiator, ufrag: "u", pwd: "p"))
        #expect((content.transports.first as? Jingle.Transport.ICEUDPTransport)?.ufrag == "u")
        #expect((content.transports.first as? Jingle.Transport.ICEUDPTransport)?.candidates.count == 1)
    }

    @Test func aCandidateThatIsNotUsableIsDropped() {
        #expect(CallJingle.transportInfo(for: CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:garbage"), name: "0", creator: .initiator, ufrag: nil, pwd: nil) == nil)
    }

    @Test func aPeersTransportInfoBecomesCandidates() throws {
        let xml = """
        <iq from='alice@example.org/phone' type='set' id='t1'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='s1'>
        <content creator='initiator' name='audio'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Xy99' pwd='secretsecretsecretsecret'>
        <candidate component='1' foundation='2' generation='0' id='c2' ip='203.0.113.4' network='0' port='41000' priority='1677729535' protocol='udp' type='srflx' rel-addr='10.0.0.2' rel-port='50000'/>
        </transport></content></jingle></iq>
        """
        let contents = try negotiation(of: xml).contents
        let candidates = CallJingle.candidates(in: contents, mids: ["audio"])
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.sdpMid == "audio")
        #expect(candidate.sdpMLineIndex == 0)
        #expect(candidate.sdp == "candidate:2 1 UDP 1677729535 203.0.113.4 41000 typ srflx raddr 10.0.0.2 rport 50000 generation 0")
    }

    @Test func aCandidateWithALineBreakIsDropped() throws {
        let xml = """
        <iq from='alice@example.org/phone' type='set' id='t1'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='s1'>
        <content creator='initiator' name='audio'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
        <candidate component='1' foundation='2' generation='0' id='c2' ip='203.0.113.4&#10;a=x' network='0' port='41000' priority='1' protocol='udp' type='host'/>
        </transport></content></jingle></iq>
        """
        #expect(CallJingle.candidates(in: try negotiation(of: xml).contents, mids: ["audio"]).isEmpty)
    }
}

struct CallIceServerTests {
    private func parse(_ xml: String) -> [ExternalService] {
        let element = Element.from(string: xml.replacingOccurrences(of: "\n", with: ""))!
        return element.mapChildren(transform: ExternalServiceDiscoveryModule.Service.parse(_:)).map(ExternalService.init)
    }

    @Test func ejabberdsAnswerBecomesIceServers() {
        let services = parse("""
        <services xmlns='urn:xmpp:extdisco:2'>
        <service type='stun' host='203.0.113.1' port='3478' transport='udp'/>
        <service type='turn' host='203.0.113.1' port='3478' transport='udp' username='1700000000:alice' password='s3cret' restricted='1' expires='2099-01-01T00:00:00Z'/>
        <service type='turn' host='203.0.113.1' port='3478' transport='tcp' username='u' password='p'/>
        <service type='turns' host='turn.example.org' port='5349' transport='tcp' username='u' password='p'/>
        </services>
        """)
        let servers = CallIceServer.servers(from: services)
        #expect(servers == [
            CallIceServer(urls: ["stun:203.0.113.1:3478"]),
            CallIceServer(urls: ["turn:203.0.113.1:3478?transport=udp"], username: "1700000000:alice", credential: "s3cret"),
            CallIceServer(urls: ["turn:203.0.113.1:3478?transport=tcp"], username: "u", credential: "p"),
            CallIceServer(urls: ["turns:turn.example.org:5349?transport=tcp"], username: "u", credential: "p"),
        ])
    }

    @Test func defaultsFillInAMissingPort() {
        let servers = CallIceServer.servers(from: [
            ExternalService(type: "stun", host: "stun.example.org"),
            ExternalService(type: "turn", host: "turn.example.org", username: "u", password: "p"),
            ExternalService(type: "turns", host: "turn.example.org", username: "u", password: "p"),
        ])
        #expect(servers.map(\.urls) == [["stun:stun.example.org:3478"], ["turn:turn.example.org:3478?transport=udp"], ["turns:turn.example.org:5349?transport=tcp"]])
    }

    @Test func otherServicesAndExpiredCredentialsAreLeftOut() {
        let now = Date()
        let servers = CallIceServer.servers(from: [
            ExternalService(type: "ftp", host: "files.example.org"),
            ExternalService(type: "stuns", host: "stun.example.org"),
            ExternalService(type: "turn", host: "turn.example.org", username: "u", password: "p", expires: now.addingTimeInterval(-1)),
            ExternalService(type: "turn", host: "bad host", username: "u", password: "p"),
            ExternalService(type: "turn", host: "evil.example/?x", username: "u", password: "p"),
            ExternalService(type: "stun", host: ""),
        ], now: now)
        #expect(servers.isEmpty)
    }

    @Test func anIPv6HostIsBracketed() {
        let servers = CallIceServer.servers(from: [ExternalService(type: "stun", host: "2001:db8::1", port: 3478)])
        #expect(servers.first?.urls == ["stun:[2001:db8::1]:3478"])
    }
}
