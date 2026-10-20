import Foundation
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!
private let myDevice = "me@example.org/phone"
private let otherDevice = "me@example.org/tablet"
private let aliceDevice = "alice@example.org/laptop"
private let aliceOther = "alice@example.org/desktop"
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private typealias Effect = CallMachine.Effect

private func fromPeer(_ action: CallSignal.Action, device: String = aliceDevice, sid: String = "s1", at time: Date = t0) -> CallMachine.Input {
    .signal(CallSignal(sid: sid, action: action, sender: alice, recipient: me, from: device, timestamp: time))
}

private func fromOurDevice(_ action: CallSignal.Action, device: String = otherDevice, sid: String = "s1") -> CallMachine.Input {
    .signal(CallSignal(sid: sid, action: action, sender: me, recipient: alice, from: device, isFromAccount: true, timestamp: t0))
}

private func outgoing() -> CallMachine {
    CallMachine.outgoing(sid: "s1", peer: alice, account: me, me: myDevice, now: t0).0
}

private func ringing(propose: CallSignal? = nil, now: Date = t0) -> CallMachine {
    let signal = propose ?? CallSignal(sid: "s1", action: .propose(media: [.audio]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
    return CallMachine.incoming(signal, account: me, me: myDevice, now: now)!.0
}

private func timerToken(_ effects: [Effect]) -> Int? {
    effects.compactMap { if case .armTimer(_, let token) = $0 { token } else { nil } }.last
}

private func endings(_ effects: [Effect]) -> [CallEndReason] {
    effects.compactMap { if case .ended(let reason) = $0 { reason } else { nil } }
}

struct CallMachineOutgoingTests {
    @Test func startingProposesAndArmsTheRingTimer() {
        let (machine, effects) = CallMachine.outgoing(sid: "s1", peer: alice, account: me, me: myDevice, now: t0)
        #expect(machine.phase == .proposing)
        #expect(effects.first == .send(.propose(to: "alice@example.org", video: false)))
        #expect(!machine.wantsVideo)
        #expect(effects.contains(.prepareMedia))
        #expect(effects.contains(.armTimer(after: 60, token: 1)))
    }

    @Test func aVideoCallProposesVideo() {
        let (machine, effects) = CallMachine.outgoing(sid: "s1", peer: alice, account: me, me: myDevice, video: true, now: t0)
        #expect(machine.wantsVideo)
        #expect(effects.first == .send(.propose(to: "alice@example.org", video: true)))
    }

    @Test func aReceiptOrRingingMakesItRing() {
        var machine = outgoing()
        #expect(machine.handle(.proposeDelivered).isEmpty)
        #expect(machine.phase == .ringing)

        var other = outgoing()
        #expect(other.handle(fromPeer(.ringing)).isEmpty)
        #expect(other.phase == .ringing)
    }

    @Test func theFirstProceedGetsTheCallAndTheOthersAreIgnored() {
        var machine = outgoing()
        let effects = machine.handle(fromPeer(.proceed), now: t0 + 5)
        #expect(machine.phase == .accepted)
        #expect(machine.peerDevice == aliceDevice)
        #expect(effects.contains(.startSession(to: aliceDevice)))
        #expect(timerToken(effects) != nil)
        #expect(machine.answeredAt == t0 + 5)

        // Another of the callee's devices answered at the same moment: its own
        // wait ends when the first one's accept reaches it.
        #expect(machine.handle(fromPeer(.proceed, device: aliceOther)).isEmpty)
        #expect(machine.peerDevice == aliceDevice)
        #expect(machine.phase == .accepted)
    }

    @Test func aProceedWithoutADeviceIsIgnored() {
        var machine = outgoing()
        #expect(machine.handle(fromPeer(.proceed, device: "alice@example.org")).isEmpty)
        #expect(machine.phase == .proposing)
    }

    @Test func aRejectEndsItAsDeclinedOrBusy() {
        var declined = outgoing()
        #expect(endings(declined.handle(fromPeer(.reject(.decline)))) == [.declined])
        var plain = outgoing()
        #expect(endings(plain.handle(fromPeer(.reject(nil)))) == [.declined])
        var busy = outgoing()
        #expect(endings(busy.handle(fromPeer(.reject(.busy)))) == [.busy])
        #expect(busy.phase == .ended(.busy))
    }

    @Test func aRejectAfterAnotherDeviceAnsweredChangesNothing() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        #expect(machine.handle(fromPeer(.reject(.decline), device: aliceOther)).isEmpty)
        #expect(machine.phase == .accepted)
    }

    @Test func hangingUpWhileRingingRetracts() {
        var machine = outgoing()
        _ = machine.handle(.proposeDelivered)
        let effects = machine.handle(.hangUp)
        #expect(effects.contains(.send(.retract(to: "alice@example.org", reason: .cancel))))
        #expect(endings(effects) == [.cancelled])
        #expect(effects.contains(.closeMedia))
    }

    @Test func ringingOutRetractsAndIsNoAnswer() {
        var machine = outgoing()
        let token = timerToken(CallMachine.outgoing(sid: "s1", peer: alice, account: me, me: myDevice, now: t0).1)!
        let effects = machine.handle(.timer(token))
        #expect(effects.contains(.send(.retract(to: "alice@example.org", reason: .timeout))))
        #expect(endings(effects) == [.noAnswer])
        #expect(machine.phase == .ended(.noAnswer))
    }

    @Test func aStaleTimerChangesNothing() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        // The ring timer was superseded by the setup timer.
        #expect(machine.handle(.timer(1)).isEmpty)
        #expect(machine.phase == .accepted)
    }

    @Test func aProceedAfterTheRetractIsIgnored() {
        var machine = outgoing()
        _ = machine.handle(.hangUp)
        #expect(machine.handle(fromPeer(.proceed)).isEmpty)
        #expect(machine.phase == .ended(.cancelled))
    }

    @Test func theAnswerStartsTheConnection() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        // Not from the device that answered.
        #expect(machine.handle(.sessionAccept(from: aliceOther)).isEmpty)
        #expect(machine.phase == .accepted)
        let effects = machine.handle(.sessionAccept(from: aliceDevice))
        #expect(effects.contains(.applyAnswer))
        #expect(machine.phase == .connecting)
        #expect(timerToken(effects) != nil)
    }

    @Test func aSessionInitiateIsNotForTheCaller() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        #expect(machine.handle(.sessionInitiate(from: aliceDevice)).isEmpty)
        #expect(machine.phase == .accepted)
    }

    @Test func connectingBecomesActiveAndTimesTheCall() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        _ = machine.handle(.sessionAccept(from: aliceDevice))
        let effects = machine.handle(.media(.connected), now: t0 + 20)
        #expect(machine.phase == .active)
        #expect(machine.activeSince == t0 + 20)
        #expect(effects == [.cancelTimer])
    }

    @Test func hangingUpAnActiveCallEndsTheSession() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        _ = machine.handle(.sessionAccept(from: aliceDevice))
        _ = machine.handle(.media(.connected))
        let effects = machine.handle(.hangUp)
        #expect(effects.contains(.terminateSession(to: aliceDevice, reason: .success)))
        #expect(effects.contains(.send(.finish(to: aliceDevice, reason: .success))))
        #expect(endings(effects) == [.completed])
    }

    @Test func hangingUpBeforeItConnectsIsCancelled() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        let effects = machine.handle(.hangUp)
        #expect(effects.contains(.terminateSession(to: aliceDevice, reason: .cancel)))
        #expect(endings(effects) == [.cancelled])
    }

    @Test func theMediaFailingEndsTheSessionAndTheCall() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        _ = machine.handle(.sessionAccept(from: aliceDevice))
        let effects = machine.handle(.media(.failed))
        #expect(effects.contains(.terminateSession(to: aliceDevice, reason: .connectivityError)))
        #expect(effects.contains(.send(.finish(to: aliceDevice, reason: .connectivityError))))
        #expect(endings(effects) == [.failed])
        #expect(effects.contains(.closeMedia))
    }

    @Test func aLostConnectionMayStillRecover() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        _ = machine.handle(.sessionAccept(from: aliceDevice))
        _ = machine.handle(.media(.connected))
        #expect(machine.handle(.media(.disconnected)).isEmpty)
        #expect(machine.phase == .active)
    }

    @Test func mediaThatCannotStartRetractsTheCall() {
        var machine = outgoing()
        let effects = machine.handle(.media(.failed))
        #expect(effects.contains(.send(.retract(to: "alice@example.org", reason: .generalError))))
        #expect(endings(effects) == [.failed])
    }

    @Test func aSetupThatTakesTooLongFails() {
        var machine = outgoing()
        let token = timerToken(machine.handle(fromPeer(.proceed)))!
        let effects = machine.handle(.timer(token))
        #expect(endings(effects) == [.failed])
        #expect(effects.contains(.terminateSession(to: aliceDevice, reason: .connectivityError)))
    }

    @Test func iceThatTakesTooLongFails() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        let token = timerToken(machine.handle(.sessionAccept(from: aliceDevice)))!
        #expect(endings(machine.handle(.timer(token))) == [.failed])
    }

    @Test func theRemoteTerminatingEndsIt() {
        var active = outgoing()
        _ = machineConnected(&active)
        #expect(endings(active.handle(.sessionTerminate(from: aliceDevice, reason: .success))) == [.completed])

        var early = outgoing()
        _ = early.handle(fromPeer(.proceed))
        #expect(endings(early.handle(.sessionTerminate(from: aliceDevice, reason: .decline))) == [.declined])

        var busy = outgoing()
        _ = busy.handle(fromPeer(.proceed))
        #expect(endings(busy.handle(.sessionTerminate(from: aliceDevice, reason: .busy))) == [.busy])

        var broken = outgoing()
        _ = broken.handle(fromPeer(.proceed))
        #expect(endings(broken.handle(.sessionTerminate(from: aliceDevice, reason: .generalError))) == [.failed])
    }

    @Test func aTerminateFromAStrangerIsIgnored() {
        var machine = outgoing()
        _ = machineConnected(&machine)
        #expect(machine.handle(.sessionTerminate(from: aliceOther, reason: .success)).isEmpty)
        #expect(machine.phase == .active)
    }

    @Test func aFinishEndsItToo() {
        var machine = outgoing()
        _ = machineConnected(&machine)
        #expect(endings(machine.handle(fromPeer(.finish(.success)))) == [.completed])
        // And what follows changes nothing.
        #expect(machine.handle(.sessionTerminate(from: aliceDevice, reason: .success)).isEmpty)
    }

    @Test func aFinishFromAnotherDeviceIsIgnored() {
        var machine = outgoing()
        _ = machineConnected(&machine)
        #expect(machine.handle(fromPeer(.finish(.success), device: aliceOther)).isEmpty)
        #expect(machine.phase == .active)
    }

    @Test func signalsOfAnotherCallAreIgnored() {
        var machine = outgoing()
        #expect(machine.handle(fromPeer(.proceed, sid: "other")).isEmpty)
        #expect(machine.phase == .proposing)
    }

    @Test func signalsFromAStrangerAreIgnored() {
        var machine = outgoing()
        let stranger = CallSignal(sid: "s1", action: .proceed, sender: JID("mallory@example.org")!, recipient: me, from: "mallory@example.org/x", timestamp: t0)
        #expect(machine.handle(.signal(stranger)).isEmpty)
        #expect(machine.phase == .proposing)
    }

    private func machineConnected(_ machine: inout CallMachine) -> [Effect] {
        _ = machine.handle(fromPeer(.proceed))
        _ = machine.handle(.sessionAccept(from: aliceDevice))
        return machine.handle(.media(.connected))
    }
}

