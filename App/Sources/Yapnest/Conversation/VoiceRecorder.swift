import AVFoundation
import Foundation
import YapnestKit

/// What records the sound: AVAudioRecorder, or a stand-in for tests.
@MainActor
protocol VoiceRecordingEngine: AnyObject {
    /// Starts recording into a new file, which `stop()` or `discard()` ends.
    /// Setting up the audio session takes a while, so this waits for it
    /// without holding up the main thread.
    func start() async throws
    /// Seconds recorded so far.
    var currentTime: TimeInterval { get }
    /// The current loudness, 0...1.
    var level: Float { get }
    /// Ends the recording and gives the file.
    func stop() -> URL?
    /// Ends it and deletes the file.
    func discard()
}

/// A voice message being recorded: held down to record and let go to send,
/// slid away to cancel, or tapped to record until it is sent or cancelled
/// (which is also how a mouse click works on the Mac). The decisions are
/// `VoiceRecordingRules`; this carries them out and tells the composer, which
/// only draws.
@MainActor
final class VoiceRecorder {
    enum Phase: Equatable {
        case idle
        /// Asking for the microphone or setting the session up.
        case starting
        /// The button is still down.
        case holding
        /// Recording on its own, until sent or cancelled.
        case locked
    }

    /// Why a recording didn't start.
    enum Refusal: Equatable {
        case inCall
        case microphoneDenied
        case failed(String)
    }

    private(set) var phase = Phase.idle {
        didSet { if phase != oldValue { onChange?() } }
    }
    /// The button has been slid far enough that letting go cancels.
    private(set) var willCancel = false {
        didSet { if willCancel != oldValue { onChange?() } }
    }

    var onChange: (() -> Void)?
    var onFinished: ((_ file: URL) -> Void)?
    var onTooShort: (() -> Void)?
    var onRefused: ((Refusal) -> Void)?

    private let engine: VoiceRecordingEngine
    private let audio: VoicePlayback
    private let requestMicrophone: () async -> Bool
    private let isMicrophoneUndetermined: () -> Bool
    private let now: () -> TimeInterval
    /// When the button went down, which a hold is measured from.
    private var pressStarted: TimeInterval = 0
    /// The button came up before the recording had started.
    private var releasedWhileStarting = false
    /// When the finger came up during the start, which is what a tap or a
    /// hold is measured to, however long the start took after it.
    private var releasedAt: TimeInterval?
    /// The system is asking for the microphone for this press, so the finger
    /// that comes up is answering that, not holding a button.
    private var promptShown = false
    /// The engine is setting up. A new press waits until it is done.
    private var engineStarting = false
    /// Which press the start under way belongs to, so one that was cancelled
    /// doesn't go on to start a recording for the next.
    private var attempt = 0

    init(
        engine: VoiceRecordingEngine,
        audio: VoicePlayback = .shared,
        requestMicrophone: @escaping () async -> Bool = VoiceMicrophone.request,
        isMicrophoneUndetermined: @escaping () -> Bool = VoiceMicrophone.isUndetermined,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.engine = engine
        self.audio = audio
        self.requestMicrophone = requestMicrophone
        self.isMicrophoneUndetermined = isMicrophoneUndetermined
        self.now = now
    }

    var isRecording: Bool { phase == .holding || phase == .locked }
    var elapsed: TimeInterval { isRecording ? engine.currentTime : 0 }
    var level: Float { isRecording ? engine.level : 0 }

    /// The button went down. `locked` is for VoiceOver and the like, which
    /// can't hold a button: the recording stays on once started.
    func press(locked: Bool = false) {
        guard phase == .idle, !engineStarting else { return }
        // The microphone is in use by the call, and a recording would take
        // the audio session out from under it.
        guard !audio.isInCall else {
            onRefused?(.inCall)
            return
        }
        audio.activeRecorder = self
        phase = .starting
        releasedWhileStarting = false
        releasedAt = nil
        willCancel = false
        pressStarted = now()
        promptShown = isMicrophoneUndetermined()
        attempt += 1
        let mine = attempt
        Task { [weak self] in
            guard let self else { return }
            let granted = await requestMicrophone()
            guard attempt == mine, phase == .starting else { return }
            guard granted else {
                phase = .idle
                onRefused?(.microphoneDenied)
                return
            }
            // A press that was spent on the permission question is over when
            // the finger is up. Otherwise it is a tap or a hold like any,
            // that the start only delayed.
            guard locked || !(releasedWhileStarting && promptShown) else {
                phase = .idle
                return
            }
            engineStarting = true
            do {
                try await engine.start()
            } catch {
                engineStarting = false
                guard attempt == mine, phase == .starting else { return }
                phase = .idle
                onRefused?(.failed(error.localizedDescription))
                return
            }
            engineStarting = false
            // Cancelled while it started: the recording that began is not wanted.
            guard attempt == mine, phase == .starting else {
                engine.discard()
                return
            }
            phase = locked ? .locked : .holding
            if releasedWhileStarting, !locked { release(at: releasedAt) }
        }
    }

