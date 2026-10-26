import Foundation

/// Where a call is. A call is never in two places: each of our devices has its
/// own copy of this, and what the others do reaches it as signals.
public enum CallPhase: Sendable, Equatable {
    /// Outgoing: the propose is sent.
    case proposing
    /// Outgoing: one of the peer's devices rings.
    case ringing
    /// Incoming: ringing here.
    case incoming
    /// Someone answered (we sent `proceed`, or received it) and the Jingle
    /// session isn't up yet.
    case accepted
    /// The Jingle session is up and ICE is working on a path.
    case connecting
    case active
    case ended(CallEndReason)

    var isEnded: Bool {
        if case .ended = self { true } else { false }
    }

    /// Our call has gone out and nobody has answered yet.
    public var isAwaitingAnswer: Bool { self == .proposing || self == .ringing }
}

public enum CallEndReason: String, Sendable, Equatable, CaseIterable, DiagEnum {
    /// Hung up after talking, by either side.
    case completed
    /// We declined, or the peer did.
    case declined
    /// Our outgoing call, hung up before it was answered.
    case cancelled
    /// Our outgoing call rang out.
    case noAnswer
    /// An incoming call nobody here answered: the caller gave up, or it rang
    /// out, or it was too old to ring.
    case missed
    case busy
    /// An incoming call this device couldn't show (the system refused to ring),
    /// ended here without telling anyone, so the caller's other devices go on.
    case dismissed
    /// Our outgoing call gave way to the peer's, or theirs to ours, at the
    /// same moment (XEP-0353 §4.1). The call carries on under the other one.
    case tieBreak
    case answeredElsewhere
    case declinedElsewhere
    /// The media or the session failed.
    case failed
    /// The connection to the server dropped and didn't come back in time,
    /// before the call could be set up or answered.
    case connectionLost

    var outcome: CallOutcome {
        switch self {
        case .completed, .answeredElsewhere: .answered
        case .declined, .declinedElsewhere: .declined
        case .cancelled, .noAnswer: .cancelled
        case .missed, .dismissed: .missed
        // Never recorded: the winning call is the one that gets a row.
        case .tieBreak: .cancelled
        case .busy: .busy
        case .failed, .connectionLost: .failed
        }
    }
}

/// One call's state as a pure value with a transition function, so the races
/// between devices and between the two parties are tested without a
/// connection. It decides; `XMPPSession` does what it asks for.
struct CallMachine: Sendable, Equatable {
    /// How long a call rings, for the caller and for the callee alike. A
    /// propose older than this is not rung for: its caller has given up.
    static let ringWindow: TimeInterval = 60
    /// How long a session may take to be set up after someone answered.
    static let setupWindow: TimeInterval = 30
    /// How long ICE may take to find a path once the session is up.
    static let connectWindow: TimeInterval = 45
    /// How long a call that is still being set up or answered waits for the
    /// connection to the server to come back (a resumed stream does within
    /// seconds) before it ends. Its messages can't be sent meanwhile.
    static let reconnectWindow: TimeInterval = 20

    enum Input: Sendable, Equatable {
        case signal(CallSignal)
        /// The peer's server confirmed that the propose arrived.
        case proposeDelivered
        case answer
        case decline
        /// Ends a call that rings here without a word to anyone.
        case dismiss
        /// Our outgoing call lost the tie-break against the peer's propose.
        case yieldToTieBreak
        case hangUp
        case timer(Int)
        /// A Jingle `session-initiate` came in.
        case sessionInitiate(from: String)
        /// A Jingle `session-accept` came in.
        case sessionAccept(from: String)
        case sessionTerminate(from: String, reason: CallReason?)
        /// `.failed` is also what the media sends when it couldn't be set up or
        /// negotiated.
        case media(CallMediaState)
        /// The connection to the server dropped. A call that is up doesn't
        /// depend on it, as its media goes between the devices; one that is
        /// still being set up or answered does.
        case connectionLost
        /// The stream is back, resumed or new.
        case connectionRestored
        case connectionTimer(Int)
        /// Whether the server offers the relay that Always Relay Calls needs,
        /// which was asked for before anything was signalled. Only sent when
        /// the setting is on.
        case relayChecked(Bool)
    }

