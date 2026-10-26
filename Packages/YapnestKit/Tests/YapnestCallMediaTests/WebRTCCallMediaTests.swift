import Foundation
import Testing
import YapnestKit
@preconcurrency import WebRTC
@_spi(Testing) @testable import YapnestCallMedia

@Suite("WebRTC call media")
struct WebRTCCallMediaTests {
    @Test("two peers in one process connect over host candidates")
    func loopback() async throws {
        let factory = WebRTCCallMediaFactory(receiveOnly: true)
        try await connect(factory.makeMedia(relayOnly: false), factory.makeMedia(relayOnly: false), iceServers: [])
    }

    /// Needs a TURN server and its credentials in `YAPNEST_TURN_USER` and
    /// `YAPNEST_TURN_PASSWORD`; `YAPNEST_TURN_URL` is its `turn:` URL
    /// (default the dev ejabberd's). The dev ejabberd takes only the temporary
    /// credentials of XEP-0215: `auth_type: user` needs the account's password
    /// in plain text, and its accounts are stored as SCRAM. The server must
    /// advertise an address WebRTC can reach from the Mac's own interface, not
    /// 127.0.0.1 (`TURN_HOST` in dev/ejabberd/compose.yaml).
    ///
    /// Only the caller is forced onto the relay. The server relays from
    /// Docker, and two relays on one server can't reach each other through
    /// its published ports, while a relay reaches a host candidate fine.
    @Test(
        "two peers connect through the dev server's TURN relay",
        .enabled(if: Self.turnServer != nil))
    func throughTurn() async throws {
        let factory = WebRTCCallMediaFactory(receiveOnly: true)
        try await connect(
            factory.makeMedia(relayOnly: true), factory.makeMedia(relayOnly: false), iceServers: [try #require(Self.turnServer)])
    }

    private static let turnServer: CallIceServer? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["YAPNEST_INTEGRATION"] == "1",
            let user = environment["YAPNEST_TURN_USER"],
            let password = environment["YAPNEST_TURN_PASSWORD"]
        else { return nil }
        return CallIceServer(
            urls: [environment["YAPNEST_TURN_URL"] ?? "turn:127.0.0.1:3478?transport=udp"],
            username: user, credential: password)
    }()

    /// Negotiation only, so no microphone is opened: the callee's answer must
    /// send its audio, not just receive the caller's.
    @Test("both sides send their audio")
    func bothSidesSend() async throws {
        let factory = WebRTCCallMediaFactory(receiveOnly: false)
        let caller = factory.makeMedia(relayOnly: false), callee = factory.makeMedia(relayOnly: false)
        try await caller.start(iceServers: [], video: false)
        try await callee.start(iceServers: [], video: false)
        let offer = try await caller.makeOffer()
        let answer = try await callee.answer(offer: offer)
        #expect(Self.audioDirection(in: offer) == "sendrecv")
        #expect(Self.audioDirection(in: answer) == "sendrecv")
        caller.close()
        callee.close()
    }

    @Test("both sides send their video, and the offer lists video codecs")
    func bothSidesSendVideo() async throws {
        let factory = WebRTCCallMediaFactory(receiveOnly: false, syntheticCamera: true)
        let caller = factory.makeMedia(relayOnly: false), callee = factory.makeMedia(relayOnly: false)
        try await caller.start(iceServers: [], video: true)
        try await callee.start(iceServers: [], video: true)
        let offer = try await caller.makeOffer()
        let answer = try await callee.answer(offer: offer)
        for sdp in [offer, answer] {
            #expect(Self.direction(of: "audio", in: sdp) == "sendrecv")
            #expect(Self.direction(of: "video", in: sdp) == "sendrecv")
        }
        #expect(offer.range(of: #"a=rtpmap:\d+ (VP8|H264)/90000"#, options: .regularExpression) != nil)
        caller.close()
        callee.close()
    }

    @Test("an audio call offers no video")
    func audioOnlyOffersNoVideo() async throws {
        let factory = WebRTCCallMediaFactory(receiveOnly: false, syntheticCamera: true)
        let caller = factory.makeMedia(relayOnly: false)
        try await caller.start(iceServers: [], video: false)
        #expect(try await !caller.makeOffer().contains("m=video"))
        caller.close()
    }

    @Test("a receive-only side leaves its camera out and only receives video")
    func receiveOnlyVideo() async throws {
        let caller = WebRTCCallMediaFactory(receiveOnly: true).makeMedia(relayOnly: false)
        try await caller.start(iceServers: [], video: true)
        let offer = try await caller.makeOffer()
        #expect(Self.direction(of: "video", in: offer) == "recvonly")
        caller.close()
    }

    @Test("video flows between two peers into the remote renderer")
    func videoLoopback() async throws {
        let factory = WebRTCCallMediaFactory(receiveOnly: true, syntheticCamera: true)
        let caller = factory.makeMedia(relayOnly: false), callee = factory.makeMedia(relayOnly: false)
        let remote = FrameCounter(), local = FrameCounter()
        let calleeMedia = try #require(callee as? WebRTCCallMedia)
        // Before the call is set up: the renderers wait for their tracks.
        calleeMedia.addRenderer(remote, for: .remote)
        calleeMedia.addRenderer(local, for: .local)
        try await connect(caller, callee, iceServers: [], video: true) {
            for _ in 0..<100 where remote.count < 5 { try? await Task.sleep(for: .milliseconds(100)) }
            #expect(remote.count >= 5)
            #expect(local.count >= 1)
            let reading = await calleeMedia.statistics().map(CallStatsReading.init)
            #expect(reading?.path?.local == .host)
            #expect(reading?.roundTripTime != nil)
            #expect(reading?.videoIn?.framesDecoded != nil)
            #expect(reading?.videoOut != nil)
            calleeMedia.removeRenderer(remote, for: .remote)
            calleeMedia.setCameraEnabled(false)
            calleeMedia.setCameraEnabled(true)
            calleeMedia.switchCamera()
        }
    }

    private static func audioDirection(in sdp: String) -> String? {
        direction(of: "audio", in: sdp)
    }

    private static func direction(of media: String, in sdp: String) -> String? {
        let lines = sdp.components(separatedBy: "\r\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("m=\(media)") }) else { return nil }
        let section = lines[(start + 1)...].prefix { !$0.hasPrefix("m=") }
        return section.first { ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains($0) }.map { String($0.dropFirst(2)) }
    }

    @Test("a closed media finishes its events and refuses more work")
    func close() async throws {
        let media = WebRTCCallMediaFactory(receiveOnly: true).makeMedia(relayOnly: false)
        try await media.start(iceServers: [], video: false)
        media.close()
        media.close()
        var last: CallMediaEvent?
        for await event in media.events { last = event }
        #expect(last == .state(.closed))
        await #expect(throws: (any Error).self) { try await media.makeOffer() }
    }

    private func connect(
        _ caller: any CallMedia, _ callee: any CallMedia, iceServers: [CallIceServer], video: Bool = false,
        whileConnected: () async -> Void = {}
    ) async throws {
        try await caller.start(iceServers: iceServers, video: video)
        try await callee.start(iceServers: iceServers, video: video)

        let callerLatch = Latch()
        let calleeLatch = Latch()
        // Candidates are forwarded as they appear, as signalling would.
        let callerPump = Task { await Self.pump(from: caller, to: callee, connected: callerLatch) }
        let calleePump = Task { await Self.pump(from: callee, to: caller, connected: calleeLatch) }

        let offer = try await caller.makeOffer()
        #expect(offer.contains("opus"))
        let answer = try await callee.answer(offer: offer)
        try await caller.setAnswer(answer)
        caller.setMuted(true)
        caller.setMuted(false)

        var connected = false
        for _ in 0..<200 where !connected {
            let callerUp = await callerLatch.isSet
            let calleeUp = await calleeLatch.isSet
            connected = callerUp && calleeUp
            if !connected { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(connected)
        await whileConnected()

        caller.close()
        callee.close()
        // Closing finishes the streams, which ends these tasks.
        _ = await (callerPump.value, calleePump.value)
    }

    private static func pump(from: any CallMedia, to: any CallMedia, connected: Latch) async {
        for await event in from.events {
            switch event {
            case .candidate(let candidate): try? await to.addRemoteCandidate(candidate)
            case .state(.connected): await connected.set()
            default: break
            }
        }
    }
}

private actor Latch {
    private(set) var isSet = false
    func set() { isSet = true }
}

private final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    var count: Int { lock.withLock { frames } }

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        if frame != nil { lock.withLock { frames += 1 } }
    }
}