    /// The finger or pointer moved, `slide` points toward the cancelling side.
    func slide(_ slide: Double) {
        guard phase == .holding else { return }
        willCancel = slide >= VoiceRecordingRules.cancelDistance
    }

    /// The button came up.
    func release() {
        release(at: nil)
    }

    private func release(at time: TimeInterval?) {
        switch phase {
        case .starting:
            releasedWhileStarting = true
            releasedAt = now()
        case .holding:
            switch VoiceRecordingRules.release(pressDuration: (time ?? now()) - pressStarted, willCancel: willCancel) {
            case .lock: phase = .locked
            case .send: finish()
            case .cancel: cancel()
            }
        case .idle, .locked:
            break
        }
    }

    /// Ends the recording and sends it, unless it is too short.
    func finish() {
        guard isRecording else { return }
        let duration = engine.currentTime
        phase = .idle
        willCancel = false
        guard VoiceRecordingRules.isSendable(duration) else {
            engine.discard()
            onTooShort?()
            return
        }
        if let file = engine.stop() { onFinished?(file) }
    }

    func cancel() {
        guard phase != .idle else { return }
        let wasRecording = isRecording
        phase = .idle
        willCancel = false
        if wasRecording { engine.discard() }
    }

    /// The app is covered. A recording goes, as the microphone isn't ours; a
    /// start waiting on the permission prompt, which covers the app too, goes on.
    func appWillResignActive() {
        if isRecording { cancel() }
    }

    /// Called as the clock ticks: a recording at its limit is sent.
    func tick() {
        if isRecording, engine.currentTime >= VoiceRecordingRules.maximumDuration { finish() }
    }
}

enum VoiceMicrophone {
    /// Whether the system is yet to ask.
    static func isUndetermined() -> Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    static func request() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// AVAudioRecorder writing AAC in an .m4a: mono at 44.1 kHz and 40 kbit/s,
/// which is clear for speech and about 300 KB a minute. It holds the audio
/// session for as long as it records and gives it back, with what it was
/// set to, afterwards.
@MainActor
final class SystemVoiceRecordingEngine: VoiceRecordingEngine {
    nonisolated static let fileName = "Voice message.m4a"

    private var recorder: AVAudioRecorder?
    private var folder: URL?
    private var interruption: NSObjectProtocol?
    private let audio: VoicePlayback
    /// Called when the system ends the recording (a call, Siri), which
    /// leaves nothing worth sending.
    var onInterrupted: (() -> Void)?

    /// A call has the audio session, which `audio` says, and which is then
    /// left as the call has it.
    init(audio: VoicePlayback = .shared) {
        self.audio = audio
    }

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return VoiceRecordingRules.meterLevel(decibels: recorder.averagePower(forChannel: 0))
    }

    private struct Started: @unchecked Sendable {
        var recorder: AVAudioRecorder
        var folder: URL
    }

    func start() async throws {
        let session = audio.session
        let started: Started
        do {
            started = try await Task.detached(priority: .userInitiated) { try Self.begin(session) }.value
        } catch {
            releaseSession()
            throw error
        }
        recorder = started.recorder
        folder = started.folder
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.onInterrupted?() }
        }
    }

    private nonisolated static func begin(_ session: VoiceAudioSession) throws -> Started {
        try session.beginRecording()
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 40_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: folder.appending(path: fileName), settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: VoiceRecordingRules.maximumDuration + 1) else { throw RecorderError.refused }
            return Started(recorder: recorder, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func stop() -> URL? {
        guard let recorder, let folder else { return nil }
        recorder.stop()
        end()
        return folder.appending(path: Self.fileName)
    }

    func discard() {
        recorder?.stop()
        let folder = folder
        end()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func end() {
        recorder = nil
        folder = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        releaseSession()
    }

    /// Gives the session back, unless a call has it.
    private func releaseSession() {
        if !audio.isInCall { audio.session.end() }
    }

    private enum RecorderError: LocalizedError {
        case refused
        var errorDescription: String? { String(localized: "The recording couldn't be started.") }
    }
}
