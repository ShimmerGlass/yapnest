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
        await eventually("the debounced action") { runs.withLock { $0 } > 0 }
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

    @Test func unchangedPathDoesNotRestartAnAttempt() {
        #expect(XMPPSession.pathAction(for: .connecting, wantsConnection: true, changed: false) == Action.nothing)
        #expect(XMPPSession.pathAction(for: .connecting, wantsConnection: true, changed: true) == Action.restartAttempt)
        #expect(XMPPSession.pathAction(for: .connected(), wantsConnection: true, changed: false) == Action.verify)
    }

    private static let wifi = PathSignature(status: .satisfied, interfaces: ["en0/wifi"])
    private static let cellular = PathSignature(status: .satisfied, interfaces: ["pdp_ip0/cellular"])
    private static let down = PathSignature(status: .unsatisfied, interfaces: [])

    private final class Acts: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Bool] = []
        func record(_ changed: Bool) { lock.withLock { list.append(changed) } }
        var values: [Bool] { lock.withLock { list } }
    }

    private func gate(quietInterval: TimeInterval = 10, _ acts: Acts) -> PathUpdateGate {
        PathUpdateGate(changeDelay: 0.1, quietDelay: 0.4, quietInterval: quietInterval) { changed in acts.record(changed) }
    }

    /// The timers sit on a global queue that can start late when the suites run in parallel,
    /// so wait for the first action, then give a wrongly surviving second one time to show.
    private func settle(_ acts: Acts, expectingAction: Bool = true) async throws {
        if expectingAction {
            await eventually("the first action") { !acts.values.isEmpty }
        }
        try await Task.sleep(for: .milliseconds(800))
    }

    @Test func burstOfIdenticalUpdatesGivesOneCheckThatCannotRestart() async throws {
        let acts = Acts()
        let gate = gate(acts)
        gate.receive(Self.wifi)
        for _ in 0..<6 {
            gate.receive(Self.wifi)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await settle(acts)
        #expect(acts.values == [false])
    }

    @Test func secondBurstSoonAfterIsSkipped() async throws {
        let acts = Acts()
        let gate = gate(acts)
        gate.receive(Self.wifi)
        gate.receive(Self.wifi)
        try await settle(acts)
        gate.receive(Self.wifi)
        try await settle(acts)
        #expect(acts.values == [false])
    }

    @Test func interfaceChangeActsAsChanged() async throws {
        let acts = Acts()
        let gate = gate(acts)
        gate.receive(Self.wifi)
        let difference = gate.receive(Self.cellular)
        #expect(difference == PathUpdateGate.Difference(status: false, interfaces: true))
        try await settle(acts)
        #expect(acts.values == [true])
    }

    @Test func unsatisfiedThenSatisfiedActsAsChanged() async throws {
        let acts = Acts()
        let gate = gate(acts)
        gate.receive(Self.wifi)
        #expect(gate.receive(Self.down) == PathUpdateGate.Difference(status: true, interfaces: true))
        try await settle(acts, expectingAction: false)
        #expect(acts.values.isEmpty)
        gate.receive(Self.wifi)
        try await settle(acts)
        #expect(acts.values == [true])
    }

    @Test func repeatDuringARealChangeKeepsItChanged() async throws {
        let acts = Acts()
        let gate = gate(acts)
        gate.receive(Self.wifi)
        gate.receive(Self.cellular)
        gate.receive(Self.cellular)
        try await settle(acts)
        #expect(acts.values == [true])
    }

    @Test func interfaceOrderIsNotADifference() {
        let a = PathSignature(status: .satisfied, interfaces: ["en0/wifi", "pdp_ip0/cellular"])
        let b = PathSignature(status: .satisfied, interfaces: ["pdp_ip0/cellular", "en0/wifi"])
        #expect(a == b)
    }

    @Test func loggedFieldsSayWhatDiffered() {
        func text(_ d: PathUpdateGate.Difference) -> [String] { PathUpdateGate.fields(d).map { "\($0.key)=\($0.rendered)" } }
        #expect(text(.init(status: false, interfaces: true)) == ["statusChanged=false", "interfacesChanged=true"])
        #expect(text(.init(status: true, interfaces: false)) == ["statusChanged=true", "interfacesChanged=false"])
    }
}
