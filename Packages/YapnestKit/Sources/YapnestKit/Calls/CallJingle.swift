import Foundation
@preconcurrency import Martin

/// Turns what the media says (SDP) into Jingle (XEP-0167, XEP-0176, XEP-0320)
/// and back, through Martin's `SDP.swift`.
///
/// The Jingle half comes from other people's clients, so what goes into SDP is
/// checked first: Martin's conversion force-unwraps a payload's name and clock
/// rate, and writes every value into a line of the description, where a line
/// break would add lines of the sender's choosing.
enum CallJingle {
    static let descriptionFeatures = [CallSignal.rtp, "urn:xmpp:jingle:apps:rtp:audio", "urn:xmpp:jingle:apps:rtp:video"]
    static let transportFeatures = ["urn:xmpp:jingle:transports:ice-udp:1", "urn:xmpp:jingle:apps:dtls:0"]

    /// Most payload types an offer may list; WebRTC offers a dozen.
    static let maxPayloads = 32

    /// What the session negotiated: its contents, and which are bundled.
    struct Negotiation {
        var contents: [Jingle.Content]
        var bundle: [String]?
    }

    /// The media's offer or answer as Jingle. `creators` says who created each
    /// content when that is not us: the answerer's contents were created by the
    /// offerer.
    static func negotiation(fromSDP sdp: String, localRole: Jingle.Content.Creator, creators: [String: Jingle.Content.Creator] = [:]) -> Negotiation? {
        guard let (parsed, _) = SDP.parse(sdpString: crlf(sdp), creatorProvider: { creators[$0] ?? localRole }, localRole: localRole),
              !parsed.contents.isEmpty else { return nil }
        return Negotiation(contents: parsed.contents, bundle: parsed.bundle)
    }

    /// SDP for the media to set as the remote description, from the peer's
    /// Jingle. Only audio and video are kept. Nil if nothing usable is left.
    static func sdp(from negotiation: Negotiation, localRole: Jingle.Content.Creator) -> String? {
        let contents = negotiation.contents.compactMap(usable)
        guard !contents.isEmpty else { return nil }
        let names = Set(contents.map(\.name))
        let bundle = negotiation.bundle?.filter(names.contains)
        let text = SDP(contents: contents, bundle: bundle?.isEmpty == false ? bundle : nil)
            .toString(withSid: "1", localRole: localRole, direction: .incoming)
        // WebRTC wants whole numbers where Martin writes a timestamp.
        return text.components(separatedBy: "\r\n").map { $0.hasPrefix("o=") ? "o=- 1 2 IN IP4 0.0.0.0" : $0 }.joined(separator: "\r\n")
    }

    /// The content as WebRTC can take it, or nil if it can't be used.
    private static func usable(_ content: Jingle.Content) -> Jingle.Content? {
        guard let description = content.description as? Jingle.RTP.Description, description.media == "audio" || description.media == "video",
              let transport = content.transports.compactMap({ $0 as? Jingle.Transport.ICEUDPTransport }).first,
              transport.ufrag?.isEmpty == false, transport.pwd?.isEmpty == false,
              !description.payloads.isEmpty, !hasLineBreak(content.toElement()) else { return nil }
        let payloads = description.payloads.filter { $0.name?.isEmpty == false && $0.clockrate != nil }.prefix(maxPayloads)
        guard !payloads.isEmpty else { return nil }
        let cleaned = Jingle.RTP.Description(
            media: description.media, ssrc: description.ssrc, payloads: Array(payloads), bandwidth: description.bandwidth,
            encryption: description.encryption, rtcpMux: description.rtcpMux, ssrcs: description.ssrcs,
            ssrcGroups: description.ssrcGroups, hdrExts: description.hdrExts,
        )
        return Jingle.Content(name: content.name, creator: content.creator, senders: content.senders, description: cleaned, transports: [transport])
    }

    /// A local candidate as the `transport-info` content that trickles it.
    static func transportInfo(for candidate: CallCandidate, name: String, creator: Jingle.Content.Creator, ufrag: String?, pwd: String?) -> Jingle.Content? {
        let line = "a=" + candidate.sdp
        guard let parsed = Jingle.Transport.ICEUDPTransport.Candidate(fromSDP: line) else { return nil }
        let candidateUfrag = line.components(separatedBy: " ").drop { $0 != "ufrag" }.dropFirst().first
        let transport = Jingle.Transport.ICEUDPTransport(pwd: pwd, ufrag: candidateUfrag ?? ufrag, candidates: [parsed])
        return Jingle.Content(name: name, creator: creator, senders: nil, description: nil, transports: [transport])
    }

    /// The candidates a `transport-info` carries. `mids` are the contents' names
    /// in the order of the media's sections.
    static func candidates(in contents: [Jingle.Content], mids: [String]) -> [CallCandidate] {
        contents.filter { !hasLineBreak($0.toElement()) }.flatMap { content -> [CallCandidate] in
            let index = Int32(mids.firstIndex(of: content.name) ?? 0)
            return content.transports.compactMap { $0 as? Jingle.Transport.ICEUDPTransport }.flatMap(\.candidates).map { candidate in
                let line = candidate.toSDP()
                return CallCandidate(sdpMid: content.name, sdpMLineIndex: index, sdp: String(line.dropFirst(2)))
            }
        }
    }

    private static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static let lineBreaks = CharacterSet(charactersIn: "\r\n\0")

    private static func hasLineBreak(_ element: Element) -> Bool {
        if let value = element.value, value.rangeOfCharacter(from: lineBreaks) != nil { return true }
        for value in element.attributes.values where value.rangeOfCharacter(from: lineBreaks) != nil { return true }
        return element.children.contains(where: hasLineBreak)
    }
}
