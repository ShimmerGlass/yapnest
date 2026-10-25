import Foundation
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!
private let myDevice = "me@example.org/phone"
private let aliceDevice = "alice@example.org/laptop"
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private typealias Effect = CallMachine.Effect

private func outgoing() -> CallMachine {
    CallMachine.outgoing(sid: "s1", peer: alice, account: me, me: myDevice, now: t0).0
}

private func ringing() -> CallMachine {
    let propose = CallSignal(sid: "s1", action: .propose(media: [.audio]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
    return CallMachine.incoming(propose, account: me, me: myDevice, now: t0)!.0
}

private func fromPeer(_ action: CallSignal.Action) -> CallMachine.Input {
    .signal(CallSignal(sid: "s1", action: action, sender: alice, recipient: me, from: aliceDevice, timestamp: t0))
}

private func endings(_ effects: [Effect]) -> [CallEndReason] {
    effects.compactMap { if case .ended(let reason) = $0 { reason } else { nil } }
}

/// What a call does when the connection to the server drops under it.
struct CallMachineConnectionTests {
    private func lost(_ machine: inout CallMachine) -> Int {
        let effects = machine.handle(.connectionLost)
        guard case .armConnectionTimer(CallMachine.reconnectWindow, let token)? = effects.first else {
            Issue.record("no wait for the connection: \(effects)")
            return 0
        }
        return token
    }

    @Test func aDropWaitsBesideTheCallsOwnTimer() {
        var machine = outgoing()
        let effects = machine.handle(.connectionLost)
        #expect(effects == [.armConnectionTimer(after: CallMachine.reconnectWindow, token: 1)])
        #expect(machine.phase == .proposing)
    }

    @Test func aStreamThatComesBackInTimeChangesNothing() {
        var machine = outgoing()
        let token = lost(&machine)
        #expect(machine.handle(.connectionRestored).isEmpty)
        #expect(machine.handle(.connectionTimer(token)).isEmpty)
        #expect(machine.phase == .proposing)
    }

    @Test func aSecondDropIsWaitedForOnItsOwn() {
        var machine = outgoing()
        let first = lost(&machine)
        _ = machine.handle(.connectionRestored)
        let second = lost(&machine)
        #expect(second != first)
        #expect(machine.handle(.connectionTimer(first)).isEmpty, "the first drop's timer is stale")
        #expect(endings(machine.handle(.connectionTimer(second))) == [.connectionLost])
    }

    @Test func aDropIsOnlyWaitedForOnce() {
        var machine = outgoing()
        _ = lost(&machine)
        #expect(machine.handle(.connectionLost).isEmpty)
    }

    @Test func aCallStillRingingWithoutTheConnectionEndsAndRetractsForWhenItIsBack() {
        var machine = outgoing()
        _ = machine.handle(.proposeDelivered)
        let token = lost(&machine)
        let effects = machine.handle(.connectionTimer(token))
        #expect(effects.contains(.send(.retract(to: "alice@example.org", reason: .generalError))))
        #expect(endings(effects) == [.connectionLost])
        #expect(effects.contains(.closeMedia))
        #expect(machine.phase == .ended(.connectionLost))
    }

    @Test func anIncomingCallEndsWithoutAWordToAnyone() {
        var machine = ringing()
        let token = lost(&machine)
        let effects = machine.handle(.connectionTimer(token))
        #expect(endings(effects) == [.connectionLost])
        #expect(!effects.contains { if case .send = $0 { true } else { false } })
    }

    @Test func aCallBeingSetUpIsTerminatedBothWays() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        let token = lost(&machine)
        let effects = machine.handle(.connectionTimer(token))
        #expect(effects.contains(.terminateSession(to: aliceDevice, reason: .connectivityError)))
        #expect(effects.contains(.send(.finish(to: aliceDevice, reason: .connectivityError))))
        #expect(endings(effects) == [.connectionLost])
    }

    @Test func aCallThatIsUpGoesOnWithoutTheConnection() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        _ = machine.handle(.sessionAccept(from: aliceDevice))
        _ = machine.handle(.media(.connected))
        #expect(machine.phase == .active)
        let token = lost(&machine)
        #expect(machine.handle(.connectionTimer(token)).isEmpty)
        #expect(machine.phase == .active)
    }

    @Test func aLostConnectionCountsAsAFailedCall() {
        #expect(CallEndReason.connectionLost.outcome == .failed)
    }
}
