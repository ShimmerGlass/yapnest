import Foundation
import Martin

extension DiagEnum where Self: RawRepresentable, RawValue == String {
    public var description: String { rawValue }
}

// What Martin's connector reports, which is already enums and numbers.
extension SocketConnectorNetwork.EndpointKind: DiagEnum {}
extension SocketConnectorNetwork.AddressFamily: DiagEnum {}
extension SocketConnectorNetwork.FailureReason: DiagEnum {}
extension SocketConnectorNetwork.ErrorKind: DiagEnum {}

/// Which kind of port a connection used. The number itself says which server
/// software is behind it, so only whether it is the usual one is logged.
enum PortKind: String, DiagEnum {
    case standard, directTLS, custom

    init(_ port: Int) {
        switch port {
        case 5222: self = .standard
        case 5223, 443: self = .directTLS
        default: self = .custom
        }
    }
}

/// Why a message wasn't handed to the stream yet.
enum SendSkip: String, DiagEnum {
    case offline, routeNotReady, probation
}

/// Why a message was marked failed.
enum SendFailure: String, DiagEnum {
    case groupNotPrivate, encryption, tooLarge, serverClosedStream
}

/// Why OMEMO couldn't encrypt, without saying for whom.
enum EncryptFailure: String, DiagEnum {
    case unsupported, listWithheld, noTrustedDevices, setupFailed

    init(_ error: OMEMOEncryption.EncryptError) {
        switch error {
        case .unsupported: self = .unsupported
        case .listWithheld: self = .listWithheld
        case .noTrustedDevices: self = .noTrustedDevices
        case .setupFailed: self = .setupFailed
        }
    }
}

enum UploadPhase: String, DiagEnum {
    case prepare, service, slot, put, store
}

/// Which family of sign-in mechanism, without the server's list.
enum SaslKind: String, DiagEnum {
    case fast, scram, plain, other, none

    init(mechanism: String?) {
        guard let mechanism else {
            self = .none
            return
        }
        if mechanism.hasPrefix("HT-") { self = .fast }
        else if mechanism.hasPrefix("SCRAM-") { self = .scram }
        else if mechanism == "PLAIN" { self = .plain }
        else { self = .other }
    }
}

enum AuthFailure: String, DiagEnum {
    case notAuthorized, temporary, serverNotTrusted, mechanism, other

    init(_ error: Error) {
        switch error as? SaslError {
        case .not_authorized, .invalid_authzid: self = .notAuthorized
        case .temporary_auth_failure: self = .temporary
        case .server_not_trusted: self = .serverNotTrusted
        case .mechanism_too_weak, .invalid_mechanism: self = .mechanism
        default: self = .other
        }
    }
}

/// How the connection ended, as Martin reports it.
enum DisconnectKind: String, DiagEnum {
    case none, timeout, noRoute, certificate, startTLSNotOffered, xmlError, streamError, authentication

    init(_ reason: XMPPClient.State.DisconnectionReason) {
        switch reason {
        case .none: self = .none
        case .timeout: self = .timeout
        case .noRouteToServer: self = .noRoute
        case .sslCertError: self = .certificate
        case .xmlError(SocketConnectorNetwork.startTLSNotOffered): self = .startTLSNotOffered
        case .xmlError: self = .xmlError
        case .streamError: self = .streamError
        case .authenticationFailure: self = .authentication
        }
    }
}

/// The stream error conditions RFC 6120 defines; anything else is "other".
enum StreamCondition: String, DiagEnum {
    case badFormat = "bad-format", badNamespacePrefix = "bad-namespace-prefix", conflict
    case connectionTimeout = "connection-timeout", hostGone = "host-gone", hostUnknown = "host-unknown"
    case improperAddressing = "improper-addressing", internalServerError = "internal-server-error"
    case invalidFrom = "invalid-from", invalidNamespace = "invalid-namespace", invalidXml = "invalid-xml"
    case notAuthorized = "not-authorized", notWellFormed = "not-well-formed", policyViolation = "policy-violation"
    case remoteConnectionFailed = "remote-connection-failed", reset, resourceConstraint = "resource-constraint"
    case restrictedXml = "restricted-xml", seeOtherHost = "see-other-host", systemShutdown = "system-shutdown"
    case undefinedCondition = "undefined-condition", unsupportedEncoding = "unsupported-encoding"
    case unsupportedFeature = "unsupported-feature", unsupportedStanzaType = "unsupported-stanza-type"
    case unsupportedVersion = "unsupported-version", other

    init(name: String?) {
        self = name.flatMap(StreamCondition.init(rawValue:)) ?? .other
    }
}

/// What the session does about its failure.
enum FailureClass: String, DiagEnum {
    case none, transient, fatal
}

enum LivenessOutcome: String, DiagEnum {
    case answered, silent
}

/// Why the session dropped a connection itself.
enum AbortCause: String, DiagEnum {
    case watchdog, noAnswer, networkChanged, insecure
}

/// The kind of an ICE candidate, which says whether a call found a direct
/// path or only a relayed one.
public enum CallCandidateKind: String, DiagEnum {
    case host, srflx, prflx, relay, unknown

    public init(sdpType: String?) {
        self = sdpType.flatMap(CallCandidateKind.init(rawValue:)) ?? .unknown
    }
}

/// Where a call is, without the reason it ended (`CallEndKind` has that).
enum CallPhaseKind: String, DiagEnum {
    case proposing, ringing, incoming, accepted, connecting, active, ended

    init(_ phase: CallPhase) {
        switch phase {
        case .proposing: self = .proposing
        case .ringing: self = .ringing
        case .incoming: self = .incoming
        case .accepted: self = .accepted
        case .connecting: self = .connecting
        case .active: self = .active
        case .ended: self = .ended
        }
    }
}

/// A Jingle message of ours the peer refused.
enum CallRefusedAction: String, DiagEnum {
    case transportInfo, sessionTerminate
}

/// How looking for the server's relays ended.
enum RelayDiscoveryOutcome: String, DiagEnum {
    case found, none, unavailable, timedOut, failed
}
