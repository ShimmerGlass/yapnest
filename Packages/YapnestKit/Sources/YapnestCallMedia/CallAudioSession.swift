#if os(iOS)
import AVFoundation
@preconcurrency import WebRTC

/// What the app's CXProviderDelegate calls, or the app itself on a call
/// without CallKit. CallKit or the app activates and deactivates the audio
/// session, never WebRTC, so WebRTC is told rather than asked.
public enum CallAudioSession {
    /// Sets the category before the call starts; CallKit, or the app without it, activates it later.
    /// A video call defaults to the loudspeaker, as the phone is held away.
    public static func configure(video: Bool = false) throws {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try setCategory(session, video: video)
    }

    private static func setCategory(_ session: RTCAudioSession, video: Bool) throws {
        if video {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        } else {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        }
    }

    /// From `provider(_:didActivate:)`.
    public static func audioSessionDidActivate(_ audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidActivate(audioSession)
        session.isAudioEnabled = true
    }

    /// From `provider(_:didDeactivate:)`.
    public static func audioSessionDidDeactivate(_ audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.audioSessionDidDeactivate(audioSession)
    }

    /// Routes the call to the loudspeaker, or back to the earpiece or headset.
    /// Off leaves the video chat mode, as that mode's default route is the
    /// loudspeaker, so dropping the override alone would stay there. On brings
    /// it back for a video call, whose sound should return to the loudspeaker
    /// when a headset goes.
    public static func setSpeaker(_ on: Bool, video: Bool) throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let mode: AVAudioSession.Mode = on && video ? .videoChat : .voiceChat
        if session.mode != mode.rawValue { try setCategory(session, video: on && video) }
        try session.overrideOutputAudioPort(on ? .speaker : .none)
    }

    /// Whether the call is coming out of the loudspeaker now. A video call
    /// starts there unless a headset is connected, and one can be plugged in
    /// at any moment, so this is read from the route rather than remembered.
    public static var isOnSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }
}
#endif
