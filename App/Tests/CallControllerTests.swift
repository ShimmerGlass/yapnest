import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// What the call screen shows, and what a video call asks of the device.
@MainActor
struct CallControllerTests {
    private let peer = JID("bob@example.org")!

    private func state(
        _ phase: CallPhase, _ direction: Message.Direction = .outgoing, video: Bool = false
    ) -> CallState {
        CallState(sid: "s", peer: peer, direction: direction, phase: phase, isVideo: video, isCameraOn: video)
    }

    private let phases: [CallPhase] = [
        .proposing, .ringing, .incoming, .accepted, .connecting, .active, .ended(.completed), .ended(.failed),
    ]

    @Test func aCallThatGaveWayOrWasDismissedIsReportedToCallKitAsNothingTheUserDid() {
        // Giving way to the peer's call is the peer ending ours; a dismissed one never rang.
        #expect(CallController.endReason(.tieBreak) == .remoteEnded)
        #expect(CallController.endReason(.dismissed) == .unanswered)
    }

    @Test func aScreenIsShownForOurOwnCallsAndForAnsweredOnes() {
        for direction in [Message.Direction.outgoing, .incoming] {
            for phase in phases {
                let expected: Bool = switch phase {
                case .proposing, .ringing: direction == .outgoing
                case .accepted, .connecting, .active: true
                case .incoming: !CallController.usesCallKit
                case .ended: false
                }
                #expect(CallController.showsScreen(for: state(phase, direction)) == expected, "\(phase) \(direction)")
            }
        }
    }

    private func screens(_ call: CallState, usesCallKit: Bool, isExpanded: Bool) -> (view: Bool, bar: CallState?) {
        (CallController.showsCallView(isInCall: true, screen: call, usesCallKit: usesCallKit, isExpanded: isExpanded),
         CallController.callBar(isInCall: true, screen: call, usesCallKit: usesCallKit, isExpanded: isExpanded))
    }

    @Test func anAudioCallUnderCallKitHasTheBarWhateverIsExpanded() {
        let call = state(.active)
        for expanded in [false, true] {
            let shown = screens(call, usesCallKit: true, isExpanded: expanded)
            #expect(!shown.view)
            #expect(shown.bar == call)
        }
    }

    @Test func aVideoCallHasTheViewWhenExpandedAndTheBarWhenMinimized() {
        let call = state(.active, video: true)
        for usesCallKit in [false, true] {
            let expanded = screens(call, usesCallKit: usesCallKit, isExpanded: true)
            #expect(expanded.view)
            #expect(expanded.bar == nil)
            let minimized = screens(call, usesCallKit: usesCallKit, isExpanded: false)
            #expect(!minimized.view)
            #expect(minimized.bar == call)
        }
    }

    @Test func withoutCallKitAnAudioCallHasTheViewOnlyOnceExpanded() {
        let call = state(.active)
        #expect(screens(call, usesCallKit: false, isExpanded: true).view)
        #expect(screens(call, usesCallKit: false, isExpanded: true).bar == nil)
        #expect(!screens(call, usesCallKit: false, isExpanded: false).view)
        #expect(screens(call, usesCallKit: false, isExpanded: false).bar == call)
    }

    @Test func aRingingCallWithoutCallKitIsInTheBarEvenForVideo() {
        for video in [false, true] {
            let call = state(.incoming, .incoming, video: video)
            for expanded in [false, true] {
                let shown = screens(call, usesCallKit: false, isExpanded: expanded)
                #expect(!shown.view)
                #expect(shown.bar == call)
            }
            #expect(!CallController.canExpand(screen: call, usesCallKit: false))
        }
    }

    @Test func anIncomingVideoCallBeforeItIsAnsweredShowsNothingUnderCallKit() {
        // The controller holds no screen for it yet, so CallKit's ringing stays its own.
        #expect(!CallController.showsCallView(isInCall: false, screen: nil, usesCallKit: true, isExpanded: true))
        #expect(CallController.callBar(isInCall: false, screen: nil, usesCallKit: true, isExpanded: true) == nil)
    }

    @Test func anEndedCallLingersWhereItWasShown() {
        let video = state(.ended(.completed), video: true)
        #expect(screens(video, usesCallKit: true, isExpanded: true).view)
        #expect(screens(video, usesCallKit: true, isExpanded: false).bar == video)
        let audio = state(.ended(.completed))
        #expect(screens(audio, usesCallKit: true, isExpanded: false).bar == audio)
    }