    enum Effect: Sendable, Equatable {
        case send(CallMessage)
        /// Finds out whether there is a relay, before the call is proposed or
        /// answered, and answers with `relayChecked`.
        case checkRelay
        /// The caller makes the offer and sends `session-initiate`.
        case startSession(to: String)
        /// The callee answers the offer that `session-initiate` carried.
        case answerSession
        /// The caller sets the answer that `session-accept` carried.
        case applyAnswer
        case terminateSession(to: String, reason: CallReason)
        /// Replaces any timer that is running.
        case armTimer(after: TimeInterval, token: Int)
        case cancelTimer
        /// Arms the wait for the connection, which runs beside the call's own
        /// timer rather than replacing it.
        case armConnectionTimer(after: TimeInterval, token: Int)
        /// Starts getting the media ready, with a camera if the call has video.
        case prepareMedia
        case closeMedia
        /// The call is over. Emitted once.
        case ended(CallEndReason)
    }

    let sid: String
    let direction: Message.Direction
    let peer: JID
    let account: JID
    /// Our full address, to tell our own messages from our other devices'.
    let me: String
    private(set) var phase: CallPhase
    /// The peer's device that answered, or the caller's that proposed: the one
    /// the Jingle session is with.
    private(set) var peerDevice: String?
    let proposedAt: Date
    let wantsVideo: Bool
    private(set) var answeredAt: Date?
    private(set) var activeSince: Date?
    private var timerToken = 0
    private var connectionToken = 0
    private var isConnectionLost = false
    /// Our outgoing call waits to learn there is a relay before its propose
    /// goes out, so until then there is nothing to retract.
    private var isProposeHeld = false
    /// Another of our devices answered while we had too: the caller picks one.
    private var otherDeviceAnswered = false

    /// Whether Jingle messages of this call can come from `device`.
    func isSessionPeer(_ device: String) -> Bool {
        switch phase {
        case .accepted, .connecting, .active: peerDevice == device
        default: false
        }
    }

    // MARK: Starting

    ///
    /// With `needsRelay` nothing is sent until `relayChecked(true)`, so that a
    /// call that can't be relayed never rings the peer.
    static func outgoing(sid: String, peer: JID, account: JID, me: String, video: Bool = false, needsRelay: Bool = false, now: Date) -> (CallMachine, [Effect]) {
        var machine = CallMachine(sid: sid, direction: .outgoing, peer: peer, account: account, me: me, phase: .proposing, proposedAt: now, wantsVideo: video)
        if needsRelay {
            machine.isProposeHeld = true
            return (machine, [.checkRelay])
        }
        let effects = machine.propose()
        return (machine, effects)
    }

    private mutating func propose() -> [Effect] {
        [.send(.propose(to: peer.description, video: wantsVideo)), arm(Self.ringWindow), .prepareMedia]
    }

    /// Takes back our propose, if it went out.
    private func retract(_ reason: CallReason, tieBreak: Bool = false) -> [Effect] {
        isProposeHeld ? [] : [.send(.retract(to: peer.description, reason: reason, tieBreak: tieBreak))]
    }

    /// A call that came in as `propose`. One that has waited past the ring
    /// window is already over: its caller has hung up by now, so it is missed.
    static func incoming(_ propose: CallSignal, account: JID, me: String, now: Date) -> (CallMachine, [Effect])? {
        guard case .propose(let media) = propose.action, media.contains(.audio) else { return nil }
        var machine = CallMachine(
            sid: propose.sid, direction: .incoming, peer: propose.sender, account: account, me: me, phase: .incoming,
            proposedAt: propose.timestamp, wantsVideo: media.contains(.video),
        )
        machine.peerDevice = propose.from
        let remaining = ringWindow - now.timeIntervalSince(propose.timestamp)
        guard remaining > 0 else {
            machine.phase = .ended(.missed)
            return (machine, [.ended(.missed)])
        }
        var effects: [Effect] = []
        if let device = propose.from { effects.append(.send(.ringing(to: device))) }
        effects.append(machine.arm(remaining))
        return (machine, effects)
    }

    /// Whether our own propose beats `theirs`, sent while ours had no answer
    /// (XEP-0353 §4.1): the lower session id wins, compared byte by byte
    /// (i;octet), and if they are the same, the lower address does.
    static func winsTieBreak(ourSid: String, ourAddress: String, theirSid: String, theirAddress: String) -> Bool {
        if ourSid != theirSid { return Array(ourSid.utf8).lexicographicallyPrecedes(Array(theirSid.utf8)) }
        return !Array(theirAddress.utf8).lexicographicallyPrecedes(Array(ourAddress.utf8))
    }

