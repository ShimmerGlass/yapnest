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
    public static func setSpeaker(_ on: Bool) throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.overrideOutputAudioPort(on ? .speaker : .none)
    }
}
#endif