    @Test func aCallStartsExpandedOnlyIfItHasVideo() {
        #expect(CallController.startsExpanded(state(.proposing, video: true)))
        #expect(!CallController.startsExpanded(state(.proposing)))
        #expect(!CallController.startsExpanded(state(.incoming, .incoming)))
    }

    @Test func minimizingAndExpandingARoundTripsAndANewCallResetsIt() {
        let controller = CallController()
        controller.setScreen(state(.active, video: true))
        #expect(controller.isExpanded)
        controller.minimize()
        #expect(!controller.isExpanded)
        controller.expand()
        #expect(controller.isExpanded)

        // The next call starts as its own kind says, not as the last was left.
        controller.minimize()
        controller.setScreen(nil)
        controller.setScreen(CallState(sid: "t", peer: peer, direction: .outgoing, phase: .proposing, isVideo: true, isCameraOn: true))
        #expect(controller.isExpanded)
        controller.setScreen(CallState(sid: "u", peer: peer, direction: .outgoing, phase: .proposing, isVideo: false, isCameraOn: false))
        #expect(!controller.isExpanded)
        controller.setScreen(nil)
    }

    @Test func theRingbackPlaysOnlyWhileOurOwnCallWaitsForTheOtherEnd() {
        for phase in phases {
            let expected = phase == .proposing || phase == .ringing
            #expect(CallController.ringbackPlays(for: state(phase)) == expected, "\(phase)")
            #expect(!CallController.ringbackPlays(for: state(phase, .incoming)), "incoming \(phase)")
        }
        #expect(!CallController.ringbackPlays(for: nil))
    }

    @Test func theRingbackIsTwoSecondsOnAndFourOffWithShortFades() {
        let rate = 48_000.0
        func envelope(_ seconds: Double) -> Double { RingbackTone.envelope(frame: Int(seconds * rate), sampleRate: rate) }
        #expect(envelope(0) == 0)
        #expect(envelope(0.01) > 0 && envelope(0.01) < 1)
        #expect(envelope(0.5) == 1)
        #expect(envelope(1.99) > 0 && envelope(1.99) < 1)
        #expect(envelope(2.0) == 0)
        #expect(envelope(4.0) == 0)
        #expect(envelope(5.99) == 0)
        // The cadence repeats.
        #expect(envelope(6.5) == 1)
        #expect(envelope(8.5) == 0)
        #expect(RingbackTone.sample(frame: Int(3 * rate), sampleRate: rate) == 0)
        // Both partials together stay near -12 dBFS.
        let peak = (0..<Int(rate)).map { abs(RingbackTone.sample(frame: Int(0.5 * rate) + $0 % 4800, sampleRate: rate)) }.max()!
        #expect(peak > 0.1 && peak <= 0.25)
    }

    @Test func theScreenStaysAwakeOnlyForAVideoCallThatIsNotOver() {
        #expect(CallController.keepsScreenAwake(for: state(.active, video: true)))
        #expect(CallController.keepsScreenAwake(for: state(.ringing, video: true)))
        #expect(!CallController.keepsScreenAwake(for: state(.ended(.completed), video: true)))
        #expect(!CallController.keepsScreenAwake(for: state(.active)))
        #expect(!CallController.keepsScreenAwake(for: nil))
    }

    @Test func aVideoCallWithoutCameraAccessSaysSoAndStartsNothing() async throws {
        let controller = CallController()
        controller.cameraAccess = { false }

        controller.startCall(to: peer, video: true)

        try await waitUntil { controller.error != nil }
        #expect(controller.error?.contains("camera") == true)
        #expect(!controller.isInCall)
    }