    private init(sid: String, direction: Message.Direction, peer: JID, account: JID, me: String, phase: CallPhase, proposedAt: Date, wantsVideo: Bool) {
        self.sid = sid
        self.direction = direction
        self.peer = peer
        self.account = account
        self.me = me
        self.phase = phase
        self.proposedAt = proposedAt
        self.wantsVideo = wantsVideo
    }

    // MARK: Transitions

    mutating func handle(_ input: Input, now: Date = Date()) -> [Effect] {
        guard !phase.isEnded else { return [] }
        switch input {
        case .signal(let signal): return handle(signal, now: now)
        case .proposeDelivered:
            if phase == .proposing { phase = .ringing }
            return []
        case .answer: return answer(now: now)
        case .relayChecked(let found): return relayChecked(found)
        case .decline: return direction == .incoming && phase == .incoming ? decline() : []
        case .dismiss: return direction == .incoming && phase == .incoming ? end(.dismissed) : []
        case .yieldToTieBreak:
            guard direction == .outgoing, phase.isAwaitingAnswer else { return [] }
            return retract(.expired, tieBreak: true) + end(.tieBreak)
        case .hangUp: return hangUp()
        case .timer(let token): return token == timerToken ? timedOut() : []
        case .sessionInitiate(let device):
            guard direction == .incoming, phase == .accepted, peerDevice == device else { return [] }
            phase = .connecting
            return [.answerSession, arm(Self.connectWindow)]
        case .sessionAccept(let device):
            guard direction == .outgoing, phase == .accepted, peerDevice == device else { return [] }
            phase = .connecting
            return [.applyAnswer, arm(Self.connectWindow)]
        case .sessionTerminate(let device, let reason):
            return isSessionPeer(device) ? remoteEnded(reason) : []
        case .connectionLost:
            guard !isConnectionLost else { return [] }
            isConnectionLost = true
            connectionToken += 1
            return [.armConnectionTimer(after: Self.reconnectWindow, token: connectionToken)]
        case .connectionRestored:
            guard isConnectionLost else { return [] }
            isConnectionLost = false
            connectionToken += 1
            return []
        case .connectionTimer(let token):
            return token == connectionToken && isConnectionLost ? lostConnection() : []
        case .media(let state):
            switch (state, phase) {
            case (.connected, .connecting):
                phase = .active
                activeSince = now
                timerToken += 1
                return [.cancelTimer]
            case (.failed, _): return mediaFailed()
            default: return []
            }
        }
    }

    private mutating func handle(_ signal: CallSignal, now: Date) -> [Effect] {
        guard signal.sid == sid, signal.from != me else { return [] }
        let fromPeer = !signal.isFromAccount && signal.sender == peer
        let fromOtherDevice = signal.isFromAccount
        switch (direction, signal.action) {
        case (.outgoing, .ringing) where fromPeer:
            if phase == .proposing { phase = .ringing }
            return []
        case (.outgoing, .proceed) where fromPeer:
            // The first device to answer gets the call. Another that answers
            // at the same moment is left to find out from the first one's
            // `accept`, which reaches all the callee's devices.
            guard phase.isAwaitingAnswer, let device = signal.from, device.contains("/") else { return [] }
            phase = .accepted
            peerDevice = device
            answeredAt = now
            return [arm(Self.setupWindow), .startSession(to: device)]
        case (.outgoing, .reject(let reason)) where fromPeer:
            guard phase.isAwaitingAnswer else { return [] }
            if signal.isTieBreak { return end(.tieBreak) }
            return end(reason == .busy ? .busy : .declined)
        case (.incoming, .retract) where fromPeer:
            // Including when it crossed our proceed: the caller never saw that.
            guard phase == .incoming || phase == .accepted else { return [] }
            return end(signal.isTieBreak ? .tieBreak : .missed)
        case (.incoming, .proceed) where fromOtherDevice, (.incoming, .accept) where fromOtherDevice:
            switch phase {
            case .incoming: return end(.answeredElsewhere)
            case .accepted: otherDeviceAnswered = true
            default: break
            }
            return []
        case (.incoming, .reject) where fromOtherDevice:
            guard phase == .incoming else { return [] }
            return end(signal.isTieBreak ? .tieBreak : .declinedElsewhere)
        case (_, .finish(let reason)) where fromPeer:
            guard let device = signal.from, isSessionPeer(device) else { return [] }
            return remoteEnded(reason)
        default:
            return []
        }
    }

