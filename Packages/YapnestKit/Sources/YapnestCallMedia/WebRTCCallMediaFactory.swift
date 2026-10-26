import Foundation
import YapnestKit
@preconcurrency import WebRTC

/// Makes the WebRTC media for each call, all on one peer connection factory:
/// creating one is slow and it owns the audio device.
public struct WebRTCCallMediaFactory: CallMediaFactory {
    private let forceRelay: Bool
    private let receiveOnly: Bool
    private let syntheticCamera: Bool

    public init() {
        self.init(forceRelay: false, receiveOnly: false)
    }

    /// For tests: `forceRelay` only offers TURN candidates, and `receiveOnly`
    /// leaves out the local audio track. WebRTC opens the microphone once
    /// something sends, and the macOS build can't take a stand-in audio device
    /// (its headers don't declare `RTCAudioDevice`), so a test avoids the
    /// permission prompt by never sending. ICE and DTLS run all the same.
    /// Video is left out by `receiveOnly` too, unless `syntheticCamera`
    /// sends a generated picture, which touches no camera.
    @_spi(Testing)
    public init(forceRelay: Bool, receiveOnly: Bool, syntheticCamera: Bool = false) {
        self.forceRelay = forceRelay
        self.receiveOnly = receiveOnly
        self.syntheticCamera = syntheticCamera
    }

    public func makeMedia() -> any CallMedia {
        makeMedia(relayOnly: false)
    }

    public func makeMedia(relayOnly: Bool) -> any CallMedia {
        WebRTCCallMedia(
            factory: SharedFactory.shared,
            forceRelay: forceRelay || relayOnly, receiveOnly: receiveOnly, syntheticCamera: syntheticCamera)
    }
}

enum SharedFactory {
    nonisolated(unsafe) static let shared: RTCPeerConnectionFactory = {
        #if targetEnvironment(macCatalyst)
        // The Mac's own audio device, as WebRTC's can't pick a microphone or
        // speaker there. It doesn't use AVAudioSession, so nothing is set up.
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioDevice: MacCallAudioDevice())
        #else
        #if os(iOS)
        // CallKit decides when the audio session is live.
        RTCAudioSession.sharedInstance().useManualAudio = true
        #endif
        return RTCPeerConnectionFactory()
        #endif
    }()

}
