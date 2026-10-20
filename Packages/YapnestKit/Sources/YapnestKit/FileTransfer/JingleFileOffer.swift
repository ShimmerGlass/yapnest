import Foundation
@preconcurrency import Martin

/// Namespaces and limits of a Jingle file transfer (XEP-0234) over in-band
/// bytestreams (XEP-0261, XEP-0047).
enum JingleFile {
    static let jingle = JingleModule.XMLNS
    static let application = "urn:xmpp:jingle:apps:file-transfer:5"
    static let transport = "urn:xmpp:jingle:transports:ibb:1"
    static let ibb = "http://jabber.org/protocol/ibb"
    static let hashes = "urn:xmpp:hashes:2"
    static let sha256Name = "urn:xmpp:hash-function-text-names:sha-256"

    /// What a device must advertise to take or send a file this way.
    static let requiredFeatures = [application, transport]

    /// What we advertise.
    static let features = [application, transport, ibb, hashes, sha256Name]

    /// The largest block we send or accept in one `<data>`, before base64.
    static let blockSize = 8192

    /// A larger file is declined: it would take hours over a stanza stream.
    static let maxSize: Int64 = 1 << 30
}

/// A file offered over Jingle: the `<content>` of a session-initiate (and of
/// the accept that echoes it), built and read here without touching the
/// session.
struct JingleFileOffer: Equatable, Sendable {
    var name: String
    var mediaType: String?
    var size: Int64
    var date: Date?
    /// The SHA-256 of the file, if the sender gave it.
    var sha256: Data?
    var ibbSid: String
    /// The largest block the IBB stream may carry, before base64.
    var blockSize: Int

    static let contentName = "a-file-offer"

    /// Why an offer can't be taken, as the reason to end the session with.
    enum Rejection: Error, Equatable {
        case unsupportedApplications
        case unsupportedTransports
        case securityError
        case decline

        var reason: JingleSessionTerminateReason {
            switch self {
            case .unsupportedApplications: .unsupportedApplications
            case .unsupportedTransports: .unsupportedTransports
            case .securityError: .securityError
            case .decline: .decline
            }
        }
    }

    /// Whether `jingle` (a session-initiate's element) offers a file.
    static func isFileOffer(_ jingle: Element) -> Bool {
        jingle.filterChildren(name: "content", xmlns: nil).contains {
            $0.firstChild(name: "description", xmlns: JingleFile.application) != nil
        }
    }

    /// Reads the offer in a session-initiate. Only one content, from the
    /// initiator, over IBB and unencrypted, is taken.
    static func parse(_ jingle: Element) -> Result<JingleFileOffer, Rejection> {
        let contents = jingle.filterChildren(name: "content", xmlns: nil)
        guard contents.count == 1, let content = contents.first,
              let description = content.firstChild(name: "description", xmlns: JingleFile.application),
              content.getAttribute("senders") == "initiator" else { return .failure(.unsupportedApplications) }
        // Encrypted transfers (JET) need keys we don't have; taking one as
        // plain bytes would store ciphertext.
        guard content.firstChild(name: "security") == nil, description.firstChild(name: "security") == nil else {
            return .failure(.securityError)
        }
        guard let transport = content.firstChild(name: "transport", xmlns: JingleFile.transport),
              let sid = transport.getAttribute("sid"), !sid.isEmpty,
              let blockSize = transport.getAttribute("block-size").flatMap(Int.init), (1...65535).contains(blockSize)
        else { return .failure(.unsupportedTransports) }
        guard let file = description.firstChild(name: "file"),
              let size = file.firstChild(name: "size")?.value.flatMap(Int64.init), (0...JingleFile.maxSize).contains(size)
        else { return .failure(.decline) }
        let name = SafeFileName.make(file.firstChild(name: "name")?.value ?? "")
        let mediaType = file.firstChild(name: "media-type")?.value.flatMap { $0.isEmpty ? nil : $0 }
        let date = file.firstChild(name: "date")?.value.flatMap { try? Date($0, strategy: .iso8601) }
        let sha256 = file.filterChildren(name: "hash", xmlns: JingleFile.hashes)
            .first { $0.getAttribute("algo") == "sha-256" }
            .flatMap { hash($0) }
        return .success(JingleFileOffer(
            name: name, mediaType: mediaType, size: size, date: date, sha256: sha256,
            ibbSid: sid, blockSize: min(blockSize, JingleFile.blockSize),
        ))
    }

