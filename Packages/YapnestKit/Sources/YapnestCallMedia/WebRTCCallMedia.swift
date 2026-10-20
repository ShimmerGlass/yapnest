import Foundation
import os
import YapnestKit
@preconcurrency import WebRTC

public enum CallMediaError: Error {
    case notStarted
    case closed
    case negotiationFailed
}

/// Which of a video call's two pictures a renderer shows.
public enum CallVideoSide: Sendable {
    case local, remote
}

/// One call's audio, and video if it has any, over WebRTC: Unified Plan, a
/// sendrecv Opus transceiver and a sendrecv video one, ICE and DTLS-SRTP.
public final class WebRTCCallMedia: CallMedia, @unchecked Sendable {
    public let events: AsyncStream<CallMediaEvent>

    private let continuation: AsyncStream<CallMediaEvent>.Continuation
    private let factory: RTCPeerConnectionFactory
    private let forceRelay: Bool
    private let receiveOnly: Bool
    private let syntheticCamera: Bool
    private let observer: Observer
    // WebRTC calls its delegate on its own threads while the app calls in from
    // others, so everything below is read and written under the lock.
    private let lock = NSLock()
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var wantsVideo = false
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var capture: CallVideoCapture?
    private var localRenderers: [any RTCVideoRenderer] = []
    private var remoteRenderers: [any RTCVideoRenderer] = []
    // Not in `remoteRenderers`: it is ours, and stays on the track whoever else draws.
    private let firstFrameLog = FirstFrameLog()
    private var closed = false
    private var hasRemoteDescription = false
    private var queuedCandidates: [RTCIceCandidate] = []

    init(factory: RTCPeerConnectionFactory, forceRelay: Bool, receiveOnly: Bool, syntheticCamera: Bool) {
        self.factory = factory
        self.forceRelay = forceRelay
        self.receiveOnly = receiveOnly
        self.syntheticCamera = syntheticCamera
        let (events, continuation) = AsyncStream.makeStream(of: CallMediaEvent.self)
        self.events = events
        self.continuation = continuation
        observer = Observer(continuation: continuation)
        observer.remoteVideoTrack = { [weak self] in self?.adoptRemoteVideo($0) }
    }

    deinit {
        close()
    }

    public func start(iceServers: [CallIceServer], video: Bool) async throws {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceTransportPolicy = forceRelay ? .relay : .all
        configuration.iceServers = iceServers.map {
            if let username = $0.username, let credential = $0.credential {
                RTCIceServer(urlStrings: $0.urls, username: username, credential: credential)
            } else {
                RTCIceServer(urlStrings: $0.urls)
            }
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: configuration, constraints: constraints, delegate: observer)
        else { throw CallMediaError.negotiationFailed }

        let track: RTCAudioTrack? = receiveOnly
            ? nil : factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "audio0")
        // addTrack and not addTransceiver: only a track's transceiver is taken
        // up by the m-line of an offer we answer (JSEP 5.10). One added with
        // addTransceiver is passed over, the answer gets a receive-only one of
        // its own, and the caller never hears us.
        let added: Bool
        if let track {
            added = connection.add(track, streamIds: ["call"]) != nil
        } else {
            let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .recvOnly
            added = connection.addTransceiver(of: .audio, init: transceiverInit) != nil
        }
        // The same goes for video. A receive-only side, which never sends
        // audio, still sends a generated picture: that opens no device.
        var videoTrack: RTCVideoTrack?
        var capture: CallVideoCapture?
        var videoAdded = true
        if video {
            if receiveOnly && !syntheticCamera {
                let transceiverInit = RTCRtpTransceiverInit()
                transceiverInit.direction = .recvOnly
                videoAdded = connection.addTransceiver(of: .video, init: transceiverInit) != nil
            } else {
                let source = factory.videoSource()
                let created = factory.videoTrack(with: source, trackId: "video0")
                videoAdded = connection.add(created, streamIds: ["call"]) != nil
                videoTrack = created
                capture = CallVideoCapture(source: source, synthetic: syntheticCamera)
            }
        }
        guard added, videoAdded else {
            connection.close()
            throw CallMediaError.negotiationFailed
        }