    @Test func anAudioCallNeverAsksForTheCamera() async throws {
        let controller = CallController()
        var asked = false
        controller.cameraAccess = { asked = true; return false }

        controller.startCall(to: peer)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!asked)
    }

    @Test func aPeerWhoIsNoLongerCallableIsNotRung() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        controller.prepareCall = { _, _, video in throw CallError.peerNotCallable(video: video) }
        controller.attach(fixture.session)
        defer { controller.detach() }

        controller.startCall(to: fixture.peer)

        try await waitUntil { controller.error != nil }
        #expect(controller.error == "This contact can't take a call right now.")
        #expect(fixture.session.callState.value == nil)
        #expect(controller.startingCall == nil)
    }

    @Test func aCallWaitsForTheConnectionBeforeAskingAnythingOfTheSystem() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        let release = AsyncStream<Void>.makeStream()
        controller.prepareCall = { _, _, _ in for await _ in release.stream { return } }
        controller.attach(fixture.session)
        defer { controller.detach() }

        controller.startCall(to: fixture.peer)
        #expect(controller.startingCall == fixture.peer)
        // A second tap while the first waits does nothing.
        controller.startCall(to: JID("other@example.com")!)
        #expect(controller.startingCall == fixture.peer)
        #expect(controller.error == nil)

        release.continuation.finish()
        try await waitUntil { controller.startingCall == nil }
        #expect(controller.startingCall == nil)
    }

    // The wait can outlast another call coming in and being answered; the
    // session's call would then be cut, or an error blamed on this one.
    @Test func aCallThatBecameBusyDuringTheWaitIsNotStarted() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        let release = AsyncStream<Void>.makeStream()
        controller.prepareCall = { _, _, _ in for await _ in release.stream { return } }
        controller.attach(fixture.session)
        defer { controller.detach() }
        controller.startCall(to: fixture.peer)

        let other = JID("carol@example.org")!
        fixture.session.callState.send(CallState(sid: "live", peer: other, direction: .incoming, phase: .active, isVideo: false, isCameraOn: false))
        release.continuation.finish()

        try await waitUntil { controller.startingCall == nil }
        #expect(controller.error == "You're already in a call.")
        #expect(fixture.session.callState.value?.sid == "live")
    }

    @Test func theCallButtonsAreOffForEveryChatWhileOneCallIsPrepared() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        let release = AsyncStream<Void>.makeStream()
        controller.prepareCall = { _, _, _ in for await _ in release.stream { return } }
        controller.attach(fixture.session)
        defer { controller.detach() }
        #expect(controller.canStartCall)

        controller.startCall(to: fixture.peer)

        #expect(!controller.canStartCall)
        release.continuation.finish()
        try await waitUntil { controller.startingCall == nil }
    }

    @Test func onlyTheButtonThatWasTappedSpins() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        let release = AsyncStream<Void>.makeStream()
        controller.cameraAccess = { true }
        controller.prepareCall = { _, _, _ in for await _ in release.stream { return } }
        controller.attach(fixture.session)
        defer { controller.detach() }

        controller.startCall(to: fixture.peer, video: true)
        try await waitUntil { controller.isStarting(fixture.peer, video: true) }

        #expect(controller.isStarting(fixture.peer, video: true))
        #expect(!controller.isStarting(fixture.peer, video: false))
        #expect(!controller.isStarting(JID("other@example.com")!, video: true))
        release.continuation.finish()
        try await waitUntil { controller.startingCall == nil }
    }

    @Test func aFailedCallHasItsErrorWhenTheSpinnerStops() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        controller.prepareCall = { _, _, _ in throw CallError.notConnected }
        controller.attach(fixture.session)
        defer { controller.detach() }

        controller.startCall(to: fixture.peer)

        // Chat settings keeps its sheet open until the spinner stops, unless
        // there is an error to show in it, so the error can't come later.
        try await waitUntil { controller.startingCall == nil }
        #expect(controller.error != nil)
    }

    @Test func aCallThatCantBePreparedShowsWhyAndStopsSpinning() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        controller.prepareCall = { _, _, _ in throw CallError.notConnected }
        controller.attach(fixture.session)
        defer { controller.detach() }

        controller.startCall(to: fixture.peer)

        try await waitUntil { controller.error != nil }
        #expect(controller.error == "You're offline.")
        #expect(controller.startingCall == nil)
    }

    @Test func aPeerWhoTakesOnlyAudioIsNotRungForVideo() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        controller.cameraAccess = { true }
        controller.prepareCall = { _, _, video in throw CallError.peerNotCallable(video: video) }
        controller.attach(fixture.session)
        defer { controller.detach() }

        controller.startCall(to: fixture.peer, video: true)

        try await waitUntil { controller.error != nil }
        #expect(controller.error == "This contact can't take a video call right now.")
    }

    /// How often `line` is in the exported log. The log outlives a test run
    /// and other tests write to it, so a test compares counts.
    private func logged(_ line: String) throws -> Int {
        let text = try String(contentsOf: DiagnosticsExport.make(), encoding: .utf8)
        return text.components(separatedBy: line).count - 1
    }

    @Test func aVideoCallWithoutCameraAccessLeavesAReasonInTheLog() async throws {
        let controller = CallController()
        controller.cameraAccess = { false }
        let before = try logged("Call not started reason=noCameraAccess")

        controller.startCall(to: peer, video: true)

        try await waitUntil { controller.error != nil }
        #expect(try logged("Call not started reason=noCameraAccess") > before)
        #expect(try logged("Call asked for video=true camera=") > 0)
    }

    @Test func aPeerWhoIsNotCallableLeavesAReasonInTheLog() async throws {
        let fixture = try ConversationFixture()
        let controller = CallController()
        controller.prepareCall = { _, _, video in throw CallError.peerNotCallable(video: video) }
        controller.attach(fixture.session)
        defer { controller.detach() }
        let before = try logged("Call not started reason=peerNotCallable video=false")

        controller.startCall(to: fixture.peer)

        try await waitUntil { controller.error != nil }
        #expect(try logged("Call not started reason=peerNotCallable video=false") > before)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }
}

