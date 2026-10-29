import Foundation
@preconcurrency import Martin

/// What an in-band bytestream stanza (XEP-0047) says.
enum IBBEvent: Sendable {
    case open(sid: String, blockSize: Int)
    case data(sid: String, seq: Int, bytes: Data)
    case close(sid: String)

    var sid: String {
        switch self {
        case .open(let sid, _), .data(let sid, _, _), .close(let sid): sid
        }
    }
}

/// Reads `<open>`, `<data>` and `<close>` of in-band bytestreams and hands
/// them to `handler`, which says whether they are for a stream we have by
/// throwing the error to answer with, and may return work to do once the
/// result has been written: the result must reach the sender before whatever
/// the data led to.
final class IBBModule: XmppModuleBase, AbstractIQModule, @unchecked Sendable {
    static let ID = JingleFile.ibb
    static let IDENTIFIER = XmppModuleIdentifier<IBBModule>()

    let criteria = Criteria.name("iq").add(Criteria.or(
        Criteria.name("open", xmlns: JingleFile.ibb),
        Criteria.name("data", xmlns: JingleFile.ibb),
        Criteria.name("close", xmlns: JingleFile.ibb),
    ))

    /// Advertised with the other file transfer features.
    var features: [String] { [] }

    /// Gets the sender's full address, which a stream is bound to.
    var handler: (@Sendable (Martin.JID, IBBEvent) throws -> (() -> Void)?)?

    func processGet(stanza: Stanza) throws {
        throw XMPPError.bad_request("An in-band bytestream is set up with a set.")
    }

    func processSet(stanza: Stanza) throws {
        guard let from = stanza.from, let handler else { throw XMPPError.item_not_found }
        let event = try Self.event(in: stanza)
        let after = try handler(from, event)
        write(stanza.makeResult(type: .result))
        after?()
    }

    static func event(in stanza: Stanza) throws -> IBBEvent {
        if let open = stanza.firstChild(name: "open", xmlns: JingleFile.ibb) {
            guard let sid = open.getAttribute("sid"), let size = open.getAttribute("block-size").flatMap(Int.init), size > 0 else {
                throw XMPPError.bad_request("Missing sid or block-size")
            }
            // Only the iq form is supported; the stanza that carries data in
            // messages would need a route of its own.
            guard (open.getAttribute("stanza") ?? "iq") == "iq" else { throw XMPPError.not_acceptable("Only data in iq stanzas is supported") }
            return .open(sid: sid, blockSize: size)
        }
        if let data = stanza.firstChild(name: "data", xmlns: JingleFile.ibb) {
            guard let sid = data.getAttribute("sid"), let seq = data.getAttribute("seq").flatMap(Int.init), (0...65535).contains(seq),
                  let bytes = Data(base64Encoded: data.value ?? "", options: .ignoreUnknownCharacters) else {
                throw XMPPError.bad_request("Bad data block")
            }
            return .data(sid: sid, seq: seq, bytes: bytes)
        }
        if let close = stanza.firstChild(name: "close", xmlns: JingleFile.ibb), let sid = close.getAttribute("sid") {
            return .close(sid: sid)
        }
        throw XMPPError.bad_request("Unknown in-band bytestream stanza")
    }

    // MARK: Stanzas we send

    static func open(to jid: Martin.JID, sid: String, blockSize: Int) -> Iq {
        Iq.set(to: jid, Element(name: "open", attributes: ["xmlns": JingleFile.ibb, "sid": sid, "block-size": String(blockSize), "stanza": "iq"]))
    }

    static func data(to jid: Martin.JID, sid: String, seq: Int, bytes: Data) -> Iq {
        Iq.set(to: jid, Element(name: "data", cdata: bytes.base64EncodedString(), attributes: ["xmlns": JingleFile.ibb, "sid": sid, "seq": String(seq)]))
    }

    static func close(to jid: Martin.JID, sid: String) -> Iq {
        Iq.set(to: jid, Element(name: "close", attributes: ["xmlns": JingleFile.ibb, "sid": sid]))
    }
}
