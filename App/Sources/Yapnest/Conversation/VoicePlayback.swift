import AVFoundation
import Foundation
import Observation

/// What playing and recording do to the app's one audio session. Not tied to
/// the main actor: setting the session up can take a while, and recording does
/// it elsewhere.
protocol VoiceAudioSession: AnyObject, Sendable {
    func beginPlayback() throws
    func beginRecording() throws
    /// Gives the session back, so other apps' sound goes on, and puts back the
    /// category it had before.
    func end()
    /// Forgets what to put back, because a call took the session and now owns it.
    func abandon()
}

final class SystemVoiceAudioSession: VoiceAudioSession, @unchecked Sendable {
    private struct Saved {
        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode
        var options: AVAudioSession.CategoryOptions
    }

    private let lock = NSLock()
    private var saved: Saved?

    func beginPlayback() throws {
        try activate(.playback, mode: .spokenAudio, options: [])
    }

    func beginRecording() throws {
        try activate(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    /// What the session was set to is kept only the first time: a second
    /// start before an end would otherwise keep our own setting as the one to go back to.
    private func activate(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        let session = AVAudioSession.sharedInstance()
        lock.withLock {
            if saved == nil { saved = Saved(category: session.category, mode: session.mode, options: session.categoryOptions) }
        }
        do {
            try session.setCategory(category, mode: mode, options: options)
            try session.setActive(true)
        } catch {
            end()
            throw error
        }
    }

    func end() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previous = lock.withLock({ defer { saved = nil }; return saved }) {
            try? session.setCategory(previous.category, mode: previous.mode, options: previous.options)
        }
    }

    func abandon() {
        lock.withLock { saved = nil }
    }
}

/// Plays the sound of one voice message at a time, and owns what voice
/// recording and playback share: the audio session, and whether a call has it.
/// It is shared, so starting a clip stops the one before it, in this chat or
/// another.
///
/// A bubble reads `seconds` and `playedFraction` only while its own clip is
/// the current one. They change a few times a second at most, so the clock
/// ticking redraws that bubble only when what it shows is different.
@MainActor
@Observable
final class VoicePlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayback()

    enum Result {
        case started
        case refusedInCall
        case failed
    }

    /// Set by the call controller. A call has the audio session, and what we
    /// do to it (another category, deactivating it) would cut the call's
    /// sound, so nothing here touches it while one is on. A call starting
    /// stops the clip and the recording, and leaves the session as the call has it.
    @ObservationIgnored var isInCall = false {
        didSet {
            guard isInCall, !oldValue else { return }
            stop()
            activeRecorder?.cancel()
            session.abandon()
        }
    }

    /// The recorder that was last started, which a call cancels.
    @ObservationIgnored weak var activeRecorder: VoiceRecorder?

    /// The message whose clip is loaded, playing or paused.
    private(set) var current: Int64?
    private(set) var isPlaying = false
    /// Whole seconds into the current clip.
    private(set) var seconds = 0
    /// How far into the clip, in steps of `fractionSteps`.
    private(set) var playedFraction = 0.0

    private static let fractionSteps = 64.0

    @ObservationIgnored let session: VoiceAudioSession
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    init(session: VoiceAudioSession = SystemVoiceAudioSession()) {
        self.session = session
        super.init()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func isPlaying(_ id: Int64) -> Bool { current == id && isPlaying }

    /// Plays the clip, or pauses it if it is the one playing, or goes on
    /// where it was paused.
    @discardableResult
    func toggle(id: Int64, file: URL) -> Result {
        guard current == id, player != nil else { return start(id: id, file: file, at: 0) }
        if isPlaying { pause() } else { resume() }
        return .started
    }

    /// Plays from `fraction` of the clip's length.
    @discardableResult
    func seek(id: Int64, file: URL, to fraction: Double) -> Result {
        let fraction = min(1, max(0, fraction))
        guard current == id, let player else { return start(id: id, file: file, at: fraction) }
        player.currentTime = fraction * player.duration
        publish(player)
        if !isPlaying { resume() }
        return .started
    }

    func stop() {
        guard current != nil else { return }
        player?.stop()
        reset()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopClock()
    }

    private func resume() {
        player?.play()
        isPlaying = true
        startClock()
    }

    private func start(id: Int64, file: URL, at fraction: Double) -> Result {
        stop()
        guard !isInCall else { return .refusedInCall }
        do {
            try session.beginPlayback()
        } catch {
            return .failed
        }
        do {
            let player = try AVAudioPlayer(contentsOf: file)
            player.delegate = self
            guard player.prepareToPlay() else { throw PlaybackError.unplayable }
            player.currentTime = fraction * player.duration
            guard player.play() else { throw PlaybackError.unplayable }
            self.player = player
        } catch {
            // The session was taken for a clip that isn't playing.
            session.end()
            return .failed
        }
        current = id
        isPlaying = true
        if let player { publish(player) }
        startClock()
        return .started
    }

    private func reset() {
        stopClock()
        player = nil
        current = nil
        isPlaying = false
        seconds = 0
        playedFraction = 0
        // Whatever was playing before (music) goes on.
        endSession()
    }

    /// Gives the session back, unless a call has it.
    func endSession() {
        if !isInCall { session.end() }
    }

    /// Only what the bubble draws is published: the raw time changes every tick.
    private func publish(_ player: AVAudioPlayer) {
        let time = player.currentTime
        if Int(time) != seconds { seconds = Int(time) }
        let fraction = player.duration > 0 ? (time / player.duration * Self.fractionSteps).rounded(.down) / Self.fractionSteps : 0
        if fraction != playedFraction { playedFraction = fraction }
    }

    private func startClock() {
        stopClock()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.publish(player)
            }
        }
        timer.tolerance = 0.02
        // In the common modes, or it stops while a list is being scrolled.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    private enum PlaybackError: Error {
        case unplayable
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.player.map(ObjectIdentifier.init) == finished else { return }
            self.reset()
        }
    }
}