    private mutating func answer(now: Date) -> [Effect] {
        guard direction == .incoming, phase == .incoming, let device = peerDevice else { return [] }
        phase = .accepted
        answeredAt = now
        return [.prepareMedia, .send(.proceed(to: device)), .send(.accept(to: account.description)), arm(Self.setupWindow)]
    }

    private mutating func relayChecked(_ found: Bool) -> [Effect] {
        switch (direction, phase) {
        case (.outgoing, .proposing) where isProposeHeld:
            isProposeHeld = false
            return found ? propose() : end(.failed)
        case (.incoming, .incoming) where !found:
            // Answering would tell the caller we're coming, and then fail.
            let reject = peerDevice.map { Effect.send(.reject(to: $0, reason: .decline)) }
            return (reject.map { [$0] } ?? []) + end(.failed)
        default:
            return []
        }
    }

    private mutating func decline() -> [Effect] {
        var effects: [Effect] = []
        if let device = peerDevice { effects.append(.send(.reject(to: device, reason: .decline))) }
        return effects + end(.declined)
    }

    private mutating func hangUp() -> [Effect] {
        switch phase {
        case .incoming:
            return decline()
        case .proposing, .ringing:
            return retract(.cancel) + end(.cancelled)
        case .accepted, .connecting:
            return leaveSession(.cancel) + end(direction == .outgoing ? .cancelled : .declined)
        case .active:
            return leaveSession(.success) + end(.completed)
        case .ended:
            return []
        }
    }

    private mutating func timedOut() -> [Effect] {
        switch phase {
        case .proposing, .ringing:
            return retract(.timeout) + end(.noAnswer)
        case .incoming:
            return end(.missed)
        case .accepted where otherDeviceAnswered:
            return end(.answeredElsewhere)
        case .accepted, .connecting:
            return fail()
        case .active, .ended:
            return []
        }
    }

    /// The connection stayed away. What can't go on without it ends here;
    /// the messages that would tell the others are sent when it is back.
    private mutating func lostConnection() -> [Effect] {
        switch phase {
        case .proposing, .ringing:
            return retract(.generalError) + end(.connectionLost)
        case .incoming:
            // Like a dismissed call, so that the caller's other devices go on.
            return end(.connectionLost)
        case .accepted, .connecting:
            return leaveSession(.connectivityError) + end(.connectionLost)
        case .active, .ended:
            return []
        }
    }

    private mutating func mediaFailed() -> [Effect] {
        switch phase {
        case .proposing, .ringing:
            return retract(.generalError) + end(.failed)
        case .accepted, .connecting, .active:
            return fail()
        case .incoming, .ended:
            return []
        }
    }

    /// The session or the media is gone: tell the peer both ways, as a peer
    /// may follow either the Jingle session or the message exchange.
    private mutating func fail() -> [Effect] {
        leaveSession(.connectivityError) + end(.failed)
    }

    private func leaveSession(_ reason: CallReason) -> [Effect] {
        guard let device = peerDevice else { return [] }
        return [.terminateSession(to: device, reason: reason), .send(.finish(to: device, reason: reason))]
    }

    /// The peer ended the session, with a `session-terminate` or a `finish`.
    private mutating func remoteEnded(_ reason: CallReason?) -> [Effect] {
        if phase == .active { return end(.completed) }
        switch (reason, direction) {
        case (.busy, _): return end(.busy)
        case (.decline, _): return end(.declined)
        case (.cancel, .outgoing): return end(.declined)
        case (.cancel, .incoming), (.gone, .incoming), (.timeout, .incoming), (.success, .incoming): return end(.missed)
        default: return end(.failed)
        }
    }

    private mutating func end(_ reason: CallEndReason) -> [Effect] {
        phase = .ended(reason)
        timerToken += 1
        return [.cancelTimer, .closeMedia, .ended(reason)]
    }

    /// Arms the timer, which supersedes the one running.
    private mutating func arm(_ seconds: TimeInterval) -> Effect {
        timerToken += 1
        return .armTimer(after: seconds, token: timerToken)
    }
}
