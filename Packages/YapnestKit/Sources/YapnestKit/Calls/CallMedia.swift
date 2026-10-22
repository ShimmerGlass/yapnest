import Foundation

/// A STUN or TURN server for a call, from the account's server (XEP-0215).
public struct CallIceServer: Sendable, Hashable {
    /// `stun:host:port` or `turn:host:port?transport=udp`.
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// One ICE candidate, as WebRTC writes it in SDP.
public struct CallCandidate: Sendable, Hashable {
    /// The `a=mid` of the media section it belongs to.
    public var sdpMid: String?
    public var sdpMLineIndex: Int32
    /// The `candidate:…` attribute, without the `a=`.
    public var sdp: String

    public init(sdpMid: String?, sdpMLineIndex: Int32, sdp: String) {
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.sdp = sdp
    }
}

public enum CallMediaState: String, Sendable, Hashable, CaseIterable, DiagEnum {
    case connecting
    case connected
    /// Lost for now; ICE may still recover it.
    case disconnected
    case failed
    case closed
}

public enum CallMediaEvent: Sendable, Hashable {
    /// A local candidate to trickle to the peer.
    case candidate(CallCandidate)
    case state(CallMediaState)
}

/// One call's media: microphone, codecs, ICE and DTLS-SRTP. Calls speak SDP
/// here, and the signalling turns it into Jingle, so the media engine knows
/// nothing of XMPP and the signalling is tested with a fake.
public protocol CallMedia: AnyObject, Sendable {
    /// Local candidates and connection changes, until `close()`.
    var events: AsyncStream<CallMediaEvent> { get }
    /// Sets up the connection and the local audio track, and a camera track
    /// if the call has video.
    func start(iceServers: [CallIceServer], video: Bool) async throws
    /// The caller's offer, set as the local description.
    func makeOffer() async throws -> String
    /// The callee's answer to `offer`, set as the local description.
    func answer(offer: String) async throws -> String
    /// The callee's answer, on the caller's side.
    func setAnswer(_ sdp: String) async throws
    func addRemoteCandidate(_ candidate: CallCandidate) async throws
    func setMuted(_ muted: Bool)
    /// Turns the camera on or off. Off also releases the camera.
    func setCameraEnabled(_ on: Bool)
    /// To the next camera, which on a phone is the other of front and back.
    func switchCamera()
    func close()
}

/// Makes the media for each call. The app passes the WebRTC one; sessions
/// without it (the extensions, most tests) don't offer calls.
public protocol CallMediaFactory: Sendable {
    func makeMedia() -> any CallMedia
}