    /// The hash a session-info `<checksum>` gives later (XEP-0234).
    static func checksum(in jingle: Element) -> Data? {
        jingle.firstChild(name: "checksum", xmlns: JingleFile.application)?
            .firstChild(name: "file")?
            .filterChildren(name: "hash", xmlns: JingleFile.hashes)
            .first { $0.getAttribute("algo") == "sha-256" }
            .flatMap { hash($0) }
    }

    /// A SHA-256 is 32 bytes; anything else is not one.
    private static func hash(_ element: Element) -> Data? {
        element.value.flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0.count == 32 ? $0 : nil }
    }

    /// The `<content>` of the session-initiate, or, with `blockSize` negotiated,
    /// of the accept.
    func content() -> Element {
        let content = Element(name: "content", attributes: ["creator": "initiator", "name": Self.contentName, "senders": "initiator"])
        let description = Element(name: "description", xmlns: JingleFile.application)
        let file = Element(name: "file")
        if let date { file.addChild(Element(name: "date", cdata: date.formatted(.iso8601))) }
        if let mediaType { file.addChild(Element(name: "media-type", cdata: mediaType)) }
        file.addChild(Element(name: "name", cdata: name))
        file.addChild(Element(name: "size", cdata: String(size)))
        if let sha256 {
            file.addChild(Element(name: "hash", cdata: sha256.base64EncodedString(), attributes: ["xmlns": JingleFile.hashes, "algo": "sha-256"]))
        }
        description.addChild(file)
        content.addChild(description)
        content.addChild(Element(name: "transport", attributes: [
            "xmlns": JingleFile.transport, "block-size": String(blockSize), "sid": ibbSid,
        ]))
        return content
    }

    // MARK: Stanzas

    static func jingleIq(to jid: Martin.JID, action: String, sid: String, children: [Element] = []) -> Iq {
        let iq = Iq()
        iq.to = jid
        iq.type = .set
        let jingle = Element(name: "jingle", xmlns: JingleFile.jingle)
        jingle.setAttribute("action", value: action)
        jingle.setAttribute("sid", value: sid)
        for child in children { jingle.addChild(child) }
        iq.addChild(jingle)
        return iq
    }

    func sessionInitiate(to jid: Martin.JID, sid: String, initiator: Martin.JID) -> Iq {
        let iq = Self.jingleIq(to: jid, action: "session-initiate", sid: sid, children: [content()])
        iq.firstChild(name: "jingle")?.setAttribute("initiator", value: initiator.stringValue)
        return iq
    }

    func sessionAccept(to jid: Martin.JID, sid: String, responder: Martin.JID) -> Iq {
        let iq = Self.jingleIq(to: jid, action: "session-accept", sid: sid, children: [content()])
        iq.firstChild(name: "jingle")?.setAttribute("responder", value: responder.stringValue)
        return iq
    }

    static func sessionTerminate(to jid: Martin.JID, sid: String, reason: JingleSessionTerminateReason) -> Iq {
        jingleIq(to: jid, action: "session-terminate", sid: sid, children: [
            Element(name: "reason", children: [Element(name: reason.rawValue)]),
        ])
    }

    /// The reason in a session-terminate, if it names one we know.
    static func reason(in jingle: Element) -> JingleSessionTerminateReason? {
        jingle.firstChild(name: "reason")?.children.lazy.compactMap { JingleSessionTerminateReason(rawValue: $0.name) }.first
    }
}