        let stored = lock.withLock {
            if closed { return false }
            self.connection = connection
            audioTrack = track
            wantsVideo = video
            localVideoTrack = videoTrack
            self.capture = capture
            for renderer in localRenderers { videoTrack?.add(renderer) }
            return true
        }
        if !stored {
            connection.close()
            throw CallMediaError.closed
        }
        capture?.start()
    }

    public func makeOffer() async throws -> String {
        let connection = try currentConnection()
        let offer = try await connection.offer(for: offerConstraints)
        try await connection.setLocalDescription(offer)
        return offer.sdp
    }

    public func answer(offer: String) async throws -> String {
        let connection = try await setRemote(type: .offer, sdp: offer)
        let answer = try await connection.answer(for: offerConstraints)
        try await connection.setLocalDescription(answer)
        return answer.sdp
    }

    public func setAnswer(_ sdp: String) async throws {
        try await setRemote(type: .answer, sdp: sdp)
    }

    public func addRemoteCandidate(_ candidate: CallCandidate) async throws {
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        let ready: RTCPeerConnection? = try lock.withLock {
            guard !closed else { throw CallMediaError.closed }
            guard let connection else { throw CallMediaError.notStarted }
            if !hasRemoteDescription {
                // Trickled candidates can beat the SDP they belong to.
                queuedCandidates.append(rtcCandidate)
                return nil
            }
            return connection
        }
        try await ready?.add(rtcCandidate)
    }

    public func setMuted(_ muted: Bool) {
        lock.withLock { audioTrack?.isEnabled = !muted }
    }

    public func setCameraEnabled(_ on: Bool) {
        let capture = lock.withLock {
            localVideoTrack?.isEnabled = on
            return self.capture
        }
        // Stopping the capture, and not only muting the track, is what puts
        // the camera light out.
        if on { capture?.start() } else { capture?.stop() }
    }

    /// How many cameras can capture, for whether switching means anything.
    public static var cameraCount: Int { RTCCameraVideoCapturer.captureDevices().count }

    public func switchCamera() {
        lock.withLock { capture }?.switchCamera()
    }

    /// Draws a side's video into `renderer`, from now on and also if the
    /// track only arrives later (the remote one comes with the peer's answer).
    public func addRenderer(_ renderer: any RTCVideoRenderer, for side: CallVideoSide) {
        lock.withLock {
            switch side {
            case .local:
                localRenderers.append(renderer)
                localVideoTrack?.add(renderer)
            case .remote:
                remoteRenderers.append(renderer)
                remoteVideoTrack?.add(renderer)
            }
        }
    }

    public func removeRenderer(_ renderer: any RTCVideoRenderer, for side: CallVideoSide) {
        lock.withLock {
            switch side {
            case .local:
                localRenderers.removeAll { $0 === renderer }
                localVideoTrack?.remove(renderer)
            case .remote:
                remoteRenderers.removeAll { $0 === renderer }
                remoteVideoTrack?.remove(renderer)
            }
        }
    }

    private func adoptRemoteVideo(_ track: RTCVideoTrack) {
        lock.withLock {
            guard !closed, remoteVideoTrack !== track else { return }
            remoteVideoTrack?.remove(firstFrameLog)
            remoteVideoTrack = track
            track.add(firstFrameLog)
            for renderer in remoteRenderers { track.add(renderer) }
        }
    }

    public func close() {
        let (alreadyClosed, connection, capture) = lock.withLock {
            let state = (closed, self.connection, self.capture)
            closed = true
            self.connection = nil
            audioTrack = nil
            for renderer in localRenderers { localVideoTrack?.remove(renderer) }
            for renderer in remoteRenderers { remoteVideoTrack?.remove(renderer) }
            remoteVideoTrack?.remove(firstFrameLog)
            localVideoTrack = nil
            remoteVideoTrack = nil
            localRenderers = []
            remoteRenderers = []
            self.capture = nil
            queuedCandidates = []
            return state
        }
        guard !alreadyClosed else { return }
        capture?.stop()
        connection?.close()
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    private var offerConstraints: RTCMediaConstraints {
        let video = lock.withLock { wantsVideo }
        return RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: video ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil)
    }

    private func currentConnection() throws -> RTCPeerConnection {
        try lock.withLock {
            guard !closed else { throw CallMediaError.closed }
            guard let connection else { throw CallMediaError.notStarted }
            return connection
        }
    }

    @discardableResult
    private func setRemote(type: RTCSdpType, sdp: String) async throws -> RTCPeerConnection {
        let connection = try currentConnection()
        try await connection.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdp))
        try await remoteDescriptionWasSet(on: connection)
        return connection
    }

    private func remoteDescriptionWasSet(on connection: RTCPeerConnection) async throws {
        let queued = lock.withLock {
            hasRemoteDescription = true
            let queued = queuedCandidates
            queuedCandidates = []
            return queued
        }
        // Where the track is, if the delegate hasn't already told of it.
        for transceiver in connection.transceivers {
            if let track = transceiver.receiver.track as? RTCVideoTrack { adoptRemoteVideo(track) }
        }
        for candidate in queued {
            try await connection.add(candidate)
        }
    }
}

/// Logs the first picture the peer's video brings, once per call: it tells in
/// the field that video arrived, and not only that it was negotiated. WebRTC
/// renders on its own thread, so this takes no lock of the media's.
private final class FirstFrameLog: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private static let logger = Logger(subsystem: "Yapnest", category: "Calls")
    private let logged = OSAllocatedUnfairLock(initialState: false)

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, logged.withLock({ let first = !$0; $0 = true; return first }) else { return }
        Self.logger.info("first remote video frame \(frame.width, privacy: .public)x\(frame.height, privacy: .public)")
    }
}

/// The peer connection's delegate. It only forwards, so it holds no state.
private final class Observer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    let continuation: AsyncStream<CallMediaEvent>.Continuation
    /// Set once, before the connection exists.
    nonisolated(unsafe) var remoteVideoTrack: ((RTCVideoTrack) -> Void)?

    init(continuation: AsyncStream<CallMediaEvent>.Continuation) {
        self.continuation = continuation
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        continuation.yield(.candidate(CallCandidate(
            sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, sdp: candidate.sdp)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let state: CallMediaState = switch newState {
        case .new, .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .failed
        }
        continuation.yield(.state(state))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack { remoteVideoTrack?(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
