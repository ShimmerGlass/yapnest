import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

private let alice = YapnestKit.JID("alice@example.org")!

/// A hang-up that the stream couldn't carry, and a stream that stays away.
struct CallConnectionTests {
    let h: CallSessionHarness

    init() throws {
        h = try CallSessionHarness()
        // Connecting leaves a send of the kept call messages waiting, which first finds the client not
        // yet reading connected and looks again 10 ms later: just as these tests drop and restore the
        // stream. It would send what a test has kept, or take it while the stream is down and put it
        // back after the reconnect's own send has found nothing. A new attempt number makes it stand
        // down; the sends of these tests' own reconnects are made after this.
        h.session.lock.withLock { $0.attempt += 1 }
    }

    private func startCall() async throws -> String {
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value).sid
        await eventually("the propose") { h.sentSignals.contains { $0.action == "propose" } }
        return sid
    }

    private func retracts(_ sid: String) -> [String] {
        h.sentSignals.filter { $0.action == "retract" && $0.sid == sid }.map(\.to)
    }

    @Test func aHangUpWhileTheStreamIsDownIsSentWhenItIsBack() async throws {
        let sid = try await startCall()
        h.session.client.update(state: .disconnected())
        h.session.hangUpCall()
        #expect(h.phase == .ended(.cancelled))
        try await Task.sleep(for: .milliseconds(100))
        #expect(retracts(sid).isEmpty, "nothing could be written")

        h.session.client.update(state: .connected(resumed: true))
        await eventually("the retract") { !retracts(sid).isEmpty }
        #expect(retracts(sid) == ["alice@example.org"])
    }

    @Test func aHangUpTheStreamDroppedIsSentWhenItIsBack() async throws {
        let sid = try await startCall()
        h.wire.failsWrites = true
        h.session.hangUpCall()
        try await Task.sleep(for: .milliseconds(100))
        #expect(retracts(sid).count == 1, "written to the dead stream, which dropped it")
        h.wire.failsWrites = false

        h.session.client.update(state: .disconnected())
        h.session.client.update(state: .connected(resumed: true))
        await eventually("the retract again") { retracts(sid).count == 2 }
    }

    @Test func aDeclineWhileTheStreamIsDownIsSentWhenItIsBack() async throws {
        h.receive(h.propose())
        await eventually("the ring") { h.phase == .incoming }
        h.session.client.update(state: .disconnected())
        h.session.hangUpCall()
        h.session.client.update(state: .connected(resumed: true))
        await eventually("the reject") { h.sentSignals.contains { $0.action == "reject" } }
    }

    @Test func aMessageIsOnlyKeptForTwoMinutes() async throws {
        let sid = try await startCall()
        h.session.client.update(state: .disconnected())
        h.session.hangUpCall()
        await eventually("the retract to be kept") { h.session.lock.withLock { !$0.unsentCallMessages.isEmpty } }
        // Past the lifetime the peer has timed the call out on its own.
        h.session.lock.withLock {
            $0.unsentCallMessages = $0.unsentCallMessages.map { item in
                var old = item
                old.since = Date().addingTimeInterval(-XMPPSession.unsentCallMessageLifetime - 1)
                return old
            }
        }
        h.session.client.update(state: .connected(resumed: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(retracts(sid).isEmpty)
    }

    @Test func aProposalIsNeverKeptForLater() async throws {
        h.session.client.update(state: .disconnected())
        h.session.writeCall(.propose(to: "alice@example.org", video: false), sid: "late")
        h.session.client.update(state: .connected(resumed: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.sentSignals.allSatisfy { $0.sid != "late" })
    }

    @Test func aCallStillRingingAfterTheStreamStaysAwayEndsHere() async throws {
        let sid = try await startCall()
        h.session.client.update(state: .disconnected())
        // The wait itself is twenty seconds; the first timer is the one the drop armed.
        h.session.callStep(.connectionTimer(1), sid: sid)
        #expect(h.phase == .ended(.connectionLost))
        h.session.client.update(state: .connected(resumed: true))
        await eventually("the retract") { !retracts(sid).isEmpty }
    }

    @Test func aStreamThatResumesLeavesTheCallAlone() async throws {
        let sid = try await startCall()
        h.session.client.update(state: .disconnected())
        h.session.client.update(state: .connected(resumed: true))
        h.session.callStep(.connectionTimer(1), sid: sid)
        #expect(h.phase == .proposing)
    }
}
