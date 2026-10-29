import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO

/// How far a call's media is vouched for. WebRTC always encrypts the media
/// (DTLS-SRTP), but the key exchange is checked against a fingerprint that
/// Jingle carries in the clear, so a server could swap it and sit in the
/// middle. A fingerprint that arrives OMEMO-encrypted from one of the peer's
/// devices can't be swapped, so the call is as trustworthy as that device.
public enum CallVerification: String, Sendable, Equatable, CaseIterable, DiagEnum {
    /// The peer sent the fingerprint in the clear, or from a device we haven't
    /// decided on: a server in the middle couldn't be told apart.
    case unverified
    /// Vouched for by a device we trust without having compared its keys.
    case trusted
    /// Vouched for by a device whose keys the user compared.
    case verified

    init(_ trust: OMEMODevice.Trust) {
        switch trust {
        case .verified: self = .verified
        case .trusted: self = .trusted
        case .undecided, .compromised: self = .unverified
        }
    }
}

/// Why a call's fingerprint couldn't be carried or read through OMEMO.
enum CallFingerprintError: String, Error, DiagEnum {
    /// We have no session with the device, or it isn't one of the peer's.
    case noSession
    case compromisedDevice
    /// It didn't decrypt, or didn't authenticate.
    case undecryptable
    /// The OMEMO element, or the contents it sits in, are not as expected.
    case malformed
    /// Another device than the one that took part in the call.
    case wrongDevice
    /// The call was verified so far and this message is not.
    case downgraded
    case setupFailed
}

/// The OMEMO half of a call, as the session uses it, so the signalling around
/// it can be tested without sessions between two real devices.
struct CallFingerprintCipher: Sendable {
    /// What a fingerprint's decryption shows: the text, and the device that
    /// sent it with how far we trust it.
    struct Opened: Sendable, Equatable {
        var fingerprint: String
        var device: Int32
        var trust: OMEMODevice.Trust
    }

    /// The `<encrypted>` element that carries `fingerprint` to `device` of `peer`.
    var encrypt: @Sendable (_ fingerprint: String, _ peer: JID, _ device: Int32) async -> Result<Element, CallFingerprintError>
    var decrypt: @Sendable (_ encrypted: Element, _ sender: JID) -> Result<Opened, CallFingerprintError>
}

/// The DTLS fingerprint of a call's media, carried through OMEMO as Conversations
/// and Dino do ("OMEMO verification" of RTP sessions, a draft of Daniel Gultsch's).
///
/// In `session-initiate` and `session-accept`, the `<fingerprint>` of each
/// content's ICE-UDP transport changes its namespace to
/// `http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification` (spelled so in
/// the draft), keeps its `hash` and `setup` attributes, and holds an
/// `<encrypted xmlns='eu.siacs.conversations.axolotl'>` instead of the text.
/// That is an OMEMO message of one key, for one device, whose payload is the
/// fingerprint. The caller's device is named in the callee's `<proceed>`,
/// by a `<device>` of the same namespace.
enum CallFingerprints {
    static let namespace = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification"
    static let dtlsNamespace = "urn:xmpp:jingle:apps:dtls:0"

    /// The ICE-UDP transport of each content in a Jingle element.
    static func transports(in jingle: Element) -> [Element] {
        jingle.getChildren(name: "content").compactMap { $0.firstChild(name: "transport", xmlns: Jingle.Transport.ICEUDPTransport.XMLNS) }
    }

    /// The `<device>` a `proceed` names.
    static func device(in proceed: Element) -> Int32? {
        proceed.firstChild(name: "device", xmlns: namespace)?.getAttribute("id").flatMap { Int32(omemoId: $0) }
    }

    /// Replaces each transport's plain fingerprint with its encrypted form.
    /// Returns why not if one can't be, with the element left half changed:
    /// it is not to be sent then.
    static func encrypt(_ jingle: Element, to peer: JID, device: Int32, with cipher: CallFingerprintCipher) async -> CallFingerprintError? {
        for transport in transports(in: jingle) {
            guard let plain = transport.firstChild(name: "fingerprint", xmlns: dtlsNamespace), let text = plain.value, !text.isEmpty else {
                return .malformed
            }
            switch await cipher.encrypt(text, peer, device) {
            case .failure(let error): return error
            case .success(let encrypted):
                let element = Element(name: "fingerprint", xmlns: namespace, children: [encrypted])
                copyFingerprintAttributes(from: plain, to: element)
                transport.removeChild(plain)
                transport.addChild(element)
            }
        }
        return nil
    }

    /// What `open` found in a Jingle element's fingerprints.
    enum Opened: Equatable {
        /// None was encrypted: the peer's fingerprints are plain.
        case plain
        /// All were, from one device. The plain fingerprints are in place.
        case encrypted(device: Int32, trust: OMEMODevice.Trust)
    }

    /// Decrypts every content's fingerprint and puts it back in plain form,
    /// where Martin and the media read it. Either every content's fingerprint
    /// is encrypted, or none is: a mix, or both forms in one transport, is a
    /// peer (or a server) trying to have one read as the other.
    static func open(_ jingle: Element, from sender: JID, with cipher: CallFingerprintCipher) -> Result<Opened, CallFingerprintError> {
        let transports = transports(in: jingle)
        let carrying = transports.filter { $0.firstChild(name: "fingerprint", xmlns: namespace) != nil }
        if carrying.isEmpty { return .success(.plain) }
        guard carrying.count == transports.count else { return .failure(.malformed) }
        var found: (device: Int32, trust: OMEMODevice.Trust)?
        for transport in transports {
            guard transport.firstChild(name: "fingerprint", xmlns: dtlsNamespace) == nil,
                  let wrapper = transport.firstChild(name: "fingerprint", xmlns: namespace),
                  transport.getChildren(name: "fingerprint", xmlns: namespace).count == 1,
                  let encrypted = singleEncrypted(in: wrapper) else { return .failure(.malformed) }
            switch cipher.decrypt(encrypted, sender) {
            case .failure(let error): return .failure(error)
            case .success(let opened):
                if let found, found.device != opened.device { return .failure(.wrongDevice) }
                found = (opened.device, opened.trust)
                let plain = Element(name: "fingerprint", cdata: opened.fingerprint, xmlns: dtlsNamespace)
                copyFingerprintAttributes(from: wrapper, to: plain)
                transport.removeChild(wrapper)
                transport.addChild(plain)
            }
        }
        guard let found else { return .failure(.malformed) }
        return .success(.encrypted(device: found.device, trust: found.trust))
    }

    private static func copyFingerprintAttributes(from source: Element, to target: Element) {
        for name in ["hash", "setup"] {
            if let value = source.getAttribute(name) { target.setAttribute(name, value: value) }
        }
    }

    private static func singleEncrypted(in wrapper: Element) -> Element? {
        let found = wrapper.getChildren(name: "encrypted", xmlns: NS.omemoLegacy)
        return found.count == 1 ? found[0] : nil
    }
}
