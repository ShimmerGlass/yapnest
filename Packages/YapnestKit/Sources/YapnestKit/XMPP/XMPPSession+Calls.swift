import Combine
import Foundation
@preconcurrency import Martin
import os

/// Audio and video calls (XEP-0353 ringing, XEP-0166 sessions). `CallMachine`
/// decides what a call does with each message and tap; this runs what it asks
/// for, with Martin's Jingle module for the session and `CallMedia` for the
/// audio and video.
///
/// One call at a time, and only in sessions that were given media: the
/// extensions' sessions don't register any of this, but still read the call
/// messages of the archive into the conversation's call rows.
extension XMPPSession {
    /// A message that ends a call, kept until the stream can carry it.
    struct UnsentCallMessage: Sendable {
        var message: CallMessage
        var sid: String
        var since: Date
    }

    struct ActiveCall {
        var machine: CallMachine
        let run: CallRun
    }

    /// What a contact's device must advertise for us to call it.
    static let callFeatures = [JingleModule.MESSAGE_INITIATION_XMLNS, "urn:xmpp:jingle:apps:rtp:audio"]

    /// What a device must advertise to take video as well.
    static let videoFeature = "urn:xmpp:jingle:apps:rtp:video"
    static let videoCallFeatures = callFeatures + [videoFeature]

    /// How long finding the server's relays may delay a call.
    static let relayDiscoveryTimeout: TimeInterval = 8

    // MARK: Modules

    /// The Jingle module serves calls when the session has media, and file
    /// transfers in the app's own session. The extensions' sessions register
    /// neither, so they never claim to take what they can't.
    func registerJingleModules() {
        let modules = client.modulesManager
        let bridge = CallJingleBridge()
        bridge.session = self
        let jingle = CallJingleModule(sessionManager: bridge)
        if callMedia != nil {
            // Messages are handled by the session itself, so this only stops
            // Martin refusing them.
            jingle.supportsMessageInitiation = true
            jingle.register(description: Jingle.RTP.Description.self, features: CallJingle.descriptionFeatures)
            jingle.register(transport: Jingle.Transport.ICEUDPTransport.self, features: CallJingle.transportFeatures)
            jingle.terminated = { [weak self] jid, sid, reason in
                guard let self, self.call(sid: sid, peer: jid) != nil else { return false }
                self.callStep(.sessionTerminate(from: jid.stringValue, reason: reason), sid: sid)
                return true
            }
        }
        if mode == .app { registerFileTransfer(on: jingle) }
        modules.register(jingle)
        if callMedia != nil { modules.register(ExternalServiceDiscoveryModule()) }
    }

    private var jingle: JingleModule? { client.modulesManager.moduleOrNil(JingleModule.IDENTIFIER) }

    /// Our own full address, which tells our messages from our other devices'.
    private var ownAddress: String { client.context.boundJid?.stringValue ?? account.description }

    // MARK: Calling

    /// Whether this session can make or take calls at all: it needs media.
    public var supportsCalls: Bool { callMedia != nil }

    /// Whether calls go only through the server's relay, hiding our address
    /// from the person we call.
    public var relaysCalls: Bool { database.flag(.relaysCalls, default: false) }

