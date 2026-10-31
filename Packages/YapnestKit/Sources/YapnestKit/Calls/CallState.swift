import Foundation

public enum CallError: Error, Sendable, Equatable {
    /// The session was made without media (the extensions').
    case unavailable
    case notConnected
    /// Another call is going on.
    case busy
    /// None of the peer's devices that are online take a call, with video if asked.
    case peerNotCallable(video: Bool)
}

extension CallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Calls aren't available here.")
        case .notConnected: String(localized: "You're offline.")
        case .busy: String(localized: "You're already in a call.")
        case .peerNotCallable(video: false): String(localized: "This contact can't take a call right now.")
        case .peerNotCallable(video: true): String(localized: "This contact can't take a video call right now.")
        }
    }
}

/// The current call, for the screen and CallKit to follow.
public struct CallState: Sendable, Equatable {
    public var sid: String
    public var peer: JID
    public var direction: Message.Direction
    public var phase: CallPhase
    /// When the call became active, for its timer.
    public var activeSince: Date?
    public var isMuted: Bool
    /// Our outgoing call has video, or the incoming one's propose asked for it.
    /// Fixed for the call: video isn't added or dropped once it is proposed.
    public var isVideo: Bool
    /// Whether the camera is sending. True for a video call until turned off.
    public var isCameraOn: Bool
    /// Whether one of the peer's OMEMO devices vouched for the call's media.
    /// Known once the Jingle session is up.
    public var verification: CallVerification

    public var isOver: Bool { phase.isEnded }

    /// For previews and tests: the session builds the real ones.
    public init(
        sid: String, peer: JID, direction: Message.Direction, phase: CallPhase, activeSince: Date? = nil,
        isMuted: Bool = false, isVideo: Bool = false, isCameraOn: Bool = false, verification: CallVerification = .unverified
    ) {
        self.verification = verification
        self.sid = sid
        self.peer = peer
        self.direction = direction
        self.phase = phase
        self.activeSince = activeSince
        self.isMuted = isMuted
        self.isVideo = isVideo
        self.isCameraOn = isCameraOn
    }

    init(_ machine: CallMachine, run: CallRun) {
        sid = machine.sid
        peer = machine.peer
        direction = machine.direction
        phase = machine.phase
        activeSince = machine.activeSince
        isVideo = machine.wantsVideo
        isCameraOn = machine.wantsVideo && run.isCameraOn
        isMuted = run.isMuted
        verification = run.verification
    }
}
