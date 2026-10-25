import Combine
import AVFoundation
import Foundation
import Observation
import UIKit
import YapnestKit

import AVFAudio
import CallKit

import YapnestCallMedia

/// Follows the session's call and keeps CallKit and our call UI in step
/// with it. The session is the source of truth: CallKit is told what happened,
/// and what the user does in CallKit's own screens is passed on to the session.
///
/// The Simulator and the Mac don't use CallKit: the session is driven directly,
/// an incoming call rings in `CallBar`, and `CallRinger` makes the sound.
@MainActor
@Observable
final class CallController {
    /// The call in progress, kept for a moment after it ends so the reason can
    /// be read. Where CallKit is used, only `callBar` shows it; its own screens
    /// are the call's.
    private(set) var screen: CallState?
    /// Whether there is a call. Views that only need this read it instead of
    /// `screen`, which changes with every phase and mute, so they don't redraw.
    private(set) var isInCall = false

    /// Whether the call fills the screen. A call is in the bar unless the user
    /// has expanded it, so it never blocks the app: audio calls start in the
    /// bar and video calls expanded (see `startsExpanded`).
    private(set) var isExpanded = false

    func minimize() { isExpanded = false }

    func expand() {
        if Self.canExpand(screen: screen, usesCallKit: Self.usesCallKit) { isExpanded = true }
    }

    /// A video call is watched, so it opens on its picture. An audio call has
    /// nothing to look at, and the bar is all it needs.
    static func startsExpanded(_ state: CallState) -> Bool { state.isVideo }

    /// Whether our full-screen call view has anything to show: where CallKit
    /// isn't used, and for a video call, which CallKit draws no picture for.
    /// With CallKit, an audio call's screen is CallKit's own. A call that is
    /// still ringing here is answered from the bar, so it doesn't interrupt
    /// what the user is doing; `screen` is only set for an incoming call under
    /// CallKit once answered, so CallKit's ringing stays its own.
    static func canExpand(screen: CallState?, usesCallKit: Bool) -> Bool {
        guard let screen, screen.phase != .incoming else { return false }
        return !usesCallKit || screen.isVideo
    }

    /// Whether our full-screen call view is up.
    var showsCallView: Bool {
        Self.showsCallView(isInCall: isInCall, screen: screen, usesCallKit: Self.usesCallKit, isExpanded: isExpanded)
    }

    static func showsCallView(isInCall: Bool, screen: CallState?, usesCallKit: Bool, isExpanded: Bool) -> Bool {
        isInCall && isExpanded && canExpand(screen: screen, usesCallKit: usesCallKit)
    }

    /// The call for the bar across the top of the app, which is how a user in
    /// the app sees and ends any call that isn't filling the screen. It
    /// lingers with the reason as `screen` does, since CallKit says nothing of
    /// why our own call ended.
    var callBar: CallState? {
        Self.callBar(isInCall: isInCall, screen: screen, usesCallKit: Self.usesCallKit, isExpanded: isExpanded)
    }

    static func callBar(isInCall: Bool, screen: CallState?, usesCallKit: Bool, isExpanded: Bool) -> CallState? {
        isInCall && !showsCallView(isInCall: isInCall, screen: screen, usesCallKit: usesCallKit, isExpanded: isExpanded) ? screen : nil
    }
    /// A failed request to CallKit, for an alert.
    var error: String?

    @ObservationIgnored private var session: XMPPSession?
    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    #if DEBUG
    /// The scripted answer, hang-up and call of the `YAPNEST_DEV_*` hooks.
    @ObservationIgnored private var devTasks: [Task<Void, Never>] = []
    #endif

    /// How long a call's end stays on the screen.
    static let endedLinger: Duration = .milliseconds(1500)