struct CallSummaryTests {
    private func summary(_ outcome: CallOutcome, video: Bool, _ direction: Message.Direction = .outgoing) -> CallSummary {
        CallSummary(outcome: outcome, direction: direction, duration: nil, isVideo: video)
    }

    @Test func theSymbolFollowsTheOutcomeAndWhetherItHadVideo() {
        #expect(summary(.answered, video: true).symbol == "video")
        #expect(summary(.cancelled, video: true).symbol == "video")
        #expect(summary(.missed, video: true).symbol == "video.slash")
        #expect(summary(.declined, video: true).symbol == "phone.down")
        #expect(summary(.busy, video: true).symbol == "phone.down")
        #expect(summary(.failed, video: true).symbol == "phone.down")

        #expect(summary(.answered, video: false).symbol == "phone.arrow.up.right")
        #expect(summary(.answered, video: false, .incoming).symbol == "phone.arrow.down.left")
        #expect(summary(.cancelled, video: false).symbol == "phone.arrow.up.right")
        #expect(summary(.missed, video: false, .incoming).symbol == "phone.down")
        #expect(summary(.declined, video: false).symbol == "phone.down")
        #expect(summary(.busy, video: false).symbol == "phone.down")
        #expect(summary(.failed, video: false).symbol == "phone.down")
    }

    @Test func theSnippetIsMarkedByWhetherItHadVideo() {
        #expect(summary(.answered, video: true).snippet.hasPrefix("📹 "))
        #expect(summary(.missed, video: true).snippet.hasPrefix("📹 "))
        #expect(summary(.answered, video: false).snippet.hasPrefix("📞 "))
        #expect(summary(.missed, video: false).snippet.hasPrefix("📞 "))
    }

    @Test func anAnsweredCallIsTwoLinesAndOnlyTheEndHasTheLength() {
        let start = CallSummary(outcome: .answered, direction: .outgoing, duration: 151)
        #expect(start.title == "Outgoing call")
        #expect(CallSummary(outcome: .answered, direction: .incoming, duration: 42, isVideo: true).title == "Incoming video call")
        for video in [false, true] {
            let end = CallSummary(outcome: .answered, direction: .outgoing, duration: 151, isVideo: video, isEnd: true)
            #expect(end.title == "Call ended · 2:31")
            #expect(end.symbol == "phone.down")
            #expect(end.snippet == "\(video ? "📹" : "📞") Call ended · 2:31")
        }
        #expect(CallSummary(outcome: .answered, direction: .incoming, duration: 42, isEnd: true).title == "Call ended · 0:42")
    }

    @Test func aCallBackHasVideoOnlyIfTheCallDidAndThePeerTakesIt() {
        #expect(summary(.answered, video: true).callsBackWithVideo(peerTakesVideo: true))
        #expect(!summary(.answered, video: true).callsBackWithVideo(peerTakesVideo: false))
        #expect(!summary(.answered, video: false).callsBackWithVideo(peerTakesVideo: true))
        #expect(!summary(.answered, video: false).callsBackWithVideo(peerTakesVideo: false))
    }
}
