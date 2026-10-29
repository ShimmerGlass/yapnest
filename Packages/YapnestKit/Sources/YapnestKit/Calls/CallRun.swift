import Foundation
@preconcurrency import Martin

/// What a call holds besides its state: the media, the timer and the order of
/// the work that touches the media. The state itself is the machine's.
final class CallRun: @unchecked Sendable {
    let sid: String
    private let lock = NSLock()
    private var media: (any CallMedia)?
    private var prepared: Task<Void, Error>?
    private var tail: Task<Void, Never>?
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Task<Void, Never>?
    private var connectionTimer: Task<Void, Never>?
    private var closed = false
    private var muted = false
    private var cameraOn = true
    private var gateOpen = false
    private var pending: [CallCandidate] = []
    private var remoteNegotiation: CallJingle.Negotiation?
    private var contents: [Jingle.Content] = []
    private var verifiedState: (device: Int32, verification: CallVerification)?
    private var encryptedDevice: Int32?
    private var offeredState: (device: Int32, verification: CallVerification)?

    /// The candidates seen, for the log of how a call connected.
    let candidates = CallCandidateTally()

    init(sid: String) {
        self.sid = sid
    }

    var isMuted: Bool { lock.withLock { muted } }
    var isCameraOn: Bool { lock.withLock { cameraOn } }

    /// The peer's offer or answer, from the Jingle message that brought it.
    var remote: CallJingle.Negotiation? {
        get { lock.withLock { remoteNegotiation } }
        set { lock.withLock { remoteNegotiation = newValue } }
    }

    /// The peer's device that vouched for the call's fingerprint, and how far,
    /// once a `session-initiate` or `session-accept` of theirs came with it
    /// encrypted.
    var verified: (device: Int32, verification: CallVerification)? {
        get { lock.withLock { verifiedState } }
        set { lock.withLock { verifiedState = newValue } }
    }

    /// What the fingerprints of the stanza being handled showed, held until the
    /// machine takes the stanza, which is when it becomes `verified`.
    func offerVerification(_ offered: (device: Int32, verification: CallVerification)?) {
        lock.withLock { offeredState = offered }
    }

    func takeOfferedVerification() -> (device: Int32, verification: CallVerification)? {
        lock.withLock {
            defer { offeredState = nil }
            return offeredState
        }
    }

    var verification: CallVerification { lock.withLock { verifiedState?.verification ?? .unverified } }

    /// The device our own encrypted fingerprints went to. The answer has to
    /// come back encrypted from that device: a plain one is a server that
    /// stripped it.
    var encryptedTo: Int32? {
        get { lock.withLock { encryptedDevice } }
        set { lock.withLock { encryptedDevice = newValue } }
    }

    /// The contents' names in the order of the media's sections, and the ICE
    /// credentials each transport has, which candidates go out with.
    func learnContents(_ contents: [Jingle.Content]) {
        lock.withLock { self.contents = contents }
    }

    var mids: [String] { lock.withLock { contents.map(\.name) } }

    /// The first transport's, as that is the one a content's candidates belong to.
    func credentials(for name: String) -> (ufrag: String?, pwd: String?)? {
        let content = lock.withLock { contents.first { $0.name == name } }
        let transport = content?.transports.lazy.compactMap { $0 as? Jingle.Transport.ICEUDPTransport }.first
        return transport.map { ($0.ufrag, $0.pwd) }
    }

    func setMuted(_ value: Bool) {
        let media = lock.withLock {
            muted = value
            return self.media
        }
        media?.setMuted(value)
    }

    func setCameraEnabled(_ value: Bool) {
        let media = lock.withLock {
            cameraOn = value
            return self.media
        }
        media?.setCameraEnabled(value)
    }

    func switchCamera() {
        lock.withLock { media }?.switchCamera()
    }

