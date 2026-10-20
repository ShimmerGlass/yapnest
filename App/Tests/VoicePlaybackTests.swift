import Foundation
import Testing
@testable import Yapnest

/// A clip's use of the audio session, which a call needs to itself.
@MainActor
struct VoicePlaybackTests {
    final class FakeSession: VoiceAudioSession, @unchecked Sendable {
        var began = 0
        var recordingBegan = 0
        var ended = 0
        var abandoned = 0
        var playbackFailure: Error?
        var recordingFailure: Error?
        func beginPlayback() throws {
            if let playbackFailure { throw playbackFailure }
            began += 1
        }
        func beginRecording() throws {
            if let recordingFailure { throw recordingFailure }
            recordingBegan += 1
        }
        func end() { ended += 1 }
        func abandon() { abandoned += 1 }
    }

    private func sound() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        try InteractionsFixture.writeSound(to: url, seconds: 2, amplitude: 0)
        return url
    }

    @Test func playingTakesTheSessionAndStoppingGivesItBack() throws {
        let session = FakeSession()
        let playback = VoicePlayback(session: session)
        #expect(playback.toggle(id: 1, file: try sound()) == .started)
        #expect(session.began == 1)
        playback.stop()
        #expect(session.ended == 1)
        #expect(playback.current == nil)
    }

    @Test func aClipThatCantBeLoadedGivesTheSessionBack() throws {
        let session = FakeSession()
        let playback = VoicePlayback(session: session)
        let notSound = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try Data("not sound".utf8).write(to: notSound)
        #expect(playback.toggle(id: 1, file: notSound) == .failed)
        #expect(session.began == 1)
        #expect(session.ended == 1, "the session stays taken, and other apps' sound stays paused")
        #expect(playback.current == nil)
    }

    @Test func aCallTakingTheSessionMakesItForgetWhatToPutBack() throws {
        let session = FakeSession()
        let playback = VoicePlayback(session: session)
        playback.isInCall = true
        #expect(session.abandoned == 1)
        #expect(session.ended == 0)
    }

    @Test func aClipDoesNotStartDuringACall() throws {
        let session = FakeSession()
        let playback = VoicePlayback(session: session)
        playback.isInCall = true
        #expect(playback.toggle(id: 1, file: try sound()) == .refusedInCall)
        #expect(session.began == 0)
        #expect(playback.current == nil)
    }

    @Test func aCallStartingMidClipStopsItWithoutTouchingTheSession() throws {
        let session = FakeSession()
        let playback = VoicePlayback(session: session)
        #expect(playback.toggle(id: 1, file: try sound()) == .started)
        playback.isInCall = true
        #expect(playback.current == nil)
        #expect(!playback.isPlaying)
        #expect(session.ended == 0)
        #expect(session.began == 1)
    }

    @Test func theBubbleSeesOnlyWholeSecondsAndSteps() throws {
        let playback = VoicePlayback(session: FakeSession())
        #expect(playback.toggle(id: 1, file: try sound()) == .started)
        #expect(playback.seconds == 0)
        playback.seek(id: 1, file: try sound(), to: 0.5)
        #expect(playback.seconds == 1)
        #expect(playback.playedFraction == 0.5)
        playback.stop()
        #expect(playback.playedFraction == 0)
    }
}
