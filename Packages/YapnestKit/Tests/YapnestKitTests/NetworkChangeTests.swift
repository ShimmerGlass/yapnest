import Foundation
import Synchronization
import Testing
@testable import YapnestKit

struct NetworkChangeTests {
    private typealias Action = XMPPSession.PathAction

    @Test func connectedConnectionIsVerified() {
        #expect(XMPPSession.pathAction(for: .connected(), wantsConnection: true) == Action.verify)
    }

    @Test func attemptInFlightIsRestarted() {
        #expect(XMPPSession.pathAction(for: .connecting, wantsConnection: true) == Action.restartAttempt)
    }

    @Test func backoffIsSkipped() {
        #expect(XMPPSession.pathAction(for: .disconnected(), wantsConnection: true) == Action.loginNow)
    }

    @Test func nothingHappensWhenNoConnectionIsWanted() {
        #expect(XMPPSession.pathAction(for: .connecting, wantsConnection: false) == Action.nothing)
        #expect(XMPPSession.pathAction(for: .disconnected(), wantsConnection: false) == Action.nothing)
        #expect(XMPPSession.pathAction(for: .disconnecting, wantsConnection: true) == Action.nothing)
    }

    /// A switch reports several path updates; only one should act.
    @Test func burstOfUpdatesActsOnce() async throws {
        let debouncer = Debouncer()
        let runs = Mutex(0)
        for _ in 0..<5 { debouncer.schedule(after: 0.1) { runs.withLock { $0 += 1 } } }
        // The timer sits on a global queue, which can start late when the suites run in
        // parallel, so wait for the first run rather than a fixed time. The settle period
        // then gives any earlier generation that wrongly survived time to run too.
        let deadline = ContinuousClock.now + .seconds(5)
        while runs.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runs.withLock { $0 } > 0, "The debounced action never ran")
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs.withLock { $0 } == 1)
    }

    /// A session that wasn't asked to connect stays put, so a path update
    /// can't start a login of its own.
    @Test func unwantedSessionDoesNotLogIn() throws {
        let session = try makeSession(JID("alice@localhost")!)
        session.pathBecameSatisfied()
        #expect(session.state.value == .disconnected(error: nil))
    }
}