    /// Starts getting the media ready, once.
    func prepare(_ work: @escaping @Sendable () async throws -> any CallMedia, failed: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard prepared == nil, !closed else { return }
            prepared = Task { [self] in
                do {
                    let created = try await work()
                    let (isClosed, muted, cameraOn) = lock.withLock {
                        if !closed { media = created }
                        return (closed, self.muted, self.cameraOn)
                    }
                    if isClosed { created.close() } else {
                        if muted { created.setMuted(true) }
                        if !cameraOn { created.setCameraEnabled(false) }
                    }
                } catch {
                    failed()
                    throw error
                }
            }
        }
        resumeWaiters()
    }

    /// The media, once it is ready. With `waitingForPreparation`, also when
    /// preparing hasn't been asked for yet: the screen follows the call's
    /// state, which can come before the work the state queued.
    func readyMedia(waitingForPreparation: Bool = false) async throws -> any CallMedia {
        if waitingForPreparation { await waitForPreparation() }
        guard let prepared = lock.withLock({ self.prepared }) else { throw CallRunError.notPrepared }
        try await prepared.value
        guard let media = lock.withLock({ self.media }) else { throw CallRunError.closed }
        return media
    }

    private func waitForPreparation() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                let ready = prepared != nil || closed
                if !ready { preparationWaiters.append(continuation) }
                return ready
            }
            if ready { continuation.resume() }
        }
    }

    private func resumeWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { preparationWaiters = [] }
            return preparationWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Runs `operation` after those queued before it. Order matters: the
    /// remote description has to be set before the candidates that follow it.
    func enqueue(_ operation: @escaping @Sendable () async throws -> Void, failed: @escaping @Sendable () -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                guard !lock.withLock({ closed }) else { return }
                do { try await operation() } catch { failed() }
            }
        }
    }

    func setTimer(_ task: Task<Void, Never>?) { replace(\.timer, with: task) }

    func setConnectionTimer(_ task: Task<Void, Never>?) { replace(\.connectionTimer, with: task) }

    private func replace(_ timer: ReferenceWritableKeyPath<CallRun, Task<Void, Never>?>, with task: Task<Void, Never>?) {
        let old = lock.withLock {
            defer { self[keyPath: timer] = task }
            return self[keyPath: timer]
        }
        old?.cancel()
    }

    /// A local candidate waits until the session that carries it is sent.
    func localCandidate(_ candidate: CallCandidate, send: (CallCandidate) -> Void) {
        let open = lock.withLock {
            if !gateOpen { pending.append(candidate) }
            return gateOpen
        }
        if open { send(candidate) }
    }

    func openGate(send: (CallCandidate) -> Void) {
        let waiting = lock.withLock {
            gateOpen = true
            defer { pending = [] }
            return pending
        }
        for candidate in waiting { send(candidate) }
    }

    func close() {
        let (media, timer, connectionTimer, tail, prepared) = lock.withLock {
            closed = true
            return (self.media, self.timer, self.connectionTimer, self.tail, self.prepared)
        }
        timer?.cancel()
        connectionTimer?.cancel()
        tail?.cancel()
        prepared?.cancel()
        media?.close()
        resumeWaiters()
    }
}

enum CallRunError: Error {
    case notPrepared
    case closed
    /// The media's description couldn't be turned into Jingle, or back.
    case badDescription
    /// The user asked for relayed calls and the server offers no relay.
    case noRelay
}

/// How many candidates of each kind each side has brought, for working out
/// from the log whether a call connected on a direct path.
final class CallCandidateTally: @unchecked Sendable {
    private let lock = NSLock()
    private var local: [CallCandidateKind: Int] = [:]
    private var remote: [CallCandidateKind: Int] = [:]

    /// Counts a candidate and says whether it is its side's first.
    func add(_ kind: CallCandidateKind, isLocal: Bool) -> Bool {
        lock.withLock {
            let wasEmpty = (isLocal ? local : remote).isEmpty
            if isLocal { local[kind, default: 0] += 1 } else { remote[kind, default: 0] += 1 }
            return wasEmpty
        }
    }

    func counts(isLocal: Bool) -> [CallCandidateKind: Int] {
        lock.withLock { isLocal ? local : remote }
    }
}
