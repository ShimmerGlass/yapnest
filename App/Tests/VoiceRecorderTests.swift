import Foundation
import Testing
import UIKit
import YapnestKit
@testable import Yapnest

/// A voice message recording from the button going down to the message
/// leaving, with the microphone and the clock played by the test.
@MainActor
struct VoiceRecorderTests {
    @MainActor
    final class FakeEngine: VoiceRecordingEngine {
        var time: TimeInterval = 0
        var started = 0
        var discarded = 0
        var failure: Error?
        /// While set, `start()` waits for `finishStart()`, as setting up the session does.
        var holdsStart = false
        private var startGate: CheckedContinuation<Void, Never>?
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        func finishStart() {
            startGate?.resume()
            startGate = nil
        }

        var isStarting: Bool { startGate != nil }

        func start() async throws {
            if holdsStart { await withCheckedContinuation { startGate = $0 } }
            if let failure { throw failure }
            started += 1
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "Voice message.m4a"))
        }

        var currentTime: TimeInterval { time }
        var level: Float { 0.5 }

        func stop() -> URL? {
            folder.appending(path: "Voice message.m4a")
        }

        func discard() { discarded += 1 }
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "no microphone" }
    }

    private final class Outcome {
        var sent: [URL] = []
        var tooShort = 0
        var refusals: [VoiceRecorder.Refusal] = []
    }

    private struct Setup {
        let recorder: VoiceRecorder
        let engine: FakeEngine
        let outcome: Outcome
        let clock: Clock
        let audio: VoicePlayback
    }

    private final class Clock {
        var now: TimeInterval = 100
    }

    private func make(inCall: Bool = false, granted: Bool = true, prompts: Bool = false) -> Setup {
        let engine = FakeEngine()
        let clock = Clock()
        let outcome = Outcome()
        let audio = VoicePlayback(session: VoicePlaybackTests.FakeSession())
        audio.isInCall = inCall
        let recorder = VoiceRecorder(engine: engine, audio: audio, requestMicrophone: { granted }, isMicrophoneUndetermined: { prompts }, now: { clock.now })
        recorder.onFinished = { outcome.sent.append($0) }
        recorder.onTooShort = { outcome.tooShort += 1 }
        recorder.onRefused = { outcome.refusals.append($0) }
        return Setup(recorder: recorder, engine: engine, outcome: outcome, clock: clock, audio: audio)
    }

    /// Lets the start under way finish.
    private func started(_ recorder: VoiceRecorder) async {
        for _ in 0..<100 where recorder.phase == .starting { await Task.yield() }
    }

    @Test func holdingThenReleasingSendsTheRecording() async {
        let s = make()
        s.recorder.press()
        #expect(s.recorder.phase == .starting)
        await started(s.recorder)
        #expect(s.recorder.phase == .holding)
        s.clock.now += 4
        s.engine.time = 4
        s.recorder.release()
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.sent.count == 1)
        #expect(s.engine.discarded == 0)
    }

    @Test func aTapKeepsRecordingUntilSent() async {
        let s = make()
        s.recorder.press()
        await started(s.recorder)
        s.clock.now += 0.1
        s.engine.time = 0.1
        s.recorder.release()
        #expect(s.recorder.phase == .locked)
        #expect(s.outcome.sent.isEmpty)
        s.engine.time = 6
        s.recorder.finish()
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.sent.count == 1)
    }

    @Test func aLockedRecordingCanBeCancelled() async {
        let s = make()
        s.recorder.press(locked: true)
        await started(s.recorder)
        #expect(s.recorder.phase == .locked)
        s.recorder.cancel()
        #expect(s.recorder.phase == .idle)
        #expect(s.engine.discarded == 1)
        #expect(s.outcome.sent.isEmpty)
    }

    @Test func slidingAwayCancelsOnRelease() async {
        let s = make()
        s.recorder.press()
        await started(s.recorder)
        s.recorder.slide(30)
        #expect(!s.recorder.willCancel)
        s.recorder.slide(VoiceRecordingRules.cancelDistance + 1)
        #expect(s.recorder.willCancel)
        s.clock.now += 5
        s.engine.time = 5
        s.recorder.release()
        #expect(s.recorder.phase == .idle)
        #expect(!s.recorder.willCancel)
        #expect(s.engine.discarded == 1)
        #expect(s.outcome.sent.isEmpty)
        #expect(s.outcome.tooShort == 0)
    }

    @Test func slidingBackUndoesTheCancel() async {
        let s = make()
        s.recorder.press()
        await started(s.recorder)
        s.recorder.slide(200)
        s.recorder.slide(0)
        #expect(!s.recorder.willCancel)
        s.clock.now += 5
        s.engine.time = 5
        s.recorder.release()
        #expect(s.outcome.sent.count == 1)
    }

    @Test func aRecordingUnderHalfASecondIsDropped() async {
        let s = make()
        s.recorder.press()
        await started(s.recorder)
        s.clock.now += 1
        s.engine.time = 0.4
        s.recorder.release()
        #expect(s.outcome.sent.isEmpty)
        #expect(s.outcome.tooShort == 1)
        #expect(s.engine.discarded == 1, "the short recording's file stays")
    }

    @Test func aRecordingAtTheLimitIsSentByTheClock() async {
        let s = make()
        s.recorder.press(locked: true)
        await started(s.recorder)
        s.engine.time = VoiceRecordingRules.maximumDuration - 1
        s.recorder.tick()
        #expect(s.recorder.phase == .locked)
        s.engine.time = VoiceRecordingRules.maximumDuration
        s.recorder.tick()
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.sent.count == 1)
    }

    @Test func aCallStartingMidRecordingDropsTheRecording() async {
        let s = make()
        s.recorder.press(locked: true)
        await started(s.recorder)
        s.engine.time = 20
        s.audio.isInCall = true
        #expect(s.recorder.phase == .idle)
        #expect(s.engine.discarded == 1)
        #expect(s.outcome.sent.isEmpty)
        #expect(s.outcome.tooShort == 0)
    }

    @Test func aClipDoesNotStartUnderARunningRecording() async throws {
        let s = make()
        s.recorder.press(locked: true)
        await started(s.recorder)
        #expect(s.recorder.phase == .locked)
        let clip = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        try InteractionsFixture.writeSound(to: clip, seconds: 2, amplitude: 0)
        let session = try #require(s.audio.session as? VoicePlaybackTests.FakeSession)
        #expect(await s.audio.toggle(id: 1, file: clip) != .started)
        #expect(session.began == 0, "playback would switch the session under the recorder")
        s.audio.stop()
        #expect(session.ended == 0, "and ending it would cut the recorder's session")
        #expect(s.recorder.phase == .locked)
    }

    @Test func aRecordingThatBeginsWhileAClipLoadsKeepsTheSession() async throws {
        let s = make()
        let session = try #require(s.audio.session as? VoicePlaybackTests.FakeSession)
        let clip = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        try InteractionsFixture.writeSound(to: clip, seconds: 2, amplitude: 0)
        let blocker = DispatchSemaphore(value: 0)
        let entered = VoicePlaybackTests.Flag()
        let hold = Task { try await s.audio.perform { entered.value = true; blocker.wait() } }
        await eventually("queue held") { entered.value }
        let clipStart = Task { await s.audio.toggle(id: 1, file: clip) }
        await eventually("begin queued") { s.audio.isStarting }

        s.recorder.press(locked: true)
        blocker.signal()

        #expect(await clipStart.value == .refusedWhileRecording)
        try await hold.value
        await s.audio.settled()
        #expect(s.audio.current == nil)
        #expect(session.ended == 0, "the recording owns the session")
    }

    @Test func aClipEndingDuringARecordingLeavesTheSession() async throws {
        let s = make()
        let session = try #require(s.audio.session as? VoicePlaybackTests.FakeSession)
        let clip = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        try InteractionsFixture.writeSound(to: clip, seconds: 2, amplitude: 0)
        #expect(await s.audio.toggle(id: 1, file: clip) == .started)
        s.recorder.press(locked: true)
        await started(s.recorder)

        s.audio.stop()
        await s.audio.settled()
        #expect(session.ended == 0)
    }

    @Test func theRecordingEngineLeavesTheSessionAloneDuringACall() async {
        for (inCall, releases) in [(true, 0), (false, 1)] {
            let session = VoicePlaybackTests.FakeSession()
            let audio = VoicePlayback(session: session)
            audio.isInCall = inCall
            SystemVoiceRecordingEngine(audio: audio).discard()
            await audio.settled()
            #expect(session.ended == releases, "in a call: \(inCall)")
        }
    }

    @Test func aFailedStartGivesTheSessionBack() async {
        let session = VoicePlaybackTests.FakeSession()
        session.recordingFailure = Boom()
        let audio = VoicePlayback(session: session)
        let engine = SystemVoiceRecordingEngine(audio: audio)
        await #expect(throws: Boom.self) { try await engine.start() }
        await audio.settled()
        #expect(session.ended == 1)
    }

    @Test func aFailedStartDuringACallLeavesTheSessionAlone() async {
        let session = VoicePlaybackTests.FakeSession()
        session.recordingFailure = Boom()
        let audio = VoicePlayback(session: session)
        audio.isInCall = true
        let engine = SystemVoiceRecordingEngine(audio: audio)
        await #expect(throws: Boom.self) { try await engine.start() }
        await audio.settled()
        #expect(session.ended == 0)
    }

    @Test func thePermissionPromptCoveringTheAppDoesNotEndTheStart() async {
        let engine = FakeEngine()
        var allow: CheckedContinuation<Bool, Never>?
        let recorder = VoiceRecorder(
            engine: engine, audio: VoicePlayback(session: VoicePlaybackTests.FakeSession()),
            requestMicrophone: { await withCheckedContinuation { allow = $0 } }, isMicrophoneUndetermined: { true },
        )
        recorder.press(locked: true)
        for _ in 0..<100 where allow == nil { await Task.yield() }
        // The system's prompt resigns the app active while the press waits on it.
        recorder.appWillResignActive()
        #expect(recorder.phase == .starting)
        allow?.resume(returning: true)
        await started(recorder)
        #expect(recorder.phase == .locked)
        #expect(engine.started == 1)
    }

    @Test func coveringTheAppEndsARecordingThatIsRunning() async {
        let s = make()
        s.recorder.press(locked: true)
        await started(s.recorder)
        s.recorder.appWillResignActive()
        #expect(s.recorder.phase == .idle)
        #expect(s.engine.discarded == 1)
    }

    @Test func aFailedClipExplainsInsteadOfPlaying() {
        #expect(VoiceMessageView.playsOnTap(canPlay: true, isFailed: false))
        #expect(!VoiceMessageView.playsOnTap(canPlay: true, isFailed: true))
        #expect(!VoiceMessageView.playsOnTap(canPlay: false, isFailed: false))
    }

    @Test func nothingIsTypedIntoTheFieldWhileRecording() async {
        let s = make()
        let bar = ConversationInputBar()
        let field = UITextView()
        bar.voice = s.recorder
        #expect(bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "a"))
        s.recorder.press(locked: true)
        await started(s.recorder)
        #expect(!bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "a"))
        s.recorder.cancel()
        #expect(bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "a"))
    }

    @Test func nothingIsRecordedDuringACall() async {
        let s = make(inCall: true)
        s.recorder.press()
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.refusals == [.inCall])
        #expect(s.engine.started == 0)
    }

    @Test func aDeniedMicrophoneIsReported() async {
        let s = make(granted: false)
        s.recorder.press()
        await started(s.recorder)
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.refusals == [.microphoneDenied])
        #expect(s.engine.started == 0)
    }

    @Test func aFailureToStartIsReported() async {
        let s = make()
        s.engine.failure = Boom()
        s.recorder.press()
        await started(s.recorder)
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.refusals == [.failed("no microphone")])
    }

    @Test func aPressLiftedDuringThePermissionPromptRecordsNothing() async {
        let s = make(prompts: true)
        s.recorder.press()
        s.recorder.release()
        await started(s.recorder)
        #expect(s.recorder.phase == .idle)
        #expect(s.engine.started == 0)
    }

    @Test func aFastTapWithTheMicrophoneAlreadyAllowedStillLocks() async {
        let s = make()
        s.recorder.press()
        s.recorder.release()
        await started(s.recorder)
        #expect(s.recorder.phase == .locked)
        #expect(s.engine.started == 1)
    }

    @Test func aFastHoldWithTheMicrophoneAlreadyAllowedIsSentOnceStarted() async {
        let s = make()
        s.recorder.press()
        s.clock.now += 3
        s.engine.time = 3
        s.recorder.release()
        await started(s.recorder)
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.sent.count == 1)
    }

    @Test func theHoldIsMeasuredFromTheFingerGoingDown() async {
        let s = make()
        s.engine.holdsStart = true
        s.recorder.press()
        for _ in 0..<100 where !s.engine.isStarting { await Task.yield() }
        // Setting up took longer than a tap lasts; the finger was down all along.
        s.clock.now += 0.5
        s.engine.time = 1
        s.engine.finishStart()
        await started(s.recorder)
        #expect(s.recorder.phase == .holding)
        s.recorder.release()
        #expect(s.recorder.phase == .idle, "a press that long is a hold, not a tap")
        #expect(s.outcome.sent.count == 1)
    }

    @Test func aTapLiftedBeforeASlowStartStillLocks() async {
        let s = make()
        s.engine.holdsStart = true
        s.recorder.press()
        for _ in 0..<100 where !s.engine.isStarting { await Task.yield() }
        s.clock.now += 0.1
        s.recorder.release()
        // The setup outlasts the tap; the tap is still as long as the finger was down.
        s.clock.now += 0.5
        s.engine.finishStart()
        await started(s.recorder)
        #expect(s.recorder.phase == .locked)
    }

    @Test func aStartCancelledWhileItSetsUpDiscardsWhatItStarted() async {
        let s = make()
        s.engine.holdsStart = true
        s.recorder.press()
        for _ in 0..<100 where !s.engine.isStarting { await Task.yield() }
        s.recorder.cancel()
        // A press meanwhile waits for the setup to finish.
        s.recorder.press()
        #expect(s.recorder.phase == .idle)
        s.engine.finishStart()
        for _ in 0..<100 where s.engine.discarded == 0 { await Task.yield() }
        #expect(s.engine.discarded == 1)
        #expect(s.recorder.phase == .idle)
        #expect(s.outcome.sent.isEmpty)
    }

    @Test func aCancelledStartDoesNotRecordForTheNextPress() async {
        let s = make()
        s.recorder.press()
        s.recorder.cancel()
        s.recorder.press()
        await started(s.recorder)
        #expect(s.recorder.phase == .holding)
        #expect(s.engine.started == 1)
    }

    @Test func aSecondPressWhileRecordingIsIgnored() async {
        let s = make()
        s.recorder.press(locked: true)
        await started(s.recorder)
        s.recorder.press()
        #expect(s.recorder.phase == .locked)
        #expect(s.engine.started == 1)
    }

    @Test func theLevelAndTimeAreOnlyReadWhileRecording() async {
        let s = make()
        s.engine.time = 9
        #expect(s.recorder.elapsed == 0)
        #expect(s.recorder.level == 0)
        s.recorder.press(locked: true)
        await started(s.recorder)
        #expect(s.recorder.elapsed == 9)
        #expect(s.recorder.level == 0.5)
    }
}
