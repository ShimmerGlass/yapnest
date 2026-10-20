import Foundation
import GRDB
import Testing
@_spi(Testing) import YapnestCallMedia
@preconcurrency import WebRTC
@testable import YapnestKit

extension LiveServer {
    /// A call over the dev server with real WebRTC on both sides, which is the
    /// proof that real SDP survives the trip through Jingle. The media only
    /// receives: sending would open the microphone.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=ejabberd swift test --filter CallWebRTCIntegration`
    @Suite
    struct CallWebRTCIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func device(_ jid: JID, forceRelay: Bool, syntheticCamera: Bool = false) async throws -> XMPPSession {
            let session = try LiveServer.makeSession(
                jid, resource: "webrtc-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(),
                callMedia: WebRTCCallMediaFactory(forceRelay: forceRelay, receiveOnly: true, syntheticCamera: syntheticCamera),
            )
            try await LiveServer.connected(session)
            return session
        }

        private func call(callerForcesRelay: Bool) async throws {
            let caller = try await device(alice, forceRelay: callerForcesRelay)
            let callee = try await device(bob, forceRelay: false)
            defer { caller.disconnect(); callee.disconnect() }
            try await LiveServer.befriend(caller, callee)
            try await LiveServer.waitUntil("alice to be able to call bob") { caller.canCall(bob) }
            if callerForcesRelay {
                let servers = await caller.discoverIceServers()
                guard servers.contains(where: { $0.urls.contains { $0.hasPrefix("turn:") } }) else {
                    try Test.cancel("\(LiveServer.target.name) offers no TURN")
                    return
                }
            }

            try caller.startCall(to: bob)
            let sid = try #require(caller.callState.value?.sid)
            try await LiveServer.waitUntil("bob to ring") { callee.callState.value?.phase == .incoming }
            callee.answerCall()
            try await LiveServer.waitUntil("both to be connected", timeout: 20) {
                caller.callState.value?.phase == .active && callee.callState.value?.phase == .active
            }
            if let ended = [caller, callee].first(where: { $0.callState.value?.phase == .ended(.failed) }) {
                Issue.record("\(ended.account) failed")
            }

            caller.hangUpCall()
            try await LiveServer.waitUntil("bob to be hung up on") { callee.callState.value?.phase == .ended(.completed) }
            func row(_ session: XMPPSession) -> Message? {
                try? session.database.reader.read { try Message.filter(Column("callOutcome") != nil && Column("remoteId") == sid).fetchOne($0) }
            }
            try await LiveServer.waitUntil("both to record it") { row(caller) != nil && row(callee) != nil }
            #expect(row(caller)?.callOutcome == .answered)
            #expect(row(callee)?.callOutcome == .answered)
        }

        /// Video both ways from generated pictures, so no camera or microphone is
        /// opened, and what the camera switch does to a call that is running.
        @Test func aVideoCallCarriesPicturesBothWays() async throws {
            let caller = try await device(alice, forceRelay: false, syntheticCamera: true)
            let callee = try await device(bob, forceRelay: false, syntheticCamera: true)
            defer { caller.disconnect(); callee.disconnect() }
            try await LiveServer.befriend(caller, callee)
            try await LiveServer.waitUntil("alice to be able to video call bob") { caller.canCall(bob, video: true) }
            try await LiveServer.waitUntil("bob to be listed for video") { caller.videoCallablePeers.value.contains(bob) }

            try caller.startCall(to: bob, video: true)
            let sid = try #require(caller.callState.value?.sid)
            try await LiveServer.waitUntil("bob to ring") { callee.callState.value?.phase == .incoming }
            callee.answerCall()
            try await LiveServer.waitUntil("both to be connected", timeout: 20) {
                caller.callState.value?.phase == .active && callee.callState.value?.phase == .active
            }
            #expect(caller.callState.value?.isVideo == true)
            #expect(callee.callState.value?.isVideo == true)

            let callerMedia = try #require(await caller.callMedia(sid: sid) as? WebRTCCallMedia)
            let calleeMedia = try #require(await callee.callMedia(sid: sid) as? WebRTCCallMedia)
            let callerLocal = FrameCounter(), callerRemote = FrameCounter()
            let calleeLocal = FrameCounter(), calleeRemote = FrameCounter()
            callerMedia.addRenderer(callerLocal, for: .local)
            callerMedia.addRenderer(callerRemote, for: .remote)
            calleeMedia.addRenderer(calleeLocal, for: .local)
            calleeMedia.addRenderer(calleeRemote, for: .remote)

            try await LiveServer.waitUntil("pictures to arrive both ways", timeout: 20) {
                callerRemote.count > 0 && calleeRemote.count > 0 && callerLocal.count > 0 && calleeLocal.count > 0
            }

            caller.setCallCameraEnabled(false)
            #expect(caller.callState.value?.isCameraOn == false)
            // Frames already in flight when the capture stops.
            try await Task.sleep(for: .milliseconds(500))
            let stopped = callerLocal.count
            try await Task.sleep(for: .seconds(1))
            #expect(callerLocal.count == stopped, "the local picture kept coming with the camera off")

            caller.setCallCameraEnabled(true)
            #expect(caller.callState.value?.isCameraOn == true)
            try await LiveServer.waitUntil("the camera to send again") { callerLocal.count > stopped }

            caller.switchCallCamera()
            let switched = callerLocal.count
            let remoteAtSwitch = calleeRemote.count
            try await LiveServer.waitUntil("frames to go on after the switch") {
                callerLocal.count > switched + 5 && calleeRemote.count > remoteAtSwitch + 5
            }
            #expect(caller.callState.value?.phase == .active)

            caller.hangUpCall()
            try await LiveServer.waitUntil("bob to be hung up on") { callee.callState.value?.phase == .ended(.completed) }
            func row(_ session: XMPPSession) -> Message? {
                try? session.database.reader.read { try Message.filter(Column("callOutcome") != nil && Column("remoteId") == sid).fetchOne($0) }
            }
            try await LiveServer.waitUntil("both to record it") { row(caller) != nil && row(callee) != nil }
            for session in [caller, callee] {
                #expect(row(session)?.callOutcome == .answered)
                #expect(row(session)?.callIsVideo == true)
            }
        }

        @Test func aCallConnectsOverRealMedia() async throws {
            try await call(callerForcesRelay: false)
        }

        @Test func aCallConnectsThroughTheRelayWithTheServersCredentials() async throws {
            try await call(callerForcesRelay: true)
        }
    }
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