struct CallMachineIncomingTests {
    @Test func aFreshProposeRingsAndSaysSo() throws {
        let propose = CallSignal(sid: "s1", action: .propose(media: [.audio]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        let (machine, effects) = try #require(CallMachine.incoming(propose, account: me, me: myDevice, now: t0 + 2))
        #expect(machine.phase == .incoming)
        #expect(effects.first == .send(.ringing(to: aliceDevice)))
        #expect(effects.contains(.armTimer(after: 58, token: 1)))
    }

    @Test func aProposeWithVideoWantsVideo() throws {
        let propose = CallSignal(sid: "s1", action: .propose(media: [.audio, .video]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        let (machine, _) = try #require(CallMachine.incoming(propose, account: me, me: myDevice, now: t0 + 2))
        #expect(machine.wantsVideo)
        let audio = CallSignal(sid: "s1", action: .propose(media: [.audio]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        #expect(try #require(CallMachine.incoming(audio, account: me, me: myDevice, now: t0 + 2)).0.wantsVideo == false)
    }

    @Test func aVideoOnlyProposeIsIgnored() {
        let propose = CallSignal(sid: "s1", action: .propose(media: [.video]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        #expect(CallMachine.incoming(propose, account: me, me: myDevice, now: t0 + 2) == nil)
    }

    @Test func aProposeOlderThanTheRingWindowNeverRings() throws {
        let propose = CallSignal(sid: "s1", action: .propose(media: [.audio]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        let (machine, effects) = try #require(CallMachine.incoming(propose, account: me, me: myDevice, now: t0 + 61))
        #expect(machine.phase == .ended(.missed))
        #expect(effects == [.ended(.missed)])
    }

    @Test func aVideoCallRingsAndRemembersIt() throws {
        let propose = CallSignal(sid: "s1", action: .propose(media: [.audio, .video]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        let (machine, _) = try #require(CallMachine.incoming(propose, account: me, me: myDevice, now: t0))
        #expect(machine.wantsVideo)
    }

    @Test func aCallOfVideoOnlyIsNotOneWeTake() {
        let propose = CallSignal(sid: "s1", action: .propose(media: [.video]), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        #expect(CallMachine.incoming(propose, account: me, me: myDevice, now: t0) == nil)
    }

    @Test func answeringSendsProceedAndTellsOurOtherDevices() {
        var machine = ringing()
        let effects = machine.handle(.answer, now: t0 + 3)
        #expect(machine.phase == .accepted)
        #expect(effects.contains(.send(.proceed(to: aliceDevice))))
        #expect(effects.contains(.send(.accept(to: "me@example.org"))))
        #expect(effects.contains(.prepareMedia))
        #expect(timerToken(effects) != nil)
    }

    @Test func decliningRejectsToTheCallersDevice() {
        var machine = ringing()
        let effects = machine.handle(.decline)
        #expect(effects.contains(.send(.reject(to: aliceDevice, reason: .decline))))
        #expect(endings(effects) == [.declined])
    }

    @Test func hangingUpWhileRingingIsDeclining() {
        var machine = ringing()
        let effects = machine.handle(.hangUp)
        #expect(effects.contains(.send(.reject(to: aliceDevice, reason: .decline))))
        #expect(endings(effects) == [.declined])
    }

    @Test func theCallerHangingUpIsAMissedCall() {
        var machine = ringing()
        let effects = machine.handle(fromPeer(.retract(.cancel)))
        #expect(endings(effects) == [.missed])
        #expect(effects.contains(.closeMedia))
    }

    @Test func ringingOutIsAMissedCall() {
        var machine = ringing()
        let effects = machine.handle(.timer(1))
        #expect(endings(effects) == [.missed])
        // Nothing is sent: the caller ends it themselves.
        #expect(!effects.contains { if case .send = $0 { true } else { false } })
    }

    @Test func aRetractThatCrossesOurProceedEndsItAsMissed() {
        var machine = ringing()
        _ = machine.handle(.answer)
        let effects = machine.handle(fromPeer(.retract(nil)))
        #expect(endings(effects) == [.missed])
        #expect(machine.phase == .ended(.missed))
    }

    @Test func aLateRetractDoesNotEndAConnectedCall() {
        var machine = ringing()
        _ = machine.handle(.answer)
        _ = machine.handle(.sessionInitiate(from: aliceDevice))
        #expect(machine.handle(fromPeer(.retract(nil))).isEmpty)
        #expect(machine.phase == .connecting)
    }

    @Test func anotherDeviceAnsweringStopsTheRing() {
        for action in [CallSignal.Action.proceed, .accept] {
            var machine = ringing()
            let effects = machine.handle(fromOurDevice(action))
            #expect(endings(effects) == [.answeredElsewhere], "\(action)")
        }
    }

    @Test func anotherDeviceDecliningStopsTheRing() {
        var machine = ringing()
        #expect(endings(machine.handle(fromOurDevice(.reject(nil)))) == [.declinedElsewhere])
    }

    @Test func ourOwnMessageComingBackChangesNothing() {
        var machine = ringing()
        #expect(machine.handle(fromOurDevice(.accept, device: myDevice)).isEmpty)
        #expect(machine.phase == .incoming)
        _ = machine.handle(.answer)
        // Our own accept, delivered to every resource of the account.
        #expect(machine.handle(fromOurDevice(.accept, device: myDevice)).isEmpty)
        #expect(machine.phase == .accepted)
    }

    @Test func whenTwoOfOurDevicesAnswerTheCallerPicksOne() {
        var machine = ringing()
        _ = machine.handle(.answer)
        // The other device's accept arrives while we wait for the caller.
        #expect(machine.handle(fromOurDevice(.accept)).isEmpty)
        #expect(machine.phase == .accepted)

        // If the caller chose us, its session-initiate still comes.
        var chosen = machine
        #expect(chosen.handle(.sessionInitiate(from: aliceDevice)).contains(.answerSession))

        // If not, nothing comes, and the wait ends as answered elsewhere.
        let token = 2
        #expect(endings(machine.handle(.timer(token))) == [.answeredElsewhere])
    }

    @Test func aWaitForTheCallerThatEndsAloneFails() {
        var machine = ringing()
        let token = timerToken(machine.handle(.answer))!
        let effects = machine.handle(.timer(token))
        #expect(endings(effects) == [.failed])
        #expect(effects.contains(.send(.finish(to: aliceDevice, reason: .connectivityError))))
    }

    @Test func onlyTheCallersSessionInitiateIsAnswered() {
        var machine = ringing()
        // Before we answered.
        #expect(machine.handle(.sessionInitiate(from: aliceDevice)).isEmpty)
        _ = machine.handle(.answer)
        // From another device of theirs.
        #expect(machine.handle(.sessionInitiate(from: aliceOther)).isEmpty)
        #expect(machine.phase == .accepted)
        let effects = machine.handle(.sessionInitiate(from: aliceDevice))
        #expect(effects.contains(.answerSession))
        #expect(machine.phase == .connecting)
    }

    @Test func aSecondSessionInitiateIsRefused() {
        var machine = ringing()
        _ = machine.handle(.answer)
        _ = machine.handle(.sessionInitiate(from: aliceDevice))
        #expect(machine.handle(.sessionInitiate(from: aliceDevice)).isEmpty)
    }

    @Test func aSessionAcceptIsNotForTheCallee() {
        var machine = ringing()
        _ = machine.handle(.answer)
        #expect(machine.handle(.sessionAccept(from: aliceDevice)).isEmpty)
    }

    @Test func connectedThenHungUpIsCompleted() {
        var machine = ringing()
        _ = machine.handle(.answer)
        _ = machine.handle(.sessionInitiate(from: aliceDevice))
        _ = machine.handle(.media(.connected), now: t0 + 10)
        let effects = machine.handle(.hangUp, now: t0 + 40)
        #expect(endings(effects) == [.completed])
        #expect(machine.activeSince == t0 + 10)
    }

    @Test func changingOurMindAfterAnsweringIsDeclined() {
        var machine = ringing()
        _ = machine.handle(.answer)
        #expect(endings(machine.handle(.hangUp)) == [.declined])
    }

    @Test func theCallersFinishEndsAnActiveCall() {
        var machine = ringing()
        _ = machine.handle(.answer)
        _ = machine.handle(.sessionInitiate(from: aliceDevice))
        _ = machine.handle(.media(.connected))
        #expect(endings(machine.handle(fromPeer(.finish(.success)))) == [.completed])
    }

    @Test func theCallerCancellingTheSessionIsMissed() {
        var machine = ringing()
        _ = machine.handle(.answer)
        _ = machine.handle(.sessionInitiate(from: aliceDevice))
        #expect(endings(machine.handle(.sessionTerminate(from: aliceDevice, reason: .cancel))) == [.missed])
    }

    @Test func nothingHappensToAnEndedCall() {
        var machine = ringing()
        _ = machine.handle(.decline)
        for input: CallMachine.Input in [.answer, .hangUp, .timer(1), .media(.failed), fromPeer(.retract(nil))] {
            #expect(machine.handle(input).isEmpty)
        }
        #expect(machine.phase == .ended(.declined))
    }

    @Test func endingMapsToWhatTheChatShows() {
        #expect(CallEndReason.completed.outcome == .answered)
        #expect(CallEndReason.answeredElsewhere.outcome == .answered)
        #expect(CallEndReason.declined.outcome == .declined)
        #expect(CallEndReason.declinedElsewhere.outcome == .declined)
        #expect(CallEndReason.cancelled.outcome == .cancelled)
        #expect(CallEndReason.noAnswer.outcome == .cancelled)
        #expect(CallEndReason.missed.outcome == .missed)
        #expect(CallEndReason.busy.outcome == .busy)
        #expect(CallEndReason.failed.outcome == .failed)
    }
}

struct CallMachineTieBreakTests {
    @Test func theLowerSessionIdWinsByBytes() {
        #expect(CallMachine.winsTieBreak(ourSid: "a", ourAddress: "x", theirSid: "b", theirAddress: "y"))
        #expect(!CallMachine.winsTieBreak(ourSid: "b", ourAddress: "x", theirSid: "a", theirAddress: "y"))
        // Upper case sorts before lower case, unlike in a locale's collation.
        #expect(CallMachine.winsTieBreak(ourSid: "B", ourAddress: "x", theirSid: "a", theirAddress: "y"))
        // A prefix sorts first.
        #expect(CallMachine.winsTieBreak(ourSid: "ab", ourAddress: "x", theirSid: "abc", theirAddress: "y"))
    }

    @Test func theSameSessionIdGoesToTheLowerAddress() {
        #expect(CallMachine.winsTieBreak(ourSid: "s", ourAddress: "a@x/1", theirSid: "s", theirAddress: "b@x/1"))
        #expect(!CallMachine.winsTieBreak(ourSid: "s", ourAddress: "b@x/1", theirSid: "s", theirAddress: "a@x/1"))
    }

    @Test func yieldingRetractsWithTheTieBreakAndEndsQuietly() {
        var machine = outgoing()
        let effects = machine.handle(.yieldToTieBreak)
        #expect(effects.contains(.send(.retract(to: "alice@example.org", reason: .expired, tieBreak: true))))
        #expect(endings(effects) == [.tieBreak])
        #expect(CallEndReason.tieBreak.outcome == .cancelled)
    }

    @Test func onlyACallWithoutAnAnswerYields() {
        var machine = outgoing()
        _ = machine.handle(fromPeer(.proceed))
        #expect(machine.handle(.yieldToTieBreak).isEmpty)
        var incoming = ringing()
        #expect(incoming.handle(.yieldToTieBreak).isEmpty)
    }

    @Test func aTieBreakRejectOrRetractEndsQuietly() {
        var rejected = outgoing()
        var signal = CallSignal(sid: "s1", action: .reject(.expired), sender: alice, recipient: me, from: aliceDevice, timestamp: t0)
        signal.isTieBreak = true
        #expect(endings(rejected.handle(.signal(signal))) == [.tieBreak])

        var retracted = ringing()
        signal.action = .retract(.expired)
        #expect(endings(retracted.handle(.signal(signal))) == [.tieBreak])

        // Our other device's tie-break reject stops this one ringing quietly too.
        var other = ringing()
        var mine = CallSignal(sid: "s1", action: .reject(.expired), sender: me, recipient: alice, from: otherDevice, isFromAccount: true, timestamp: t0)
        mine.isTieBreak = true
        #expect(endings(other.handle(.signal(mine))) == [.tieBreak])
    }

    @Test func dismissingEndsARingingCallWithoutASignal() {
        var machine = ringing()
        let effects = machine.handle(.dismiss)
        #expect(!effects.contains { if case .send = $0 { true } else { false } })
        #expect(endings(effects) == [.dismissed])
        #expect(CallEndReason.dismissed.outcome == .missed)
    }
}