    /// Whether `peer` has a device that can take an audio call: one that
    /// advertises Jingle Message Initiation and RTP audio.
    /// With `video`, one that advertises RTP video too. The features have to
    /// be of one device: a peer's phone with audio but no video and a desktop
    /// with video but no audio don't add up to a device that can take a video
    /// call.
    public func canCall(_ peer: JID, video: Bool = false) -> Bool {
        guard callMedia != nil, let caps = client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER) else { return false }
        let features = video ? Self.videoCallFeatures : Self.callFeatures
        return Self.supportsAll(features.map { caps.isFeatureSupported($0, by: peer.martin) })
    }

    /// Works out who can be called now, after a presence or a caps result
    /// changed what is known. Only contacts who are online can be.
    func updateCallablePeers() {
        guard callMedia != nil else { return }
        callablePublishLock.lock()
        defer { callablePublishLock.unlock() }
        var callable: Set<JID> = [], videoCallable: Set<JID> = []
        let caps = client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER)
        for peer in presences.value.keys {
            guard let caps else { break }
            let audio = Self.callFeatures.map { caps.isFeatureSupported($0, by: peer.martin) }
            guard Self.supportsAll(audio) else { continue }
            callable.insert(peer)
            if Self.supportsAll(audio + [caps.isFeatureSupported(Self.videoFeature, by: peer.martin)]) { videoCallable.insert(peer) }
        }
        if callablePeers.value != callable { callablePeers.send(callable) }
        if videoCallablePeers.value != videoCallable { videoCallablePeers.send(videoCallable) }
    }

    /// `updateCallablePeers` for a caps result. Hundreds arrive at once after
    /// sign-in, and a thread for each, all waiting on the lock, would starve
    /// the cache's queue of the threads its stores need. Cleared before the
    /// run, so a result that lands during it gets a run of its own.
    func scheduleCallableUpdate() {
        let isFirst = callableUpdatePending.withLock { pending in
            defer { pending = true }
            return !pending
        }
        guard isFirst else { return }
        callableQueue.async { [weak self] in
            guard let self else { return }
            self.callableUpdatePending.withLock { $0 = false }
            self.updateCallablePeers()
        }
    }

    /// Whether some device supports every feature in `results`, one per feature.
    static func supportsAll(_ results: [CapabilitiesModule.FeatureSupported]) -> Bool {
        switch devicesSupportingAll(results) {
        case .none: false
        case .every: true
        case .some(let devices): !devices.isEmpty
        }
    }

    /// Which devices support every feature in `results`, one per feature.
    enum SupportingDevices {
        /// Some feature has no device that supports it.
        case none
        /// Every feature is supported by whichever device, so nothing narrows it.
        case every
        /// Only these devices support them all.
        case some(Set<Martin.JID>)
    }

    static func devicesSupportingAll(_ results: [CapabilitiesModule.FeatureSupported]) -> SupportingDevices {
        var devices: Set<Martin.JID>?
        for result in results {
            switch result {
            case .none: return .none
            case .all: continue
            case .some(let jids): devices = devices.map { $0.intersection(jids) } ?? Set(jids)
            }
        }
        return devices.map { .some($0) } ?? .every
    }

    /// Rings `peer`. Throws if another call is going on or the session can't call.
    public func startCall(to peer: JID, video: Bool = false) throws {
        guard callMedia != nil else { throw CallError.unavailable }
        guard isConnected else { throw CallError.notConnected }
        let sid = UUID().uuidString.lowercased()
        let me = ownAddress
        let started = publish(callState, under: callPublishLock) { state -> (result: Bool, snapshot: CallState??) in
            if let call = state.call, !call.machine.phase.isEnded { return (false, nil) }
            let (machine, effects) = CallMachine.outgoing(sid: sid, peer: peer, account: account, me: me, video: video, needsRelay: relaysCalls, now: Date())
            let run = CallRun(sid: sid)
            state.call = ActiveCall(machine: machine, run: run)
            perform(effects, run: run, machine: machine)
            logCall(machine)
            return (true, .some(CallState(machine, run: run)))
        }
        if !started { throw CallError.busy }
    }

    public func answerCall() {
        guard relaysCalls, let sid = lock.withLock({ $0.call?.machine.sid }) else {
            callStep(.answer)
            return
        }
        // Answering tells the caller we're coming, so a call that can't be
        // relayed is refused before that, not when its media fails to start.
        Task { [self] in
            let found = await hasRelay(sid: sid)
            callStep(found ? .answer : .relayChecked(false), sid: sid)
        }
    }

    public func declineCall() { callStep(.decline) }

    /// Ends a call that rings here without telling anyone, for when the
    /// system won't show it (Do Not Disturb). Declining would send a `reject`,
    /// which stops the user's other devices ringing and tells the caller it
    /// was turned down; this lets them go on, and the call settle as it would
    /// for a device nobody answered on.
    public func dismissIncomingCall() { callStep(.dismiss) }

    /// Ends the call, whatever it is doing: cancels one that is ringing out,
    /// declines one that rings here.
    public func hangUpCall() { callStep(.hangUp) }

    public func setCallMuted(_ muted: Bool) {
        updateCallRun { $0.setMuted(muted) }
    }

    /// Turns our camera on or off in a video call.
    public func setCallCameraEnabled(_ on: Bool) {
        updateCallRun(requiresVideo: true) { $0.setCameraEnabled(on) }
    }

    private func updateCallRun(requiresVideo: Bool = false, _ change: (CallRun) -> Void) {
        publish(callState, under: callPublishLock) { state -> (result: Void, snapshot: CallState??) in
            guard let call = state.call, !call.machine.phase.isEnded, !requiresVideo || call.machine.wantsVideo else { return ((), nil) }
            change(call.run)
            return ((), .some(CallState(call.machine, run: call.run)))
        }
    }

    public func switchCallCamera() {
        let run = lock.withLock { state in
            state.call.flatMap { $0.machine.phase.isEnded ? nil : $0.run }
        }
        run?.switchCamera()
    }

    /// The media of the call `sid` names, once it is ready, for the screen to
    /// draw the video from. Nil if that isn't the current call.
    public func callMedia(sid: String) async -> (any CallMedia)? {
        guard let run = call(sid: sid)?.run else { return nil }
        return try? await run.readyMedia(waitingForPreparation: true)
    }

    // MARK: Steps

    /// Gives the call's machine `input`, publishes its new state and queues
    /// what it asks for, in the order the steps happened. `sid` limits the
    /// step to that call. `remote` is what the Jingle message brought, kept
    /// for the work the machine may ask for.
    @discardableResult
    func callStep(_ input: CallMachine.Input, sid: String? = nil, remote: CallJingle.Negotiation? = nil) -> [CallMachine.Effect] {
        publish(callState, under: callPublishLock) { state -> (result: [CallMachine.Effect], snapshot: CallState??) in
            guard var call = state.call, sid == nil || call.machine.sid == sid else { return ([], nil) }
            let before = call.machine
            let effects = call.machine.handle(input)
            guard call.machine != before else { return (effects, nil) }
            // Only a message the machine took may set the negotiation: a
            // retransmission, or another of the peer's devices, would replace
            // the one the queued answer is about to read.
            if let remote { call.run.remote = remote }
            state.call = call
            perform(effects, run: call.run, machine: call.machine)
            logCall(call.machine)
            return (effects, .some(CallState(call.machine, run: call.run)))
        }
    }

    /// One line per change of a call's phase, for working out in the field
    /// where a call stopped and where the time went. The peer is private, as
    /// it is anywhere else.
    private func logCall(_ machine: CallMachine) {
        var fields = Self.callFields(machine) + [
            .bool("outgoing", machine.direction == .outgoing), .bool("video", machine.wantsVideo),
            .value("phase", CallPhaseKind(machine.phase)),
        ]
        if case .ended(let reason) = machine.phase { fields.append(.value("reason", reason)) }
        DiagLog.info(.calls, "Call phase", fields: fields)
    }

    /// What every line of a call carries: its id, and the time since it was
    /// proposed and, once answered, since it was.
    private static func callFields(_ machine: CallMachine) -> [DiagField] {
        var fields: [DiagField] = [.id("sid", Redacted.id(machine.sid)), .duration("sinceProposed", since: machine.proposedAt)]
        if let answeredAt = machine.answeredAt { fields.append(.duration("sinceAnswered", since: answeredAt)) }
        return fields
    }

    /// For a line written outside the machine's own step; the id alone if the
    /// call is gone.
    private func callFields(sid: String) -> [DiagField] {
        call(sid: sid).map { Self.callFields($0.machine) } ?? [.id("sid", Redacted.id(sid))]
    }

    /// The `typ` of a candidate (host, srflx, prflx or relay), which says
    /// whether a call could connect directly or only through the relay.
    static func candidateType(_ candidate: CallCandidate) -> CallCandidateKind {
        let parts = candidate.sdp.split(separator: " ")
        guard let index = parts.firstIndex(of: "typ"), parts.indices.contains(index + 1) else { return .unknown }
        return CallCandidateKind(sdpType: String(parts[index + 1]))
    }

    private func logCandidate(_ candidate: CallCandidate, run: CallRun, isLocal: Bool) {
        let kind = Self.candidateType(candidate)
        let first = run.candidates.add(kind, isLocal: isLocal)
        DiagLog.info(.calls, isLocal ? "Call local candidate" : "Call remote candidate",
                     fields: callFields(sid: run.sid) + [.value("type", kind), .bool("first", first)])
    }

    /// The candidates that came inside the peer's offer or answer, which
    /// reach the media with the description and not as transport-info.
    private func logRemoteCandidates(in remote: CallJingle.Negotiation, run: CallRun) {
        let mids = remote.contents.map(\.name)
        for candidate in CallJingle.candidates(in: remote.contents, mids: mids) {
            logCandidate(candidate, run: run, isLocal: false)
        }
    }

    private func logMedia(_ state: CallMediaState, run: CallRun, sid: String) {
        var fields = callFields(sid: sid) + [.value("state", state)]
        if state == .connected {
            let local = run.candidates.counts(isLocal: true)
            let remote = run.candidates.counts(isLocal: false)
            fields += [
                .int("localHost", local[.host] ?? 0), .int("localSrflx", local[.srflx] ?? 0),
                .int("localPrflx", local[.prflx] ?? 0), .int("localRelay", local[.relay] ?? 0),
                .int("remoteHost", remote[.host] ?? 0), .int("remoteSrflx", remote[.srflx] ?? 0),
                .int("remotePrflx", remote[.prflx] ?? 0), .int("remoteRelay", remote[.relay] ?? 0),
            ]
        }
        DiagLog.info(.calls, "Call media", fields: fields)
    }

    /// The call `sid` names, and with a `peer`, only if that is its session's
    /// peer.
    private func call(sid: String, peer: Martin.JID? = nil) -> ActiveCall? {
        lock.withLock { state in
            guard let call = state.call, call.machine.sid == sid,
                  peer.map({ call.machine.isSessionPeer($0.stringValue) }) ?? true else { return nil }
            return call
        }
    }

    private func warnNoRelay() {
        warnings.post(
            "call-relay", title: String(localized: "Call couldn't connect"),
            detail: String(localized: "Always Relay Calls is on, but your server offers no relay to call through. Turn it off in Settings to call directly, or ask your server's administrator to set up a TURN relay."),
        )
    }

    /// Whether the server offers a relay to call through, which the servers
    /// already found answer without asking again. Posts the warning when it
    /// doesn't, as the call is refused.
    private func hasRelay(sid: String) async -> Bool {
        let found = await discoverIceServers().contains(where: \.isRelay)
        if found {
            warnings.clear("call-relay")
        } else {
            DiagLog.notice(.calls, "Call refused: relaying is on and the server offers no relay", fields: callFields(sid: sid))
            warnNoRelay()
        }
        return found
    }

    private func failCall(_ sid: String) {
        callStep(.media(.failed), sid: sid)
    }

    // MARK: Jingle

    func callSessionInitiated(from jid: Martin.JID, sid: String, negotiation: CallJingle.Negotiation) -> Bool {
        callStep(.sessionInitiate(from: jid.stringValue), sid: sid, remote: negotiation).contains(.answerSession)
    }

    func callSessionAccepted(from jid: Martin.JID, sid: String, negotiation: CallJingle.Negotiation) -> Bool {
        callStep(.sessionAccept(from: jid.stringValue), sid: sid, remote: negotiation).contains(.applyAnswer)
    }

    func callTransportInfo(from jid: Martin.JID, sid: String, contents: [Jingle.Content]) -> Bool {
        guard let run = call(sid: sid, peer: jid)?.run else { return false }
        // After the work already queued, which sets the description they belong to.
        callQueue.async {
            run.enqueue({ [weak self] in
                let media = try await run.readyMedia()
                for candidate in CallJingle.candidates(in: contents, mids: run.mids) {
                    self?.logCandidate(candidate, run: run, isLocal: false)
                    try? await media.addRemoteCandidate(candidate)
                }
            }, failed: {})
        }
        return true
    }

    // MARK: Messages

    /// A Jingle Message Initiation message from any source. The call this
    /// device is in, and a new call ringing here, are the machine's; the rest
    /// only add to the conversation's call rows.
    func callSignalReceived(_ signal: CallSignal, source: InboundMessage.Source, isHistory: Bool, query: String = "") {
        if callMedia != nil, routeToCall(signal, source: source, isHistory: isHistory) { return }
        if case .archive = source {
            // With the page's messages, in the transaction that ends it.
            lock.withLockUnchecked { $0.archivedCallSignals.append(ArchivedCallSignal(query: query, signal: signal, isHistory: isHistory)) }
            return
        }
        do {
            if let row = try database.applyCallSignal(signal, account: account, isHistory: isHistory), !isHistory {
                events.send(.newMessage(row))
            }
        } catch {
            logger.error("Failed to record call \(signal.sid, privacy: .private): \(error)")
        }
    }

    /// Whether the machine took the signal.
    private func routeToCall(_ signal: CallSignal, source: InboundMessage.Source, isHistory: Bool) -> Bool {
        let isArchive = if case .archive = source { true } else { false }
        let isLivePropose = if case .propose = signal.action, source == .live, !isHistory, !signal.isFromAccount { true } else { false }
        if isLivePropose, settleTieBreak(against: signal) { return true }
        // A call dismissed here goes on elsewhere, and how it ends is what the
        // log needs to hear.
        let ours = call(sid: signal.sid).map { $0.machine.phase != .ended(.dismissed) } ?? false
        if ours {
            // The archive tells of the call we are in, or just were: the row
            // is written when it ends.
            if !isArchive, !isHistory { callStep(.signal(signal), sid: signal.sid) }
            return true
        }
        guard isLivePropose,
              (try? database.isInRoster(signal.sender)) == true else { return false }
        ring(for: signal)
        return true
    }

    /// XEP-0353 §4.1: the peer proposed while our own propose to them has no
    /// answer. One of the two calls has to give way, or both would end busy.
    /// Returns whether `signal` was dealt with. A call with anyone else, or one
    /// already answered, isn't a tie.
    private func settleTieBreak(against signal: CallSignal) -> Bool {
        guard let current = lock.withLock({ $0.call?.machine }), current.direction == .outgoing,
              current.peer == signal.sender, current.phase.isAwaitingAnswer else { return false }
        let wins = CallMachine.winsTieBreak(
            ourSid: current.sid, ourAddress: ownAddress, theirSid: signal.sid, theirAddress: signal.from ?? signal.sender.description,
        )
        if wins {
            // Theirs gives way, and is not a missed call of ours.
            writeCall(.reject(to: signal.from ?? signal.sender.description, reason: .expired, tieBreak: true), sid: signal.sid)
        } else {
            callStep(.yieldToTieBreak, sid: current.sid)
            ring(for: signal)
        }
        return true
    }

    private func ring(for signal: CallSignal) {
        let now = Date()
        guard case .propose(let media) = signal.action else { return }
        guard media.contains(.audio) else {
            // Video alone isn't a call we can take. The caller hears why, and
            // the user sees that someone tried.
            rejectAsMissed(signal, reason: .unsupportedApplications)
            return
        }
        guard let (machine, effects) = CallMachine.incoming(signal, account: account, me: ownAddress, now: now) else { return }
        let run = CallRun(sid: signal.sid)
        let isBusy = publish(callState, under: callPublishLock) { state -> (result: Bool, snapshot: CallState??) in
            if let call = state.call, !call.machine.phase.isEnded { return (true, nil) }
            // Too old to ring, and not worth showing: it is only a row.
            if machine.phase.isEnded {
                perform(effects, run: run, machine: machine)
                return (false, nil)
            }
            state.call = ActiveCall(machine: machine, run: run)
            perform(effects, run: run, machine: machine)
            logCall(machine)
            return (false, .some(CallState(machine, run: run)))
        }
        // So that answering finds the servers ready.
        if !isBusy, !machine.phase.isEnded { Task { [self] in _ = await discoverIceServers() } }
        guard isBusy else { return }
        rejectAsMissed(signal, reason: .busy)
    }

    private func rejectAsMissed(_ signal: CallSignal, reason: CallReason) {
        if let device = signal.from { writeCall(.reject(to: device, reason: reason), sid: signal.sid) }
        callQueue.async { [self] in
            record(CallRecord(peer: signal.sender, account: account, sid: signal.sid, direction: .incoming, outcome: .missed, startedAt: signal.timestamp, isVideo: signal.action.asksForVideo))
        }
    }

    /// A delivery receipt for our `propose` says the peer's server has it, and
    /// is the ring the caller waits for from clients that send no `ringing`.
    func callProposeDelivered(_ sid: String) {
        guard callMedia != nil else { return }
        callStep(.proposeDelivered, sid: sid)
    }

    // MARK: Effects

    /// Queues `effects` behind those of earlier steps. Called with the state
    /// lock held, so that the order they are queued in is the order of the
    /// machine's steps.
    private func perform(_ effects: [CallMachine.Effect], run: CallRun, machine: CallMachine) {
        guard !effects.isEmpty else { return }
        callQueue.async { [self] in
            for effect in effects { perform(effect, run: run, machine: machine) }
        }
    }

    private func perform(_ effect: CallMachine.Effect, run: CallRun, machine: CallMachine) {
        let sid = machine.sid
        switch effect {
        case .send(let message):
            writeCall(message, sid: sid)
        case .checkRelay:
            Task { [self] in callStep(.relayChecked(await hasRelay(sid: sid)), sid: sid) }
        case .prepareMedia:
            prepareMedia(run: run, sid: sid, video: machine.wantsVideo)
        case .startSession(let device):
            startSession(with: device, run: run, sid: sid)
        case .answerSession:
            answerSession(with: machine.peerDevice, run: run, sid: sid)
        case .applyAnswer:
            applyAnswer(run: run, sid: sid)
        case .terminateSession(let device, let reason):
            jingle?.terminateSession(with: Martin.JID(device), sid: sid, reason: reason.jingle) { result in
                if case .failure(let error) = result { self.logRefused(.sessionTerminate, sid: sid, error) }
            }
        case .armTimer(let seconds, let token):
            run.setTimer(Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.callStep(.timer(token), sid: sid)
            })
        case .armConnectionTimer(let seconds, let token):
            run.setConnectionTimer(Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.callStep(.connectionTimer(token), sid: sid)
            })
        case .cancelTimer:
            run.setTimer(nil)
        case .closeMedia:
            run.close()
        case .ended(let reason):
            // The call that won the tie-break is the one that gets a row.
            if reason != .tieBreak { record(machine, reason: reason) }
        }
    }

    /// Writes a call message. One that ends a call, and that the stream was
    /// down for or dropped, is kept for `unsentCallMessageLifetime` and sent
    /// when the stream is back: otherwise the peer goes on ringing, and our
    /// other devices with it, until their own timers. A proposal or an answer
    /// is of no use late, and is dropped.
    func writeCall(_ message: CallMessage, sid: String) {
        let stanza = OutboundStanza.call(message, sid: sid)
        guard message.endsACall else {
            write(stanza)
            return
        }
        guard isConnected else {
            keepForReconnect(message, sid: sid, since: Date())
            return
        }
        client.context.writer.write(stanza) { [weak self] result in
            if case .failure = result { self?.keepForReconnect(message, sid: sid, since: Date()) }
        }
    }

    /// How long a message that ends a call waits for the stream. Past it the
    /// peer has timed the call out itself.
    static let unsentCallMessageLifetime: TimeInterval = 120

    private func keepForReconnect(_ message: CallMessage, sid: String, since: Date) {
        DiagLog.notice(.calls, "Call message kept for the reconnect", fields: [.id("sid", Redacted.id(sid))])
        lock.withLock { $0.unsentCallMessages.append(.init(message: message, sid: sid, since: since)) }
    }

    /// Sends what ending a call left unsent while the stream was down. Called
    /// when it is back, resumed or new. What is too old is dropped.
    func sendUnsentCallMessages(now: Date = Date()) {
        let unsent = lock.withLock { state in
            defer { state.unsentCallMessages = [] }
            return state.unsentCallMessages
        }
        for item in unsent where now.timeIntervalSince(item.since) <= Self.unsentCallMessageLifetime {
            DiagLog.info(.calls, "Call message sent after the reconnect", fields: [.id("sid", Redacted.id(item.sid))])
            let stanza = OutboundStanza.call(item.message, sid: item.sid)
            guard isConnected else {
                keepForReconnect(item.message, sid: item.sid, since: item.since)
                continue
            }
            client.context.writer.write(stanza) { [weak self] result in
                if case .failure = result { self?.keepForReconnect(item.message, sid: item.sid, since: item.since) }
            }
        }
    }

    private func record(_ machine: CallMachine, reason: CallEndReason) {
        record(CallRecord(
            peer: machine.peer, account: account, sid: machine.sid, direction: machine.direction,
            outcome: reason.outcome, startedAt: machine.proposedAt, answeredAt: machine.answeredAt,
            duration: machine.activeSince.map { max(0, Date().timeIntervalSince($0)) },
            isVideo: machine.wantsVideo,
        ))
    }

    private func record(_ record: CallRecord) {
        do {
            if let row = try database.recordCall(record) { events.send(.newMessage(row)) }
        } catch {
            logger.error("Failed to record call \(record.sid, privacy: .private): \(error)")
        }
    }

    // MARK: Media

    private func prepareMedia(run: CallRun, sid: String, video: Bool) {
        run.prepare({ [weak self] in
            guard let self, let factory = self.callMedia else { throw CallRunError.closed }
            let servers = await self.discoverIceServers()
            // Never a direct connection when the user asked for relayed calls.
            let relayOnly = self.relaysCalls
            // The last guard: the call was only let through if it had a relay,
            // but the setting or the servers may have changed since.
            if relayOnly, !servers.contains(where: \.isRelay) {
                DiagLog.notice(.calls, "Call refused: relaying is on and the server offers no relay", fields: self.callFields(sid: sid))
                self.warnNoRelay()
                throw CallRunError.noRelay
            }
            self.warnings.clear("call-relay")
            let media = factory.makeMedia(relayOnly: relayOnly)
            let startedAt = Date()
            do {
                try await media.start(iceServers: servers, video: video)
            } catch {
                media.close()
                DiagLog.error(.calls, "Call media failed to start", fields: self.callFields(sid: sid) + [.duration("took", since: startedAt), .error(error)])
                throw error
            }
            DiagLog.info(.calls, "Call media started", fields: self.callFields(sid: sid) + [.bool("video", video), .duration("took", since: startedAt)])
            self.follow(media, run: run, sid: sid)
            return media
        }, failed: { [weak self] in self?.failCall(sid) })
    }

    private func follow(_ media: any CallMedia, run: CallRun, sid: String) {
        let events = media.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .candidate(let candidate):
                    self.logCandidate(candidate, run: run, isLocal: true)
                    run.localCandidate(candidate) { self.sendLocalCandidate($0, run: run, sid: sid) }
                case .state(let state):
                    self.logMedia(state, run: run, sid: sid)
                    self.callStep(.media(state), sid: sid)
                }
            }
        }
    }

    private func sendLocalCandidate(_ candidate: CallCandidate, run: CallRun, sid: String) {
        guard let device = call(sid: sid)?.machine.peerDevice, let jingle else { return }
        let mids = run.mids
        let name = candidate.sdpMid ?? (mids.indices.contains(Int(candidate.sdpMLineIndex)) ? mids[Int(candidate.sdpMLineIndex)] : nil) ?? "0"
        let credentials = run.credentials(for: name)
        guard let content = CallJingle.transportInfo(for: candidate, name: name, creator: .initiator, ufrag: credentials?.ufrag, pwd: credentials?.pwd) else { return }
        // A candidate the peer refused is one ICE never tries, which the log
        // should show when a call doesn't connect.
        jingle.transportInfo(with: Martin.JID(device), sid: sid, contents: [content]) { result in
            if case .failure(let error) = result { self.logRefused(.transportInfo, sid: sid, error) }
        }
    }

    private func logRefused(_ action: CallRefusedAction, sid: String, _ error: XMPPError) {
        DiagLog.error(.calls, "Call message refused", fields: callFields(sid: sid) + [.value("action", action), .error(error)])
    }

    private func startSession(with device: String, run: CallRun, sid: String) {
        run.enqueue({ [weak self] in
            guard let self, let jingle = self.jingle else { throw CallRunError.closed }
            let media = try await run.readyMedia()
            let offer = try await media.makeOffer()
            guard let negotiation = CallJingle.negotiation(fromSDP: offer, localRole: .initiator) else { throw CallRunError.badDescription }
            run.learnContents(negotiation.contents)
            try await jingle.initiateSession(to: Martin.JID(device), sid: sid, contents: negotiation.contents, bundle: negotiation.bundle)
            run.openGate { self.sendLocalCandidate($0, run: run, sid: sid) }
        }, failed: { [weak self] in self?.failCall(sid) })
    }

    private func answerSession(with device: String?, run: CallRun, sid: String) {
        guard let device else { return }
        run.enqueue({ [weak self] in
            guard let self, let jingle = self.jingle, let remote = run.remote,
                  let offer = CallJingle.sdp(from: remote, localRole: .responder) else { throw CallRunError.badDescription }
            self.logRemoteCandidates(in: remote, run: run)
            let media = try await run.readyMedia()
            let answer = try await media.answer(offer: offer)
            let creators = Dictionary(remote.contents.map { ($0.name, $0.creator) }, uniquingKeysWith: { first, _ in first })
            guard let negotiation = CallJingle.negotiation(fromSDP: answer, localRole: .responder, creators: creators) else {
                throw CallRunError.badDescription
            }
            run.learnContents(negotiation.contents)
            try await jingle.acceptSession(with: Martin.JID(device), sid: sid, contents: negotiation.contents, bundle: negotiation.bundle)
            run.openGate { self.sendLocalCandidate($0, run: run, sid: sid) }
        }, failed: { [weak self] in self?.failCall(sid) })
    }

    private func applyAnswer(run: CallRun, sid: String) {
        run.enqueue({ [weak self] in
            guard let remote = run.remote, let answer = CallJingle.sdp(from: remote, localRole: .initiator) else { throw CallRunError.badDescription }
            self?.logRemoteCandidates(in: remote, run: run)
            try await run.readyMedia().setAnswer(answer)
        }, failed: { [weak self] in self?.failCall(sid) })
    }

    // MARK: Relays

    /// The server's STUN and TURN servers, kept until their credentials
    /// expire, and asked for when a call rings so that answering needn't wait.
    /// Without them the call still tries a direct path, unless the user has
    /// asked for relayed calls, which then fail.
    func discoverIceServers() async -> [CallIceServer] {
        let start = Date()
        let servers = await iceServerCache.servers { [weak self] in await self?.fetchIceServers() }
        DiagLog.info(.calls, "Call relays ready", .duration("took", since: start),
                     .int("stun", servers.count { $0.urls.contains { $0.hasPrefix("stun") } }),
                     .int("turn", servers.count { $0.urls.contains { $0.hasPrefix("turn") } }))
        return servers
    }

    /// The services with the credentials of those that need asking for them
    /// (XEP-0215), all at once. A relay whose credentials can't be had is
    /// useless, so it is dropped; the others stay.
    private static func withCredentials(_ services: [ExternalServiceDiscoveryModule.Service], module: ExternalServiceDiscoveryModule) async -> [ExternalServiceDiscoveryModule.Service] {
        await withTaskGroup(of: (Int, ExternalServiceDiscoveryModule.Service?).self) { group in
            for (index, service) in services.enumerated() {
                group.addTask {
                    guard service.restricted, service.username == nil || service.password == nil else { return (index, service) }
                    do {
                        return (index, try await module.credentials(for: service))
                    } catch {
                        // STUN needs no credentials to be of use.
                        return (index, service.type.lowercased() == "stun" ? service : nil)
                    }
                }
            }
            var found: [(Int, ExternalServiceDiscoveryModule.Service)] = []
            for await (index, service) in group {
                if let service { found.append((index, service)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func fetchIceServers() async -> IceServerCache.Discovered? {
        guard let module = client.modulesManager.moduleOrNil(ExternalServiceDiscoveryModule.IDENTIFIER), module.isAvailable else {
            DiagLog.info(.calls, "Call relay discovery", .value("outcome", RelayDiscoveryOutcome.unavailable))
            return nil
        }
        let start = Date()
        do {
            let services = try await withTimeout(Self.relayDiscoveryTimeout) {
                await Self.withCredentials(try await module.discover(from: nil, type: nil), module: module)
            }
            let now = Date()
            let servers = CallIceServer.servers(from: services.map(ExternalService.init), now: now)
            DiagLog.info(.calls, "Call relay discovery", .value("outcome", servers.isEmpty ? RelayDiscoveryOutcome.none : .found), .duration("took", since: start), .int("services", services.count), .int("servers", servers.count))
            return IceServerCache.Discovered(
                servers: servers,
                expires: services.compactMap(\.expires).filter { $0 > now }.min(),
            )
        } catch {
            let timedOut = error is TimeoutError
            var fields: [DiagField] = [.value("outcome", timedOut ? RelayDiscoveryOutcome.timedOut : .failed), .duration("took", since: start)]
            if !timedOut { fields.append(.error(error)) }
            DiagLog.notice(.calls, "Call relay discovery", fields: fields)
            return nil
        }
    }
}

/// Martin's capabilities cache, which says when a node's features arrive:
/// Martin otherwise only lets a lookup find out, and who can be called
/// depends on them.
final class ReportingCapabilitiesCache: DefaultCapabilitiesCache, @unchecked Sendable {
    /// Set before the cache is used.
    var stored: (@Sendable () -> Void)?

    override func store(node: String, identity: DiscoveryModule.Identity?, features: [String]) {
        super.store(node: node, identity: identity, features: features)
        // The superclass stores on a barrier of its queue, so this lookup, queued
        // after it, sees the node. The callback must not read the cache on
        // this queue: that syncs on it, behind any store queued meanwhile.
        isCached(node: node) { [stored] _ in stored?() }
    }
}
