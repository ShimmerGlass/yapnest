import Foundation
@preconcurrency import Martin

/// Martin's Jingle module, with the session-terminate's reason kept: its
/// session manager isn't told one. It also sends file transfers (XEP-0234)
/// elsewhere before Martin sees them, since Martin parses a session's contents
/// only against the descriptions and transports registered, which are the
/// call's. `XMPPSession` reads Jingle Message
/// Initiation itself, since carbons and archive results never reach modules, so
/// the module's own handling is switched off: it would reject a propose it has
/// no description for, to the sender and to our other devices, whoever the
/// sender is.
final class CallJingleModule: JingleModule {
    /// Takes a Jingle iq of a file transfer: a session-initiate that offers a
    /// file, or any stanza of a session that is one. It answers the iq itself
    /// (or throws the error to answer with) and returns true, or returns false
    /// for an iq that is not for it, which goes the call's way.
    var fileTransfer: ((Iq, Element) throws -> Bool)?

    /// A session-terminate from `jid` for `sid`, with its reason. Returns
    /// whether it is for a call we have, which decides the reply.
    var terminated: ((Martin.JID, String, CallReason?) -> Bool)?

    /// Reads the fingerprints of a call's `session-initiate` or
    /// `session-accept` (`jingle`, in place, from `jid` for `sid`), with
    /// whether it is an initiate. Returns false if the call can't go on with
    /// them, which has been dealt with.
    var fingerprints: ((Martin.JID, String, Bool, Element) -> Bool)?

    override func process(message: Martin.Message) throws {}

    override func process(iq stanza: Iq) throws {
        guard stanza.type == .set, let jingle = stanza.firstChild(name: "jingle", xmlns: JingleModule.XMLNS) else {
            try super.process(iq: stanza)
            return
        }
        if try fileTransfer?(stanza, jingle) == true { return }
        // The fingerprints are put back in plain form before Martin reads the
        // contents. One that fails is answered, as the call ends over it.
        if let action = jingle.getAttribute("action"), action == "session-initiate" || action == "session-accept",
           let from = stanza.from, let sid = jingle.getAttribute("sid"),
           fingerprints?(from, sid, action == "session-initiate", jingle) == false {
            write(stanza.makeResult(type: .result))
            return
        }
        guard jingle.getAttribute("action") == "session-terminate" else {
            try super.process(iq: stanza)
            return
        }
        guard let from = stanza.from, let sid = jingle.getAttribute("sid") else { throw XMPPError.bad_request("Missing sid") }
        let reason = CallSignal.reason(in: jingle)
        guard terminated?(from, sid, reason) == true else { throw XMPPError.item_not_found }
        write(stanza.makeResult(type: .result))
    }
}

/// Hands the Jingle session's messages to the session, which asks the call.
/// File transfers never get here: `CallJingleModule` takes them first.
final class CallJingleBridge: JingleSessionManager, @unchecked Sendable {
    weak var session: XMPPSession?

    func sessionInitiated(for context: Context, with jid: Martin.JID, sid: String, contents: [Jingle.Content], bundle: [String]?) throws {
        guard session?.callSessionInitiated(from: jid, sid: sid, negotiation: .init(contents: contents, bundle: bundle)) == true else {
            throw XMPPError.item_not_found
        }
    }

    func sessionAccepted(for context: Context, with jid: Martin.JID, sid: String, contents: [Jingle.Content], bundle: [String]?) throws {
        guard session?.callSessionAccepted(from: jid, sid: sid, negotiation: .init(contents: contents, bundle: bundle)) == true else {
            throw XMPPError.item_not_found
        }
    }

    /// Handled by `CallJingleModule`, which knows the reason.
    func sessionTerminated(for context: Context, with jid: Martin.JID, sid: String) throws {}

    func transportInfo(for context: Context, with jid: Martin.JID, sid: String, contents: [Jingle.Content]) throws {
        guard session?.callTransportInfo(from: jid, sid: sid, contents: contents) == true else { throw XMPPError.item_not_found }
    }

    /// Read by `XMPPSession` from the message itself.
    func messageInitiation(for context: Context, from jid: Martin.JID, action: Jingle.MessageInitiationAction) throws {}

    /// Nothing is added or changed mid-call, video included.
    func contentModified(for context: Context, with jid: Martin.JID, sid: String, action: Jingle.ContentAction, contents: [Jingle.Content], bundle: [String]?) throws {
        throw XMPPError.feature_not_implemented
    }

    func sessionInfo(for context: Context, with jid: Martin.JID, sid: String, info: [Jingle.SessionInfo]) throws {}
}

extension CallJingleModule {
    /// Whose fingerprints to encrypt, and how.
    struct FingerprintEncryption {
        var peer: JID
        var device: Int32
        var cipher: CallFingerprintCipher
    }

    /// Sends a `session-initiate` or `session-accept`. Martin's own senders
    /// write the plain fingerprint, and the element is all there is to change,
    /// so this builds it the same way and has the fingerprints encrypted
    /// first (`CallFingerprints`). Throws the reason one couldn't be, with
    /// nothing sent, and the server's error if it refuses the stanza.
    func sendSession(
        initiating: Bool, to jid: Martin.JID, sid: String, contents: [Jingle.Content], bundle: [String]?, encryption: FingerprintEncryption?,
    ) async throws {
        guard let bound = context?.boundJid else { throw XMPPError.undefined_condition }
        let iq = Iq()
        iq.to = jid
        iq.type = .set
        let jingle = Element(name: "jingle", xmlns: JingleModule.XMLNS)
        jingle.setAttribute("action", value: initiating ? "session-initiate" : "session-accept")
        jingle.setAttribute("sid", value: sid)
        jingle.setAttribute(initiating ? "initiator" : "responder", value: bound.stringValue)
        iq.addChild(jingle)
        for content in contents { jingle.addChild(content.toElement()) }
        if let bundle {
            let group = Element(name: "group", xmlns: "urn:xmpp:jingle:apps:grouping:0")
            group.setAttribute("semantics", value: "BUNDLE")
            for name in bundle { group.addChild(Element(name: "content", attributes: ["name": name])) }
            jingle.addChild(group)
        }
        if let encryption, let failure = await CallFingerprints.encrypt(jingle, to: encryption.peer, device: encryption.device, with: encryption.cipher) {
            throw failure
        }
        try await write(iq: iq)
    }
}