    func attach(_ session: XMPPSession) {
        detach()
        self.session = session
        // Without media the session has no calls, and a provider would only
        // make CallKit list the app as one that takes them.
        guard session.supportsCalls else { return }
        // The unit tests run in the app, and would each make a provider.
        guard !AppModel.isHostingTests else { return }
        // CallKit turns down our own calls until the app has a provider.
        if Self.usesCallKit { _ = provider }
        subscription = session.callState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handle(state) }
        #if DEBUG
        devCallIfRequested()
        #endif
    }

    func setScreen(_ state: CallState?) {
        // Each call starts as its kind says, whatever the last one was left at.
        if let state, state.sid != screen?.sid { isExpanded = Self.startsExpanded(state) }
        screen = state
        // Writing the same value would still notify the views that read it.
        if (state != nil) != isInCall {
            isInCall = state != nil
            // A clip playing or a voice message being recorded lets go of the
            // audio session, which is the call's now.
            VoicePlayback.shared.isInCall = isInCall
        }
        // A video call is watched, not touched, so the screen would dim.
        let keepAwake = Self.keepsScreenAwake(for: state)
        if UIApplication.shared.isIdleTimerDisabled != keepAwake { UIApplication.shared.isIdleTimerDisabled = keepAwake }
    }

    static func keepsScreenAwake(for state: CallState?) -> Bool {
        state.map { $0.isVideo && !$0.isOver } ?? false
    }

    func detach() {
        subscription = nil
        if let session, session.callState.value?.isOver == false { session.hangUpCall() }
        session = nil
        setScreen(nil)
        dismissal?.cancel()
        #if DEBUG
        devTasks.forEach { $0.cancel() }
        devTasks = []
        #endif
        ringer.stop()
        ringback.stop()
        reportAllEnded()
        calls = [:]
        locallyEnded = []
        callKitAudioActive = false
        if !Self.usesCallKit { deactivateAudio() }
    }

    /// Tells CallKit every call it holds is over. The subscription is gone by
    /// then, so the session's own ending would never reach `handle`, and the
    /// system would keep showing a call nothing is behind.
    private func reportAllEnded() {
        guard Self.usesCallKit, !calls.isEmpty else { return }
        for uuid in calls.values where !locallyEnded.contains(uuid) {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
    }

    /// The iOS Simulator's callservicesd ends every call it is given ~50 ms after
    /// accepting it, so there the session is driven directly and the call
    /// bar rings. The Mac has no CallKit to take a call, so it does the same.
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    static let usesCallKit = false
    #else
    static let usesCallKit = true
    #endif

    /// Whether `state` is a call in progress here: our own calls from the first
    /// moment, and incoming ones once answered (CallKit shows the ringing,
    /// except where it isn't used).
    static func showsScreen(for state: CallState) -> Bool {
        switch state.phase {
        case .proposing, .ringing: state.direction == .outgoing
        case .accepted, .connecting, .active: true
        case .incoming: !usesCallKit
        case .ended: false
        }
    }

    private func updateScreen(_ state: CallState?) {
        guard let state else { return }
        if Self.showsScreen(for: state) {
            dismissal?.cancel()
            setScreen(state)
        } else if state.isOver, screen?.sid == state.sid {
            setScreen(state)
            let sid = state.sid
            dismissal?.cancel()
            dismissal = Task { [weak self] in
                try? await Task.sleep(for: Self.endedLinger)
                guard !Task.isCancelled, let self, self.screen?.sid == sid else { return }
                self.setScreen(nil)
            }
        }
    }

    // MARK: CallKit

    @ObservationIgnored private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // The Phone app's recents are a later stage.
        configuration.includesCallsInRecents = false
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(delegate, queue: .main)
        return provider
    }()
    @ObservationIgnored private lazy var delegate = ProviderDelegate(controller: self)
    @ObservationIgnored private let callController = CXCallController()
    /// CallKit's identifier for each call, by the session's.
    @ObservationIgnored private var calls: [String: UUID] = [:]
    /// Calls the user ended through CallKit, which it already knows are over.
    @ObservationIgnored private var locallyEnded: Set<UUID> = []
    /// Incoming calls being reported, so a repeated state doesn't report twice.
    @ObservationIgnored private var reporting: Set<String> = []
    /// Whether this controller activated the audio session, which is only so
    /// where CallKit isn't used.
    @ObservationIgnored private var audioActive = false
    @ObservationIgnored private let ringer = CallRinger()
    @ObservationIgnored private let ringback = RingbackPlayer()
    /// Whether CallKit has activated the audio session, which is when the
    /// ringback may use it.
    @ObservationIgnored private var callKitAudioActive = false

    private func handle(_ state: CallState?) {
        updateScreen(state)
        if state?.phase != .incoming { ringer.stop() }
        updateRingback()
        guard let state, let session else { return }
        let uuid = calls[state.sid]
        switch state.phase {
        case .incoming:
            guard uuid == nil, !reporting.contains(state.sid) else { return }
            reporting.insert(state.sid)
            guard Self.usesCallKit else {
                ring(for: state, session: session)
                #if DEBUG
                devAnswerIfRequested(sid: state.sid)
                #endif
                return
            }
            report(incoming: state, session: session)
        case .proposing, .ringing:
            break
        case .accepted, .connecting:
            if let uuid, state.direction == .outgoing { provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil) }
        case .active:
            if let uuid, state.direction == .outgoing { provider.reportOutgoingCall(with: uuid, connectedAt: state.activeSince) }
            #if DEBUG
            devHangUpIfRequested(sid: state.sid)
            #endif
        case .ended(let reason):
            reporting.remove(state.sid)
            if !Self.usesCallKit { deactivateAudio() }
            guard let uuid else { return }
            calls[state.sid] = nil
            // CallKit ended it itself when the user did.
            if locallyEnded.remove(uuid) != nil { return }
            provider.reportCall(with: uuid, endedAt: Date(), reason: Self.endReason(reason))
        }
    }

    /// The ringback follows the call's phase. It waits for the audio session
    /// where there is one: CallKit activates it after the start action, and
    /// the tone must not activate it first. The Mac has no session to wait for.
    private func updateRingback() {
        #if targetEnvironment(macCatalyst)
        let ready = true
        #else
        let ready = audioActive || callKitAudioActive
        #endif
        if ready, Self.ringbackPlays(for: session?.callState.value) { ringback.start() } else { ringback.stop() }
    }

    static func ringbackPlays(for state: CallState?) -> Bool { RingbackTone.plays(for: state) }

    private func ring(for state: CallState, session: XMPPSession) {
        let peer = state.peer, sid = state.sid, video = state.isVideo
        Task {
            let name = await Self.displayName(of: peer, in: session)
            // It may have been answered or retracted while the name was looked up.
            guard let current = session.callState.value, current.sid == sid, current.phase == .incoming else { return }
            ringer.start(sid: sid, name: name, video: video)
        }
    }

    private func report(incoming state: CallState, session: XMPPSession) {
        let uuid = UUID()
        let peer = state.peer
        let sid = state.sid
        Task {
            let name = await Self.displayName(of: peer, in: session)
            // It may have been retracted while the name was looked up.
            guard let current = session.callState.value, current.sid == sid, current.phase == .incoming else {
                reporting.remove(sid)
                return
            }
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: peer.description)
            update.localizedCallerName = name
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            update.hasVideo = state.isVideo
            calls[sid] = uuid
            do {
                try await provider.reportNewIncomingCall(with: uuid, update: update)
            } catch {
                // Do Not Disturb, or the system won't take another call.
                calls[sid] = nil
                reporting.remove(sid)
                // Only this device gives up on it. Declining would stop the
                // user's other devices ringing and tell the caller no.
                session.dismissIncomingCall()
                return
            }
            #if DEBUG
            devAnswerIfRequested(sid: sid)
            #endif
        }
    }

    static func displayName(of peer: JID, in session: XMPPSession) async -> String {
        let database = session.database
        let contact = await offMain { try? database.contact(peer) }
        return contact?.displayName ?? peer.shortName
    }

    static func endReason(_ reason: CallEndReason) -> CXCallEndedReason {
        switch reason {
        case .failed, .connectionLost: .failed
        case .missed, .noAnswer, .busy, .dismissed: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        // The peer declined or hung up; for ours, CallKit is told by the user's action.
        case .declined, .completed, .cancelled, .tieBreak: .remoteEnded
        }
    }

    // MARK: From the app's screens

    /// Whether the camera may be used, asked for if it isn't known yet.
    /// Tests replace it, as the real one prompts.
    @ObservationIgnored var cameraAccess: () async -> Bool = { await CallController.hasCameraAccess() }

    /// Asks CallKit to start a call, which comes back to `perform(start:)`.
    func startCall(to peer: JID, video: Bool = false) {
        guard video else { return begin(peer, video: false) }
        Task {
            guard await cameraAccess() else {
                error = Platform.isMac
                    ? String(localized: "Yapnest needs the camera for video calls. Turn it on in System Settings > Privacy & Security > Camera.")
                    : String(localized: "Yapnest needs the camera for video calls. Turn it on in Settings > Yapnest.")
                return
            }
            begin(peer, video: true)
        }
    }

    private func begin(_ peer: JID, video: Bool) {
        // The button stays a moment after the peer stops taking calls, so
        // it doesn't blink when they drop out briefly; a tap then gets this
        // rather than a call no device rings for.
        if let session, !(video ? session.videoCallablePeers : session.callablePeers).value.contains(peer) {
            error = video
                ? String(localized: "This contact can't take a video call right now.")
                : String(localized: "This contact can't take a call right now.")
            return
        }
        guard Self.usesCallKit else {
            do {
                try activateAudio(video: video)
                try session?.startCall(to: peer, video: video)
            } catch {
                self.error = error.localizedDescription
                deactivateAudio()
            }
            return
        }
        let handle = CXHandle(type: .generic, value: peer.description)
        let action = CXStartCallAction(call: UUID(), handle: handle)
        action.isVideo = video
        request(action)
    }

    /// Asks if it isn't known yet. The request answers off the main thread.
    private static func hasCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Answers a video call with the camera off when there is no access, so
    /// the caller still gets the call. The prompt, if due, comes after the
    /// answer, as the system's call screen must not wait for it.
    private func limitCameraToAccess() {
        guard session?.callState.value?.isVideo == true else { return }
        Task {
            if !(await cameraAccess()) { session?.setCallCameraEnabled(false) }
        }
    }

    func setCameraEnabled(_ on: Bool) {
        session?.setCallCameraEnabled(on)
    }

    func switchCamera() {
        session?.switchCallCamera()
    }

    func setMuted(_ muted: Bool) {
        guard Self.usesCallKit else { return session?.setCallMuted(muted) ?? () }
        guard let uuid = currentUUID else { return }
        request(CXSetMutedCallAction(call: uuid, muted: muted))
    }

    func endCall() {
        guard Self.usesCallKit, let uuid = currentUUID else {
            session?.hangUpCall()
            return
        }
        request(CXEndCallAction(call: uuid))
    }

    /// Answers the incoming call, from the call bar's button.
    func answer() {
        guard Self.usesCallKit else {
            guard let session, session.callState.value?.phase == .incoming else { return }
            // The ring must be off before the call's audio session starts.
            ringer.stop()
            do {
                try activateAudio(video: session.callState.value?.isVideo == true)
            } catch {
                self.error = error.localizedDescription
            }
            session.answerCall()
            limitCameraToAccess()
            return
        }
        guard let uuid = currentUUID else { return }
        request(CXAnswerCallAction(call: uuid))
    }

    func setSpeaker(_ on: Bool) {
        do { try CallAudioSession.setSpeaker(on) } catch { self.error = error.localizedDescription }
    }

    /// Without CallKit nobody activates the audio session, and WebRTC plays and
    /// records only once told it is active.
    private func activateAudio(video: Bool) throws {
        #if targetEnvironment(macCatalyst)
        // The Mac's call audio (`MacCallAudioDevice`) opens the chosen devices
        // itself, once the call needs them, and WebRTC doesn't touch
        // AVAudioSession there: there is no session to activate.
        #else
        #if DEBUG
        // A Mac without a microphone the Simulator can open aborts the app in
        // AURemoteIO's start. WebRTC leaves the audio unit alone until audio
        // is enabled, so the call still connects, silently.
        if Self.devEnvironment["YAPNEST_DEV_NO_AUDIO"] == "1" { return }
        #endif
        try CallAudioSession.configure(video: video)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setActive(true)
        CallAudioSession.audioSessionDidActivate(audioSession)
        audioActive = true
        #endif
    }

    private func deactivateAudio() {
        guard audioActive else { return }
        audioActive = false
        let audioSession = AVAudioSession.sharedInstance()
        CallAudioSession.audioSessionDidDeactivate(audioSession)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var currentUUID: UUID? {
        session?.callState.value.flatMap { calls[$0.sid] }
    }

    private func request(_ action: CXAction) {
        Task {
            do {
                try await callController.request(CXTransaction(action: action))
            } catch {
                self.error = error.localizedDescription
                // The end of a call CallKit has lost must still end it here.
                if action is CXEndCallAction { session?.hangUpCall() }
            }
        }
    }

    // MARK: From CallKit

    fileprivate func perform(start action: CXStartCallAction) {
        guard let session, let peer = JID(action.handle.value) else { return action.fail() }
        do {
            try CallAudioSession.configure(video: action.isVideo)
            try session.startCall(to: peer, video: action.isVideo)
        } catch {
            self.error = error.localizedDescription
            return action.fail()
        }
        guard let state = session.callState.value, state.peer == peer else { return action.fail() }
        calls[state.sid] = action.callUUID
        action.fulfill()
        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.localizedCallerName = peer.shortName
        update.hasVideo = state.isVideo
        provider.reportCall(with: action.callUUID, updated: update)
        Task {
            let name = await Self.displayName(of: peer, in: session)
            update.localizedCallerName = name
            provider.reportCall(with: action.callUUID, updated: update)
        }
    }

    fileprivate func perform(answer action: CXAnswerCallAction) {
        guard let session, let state = session.callState.value, calls[state.sid] == action.callUUID, state.phase == .incoming else {
            return action.fail()
        }
        do {
            try CallAudioSession.configure(video: state.isVideo)
        } catch {
            self.error = error.localizedDescription
        }
        session.answerCall()
        limitCameraToAccess()
        action.fulfill()
    }

    fileprivate func perform(end action: CXEndCallAction) {
        if let session, let state = session.callState.value, calls[state.sid] == action.callUUID, !state.isOver {
            locallyEnded.insert(action.callUUID)
            // Declines the call if it is still ringing here.
            session.hangUpCall()
        }
        action.fulfill()
    }

    fileprivate func perform(mute action: CXSetMutedCallAction) {
        session?.setCallMuted(action.isMuted)
        action.fulfill()
    }

    fileprivate func audioSession(didChange active: Bool) {
        callKitAudioActive = active
        updateRingback()
    }

    fileprivate func reset() {
        session?.hangUpCall()
        calls = [:]
        locallyEnded = []
        reporting = []
    }

    #if DEBUG
    // MARK: Scripted calls

    // For driving calls between simulators and other clients from scripts,
    // through CallKit's own actions (where it is used) so its paths run as
    // they do for a user.

    private static let devEnvironment = ProcessInfo.processInfo.environment

    /// `YAPNEST_DEV_CALL=<jid>`: rings the contact once its device is known to
    /// take calls, which only the presence that follows sign-in tells.
    private func devCallIfRequested() {
        guard let address = Self.devEnvironment["YAPNEST_DEV_CALL"], let peer = JID(address), let session else { return }
        devTasks.append(Task { [weak self] in
            let video = Self.devEnvironment["YAPNEST_DEV_CALL_VIDEO"] == "1"
            let callable = video ? session.videoCallablePeers : session.callablePeers
            let waiting = Task {
                for await peers in callable.values where peers.contains(peer) { return true }
                return false
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(60))
                waiting.cancel()
            }
            let found = await withTaskCancellationHandler { await waiting.value } onCancel: { waiting.cancel() }
            timeout.cancel()
            guard !Task.isCancelled else { return }
            if found { self?.startCall(to: peer, video: video) } else { DiagLog.error(.calls, "Dev call: the peer never advertised calls") }
        })
    }

    /// `YAPNEST_DEV_ANSWER=1`: answers an incoming call after a moment, so the
    /// caller sees it ring.
    private func devAnswerIfRequested(sid: String) {
        guard Self.devEnvironment["YAPNEST_DEV_ANSWER"] == "1" else { return }
        devTasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.session?.callState.value?.sid == sid else { return }
            self.answer()
        })
    }

    /// `YAPNEST_DEV_HANGUP_AFTER=<seconds>`: ends a call that became active.
    private func devHangUpIfRequested(sid: String) {
        guard let text = Self.devEnvironment["YAPNEST_DEV_HANGUP_AFTER"], let seconds = Double(text) else { return }
        devTasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.session?.callState.value?.sid == sid else { return }
            self.endCall()
        })
    }
    #endif

    /// CallKit's provider delegate. The provider calls it on the main queue.
    private final class ProviderDelegate: NSObject, CXProviderDelegate, @unchecked Sendable {
        weak var controller: CallController?

        init(controller: CallController) { self.controller = controller }

        func providerDidReset(_ provider: CXProvider) {
            MainActor.assumeIsolated { controller?.reset() }
        }

        /// CallKit calls on the main queue it was given.
        private func onMain<Action: CXAction>(_ action: Action, _ work: @MainActor (CallController, Action) -> Void) {
            nonisolated(unsafe) let action = action
            MainActor.assumeIsolated { if let controller { work(controller, action) } }
        }

        func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
            onMain(action) { $0.perform(start: $1) }
        }

        func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
            onMain(action) { $0.perform(answer: $1) }
        }

        func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
            onMain(action) { $0.perform(end: $1) }
        }

        func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
            onMain(action) { $0.perform(mute: $1) }
        }

        func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
            CallAudioSession.audioSessionDidActivate(audioSession)
            MainActor.assumeIsolated { controller?.audioSession(didChange: true) }
        }

        func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
            MainActor.assumeIsolated { controller?.audioSession(didChange: false) }
            CallAudioSession.audioSessionDidDeactivate(audioSession)
        }
    }
}
