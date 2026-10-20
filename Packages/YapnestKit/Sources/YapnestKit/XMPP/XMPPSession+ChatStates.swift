import Foundation
@preconcurrency import Martin

/// What we know of one contact's chat states (XEP-0085), and what we last
/// told them.
struct ChatStateTracker: Sendable {
    /// Whether they send chat states themselves: nil until they write to us.
    var supported: Bool?
    /// The last state we told them, as a state is never sent twice in a row.
    var sent: InboundMessage.ChatState?
    /// Counts the times we said inactive, so a timer started by an earlier
    /// one can tell it has been superseded.
    var inactiveGeneration = 0
}

/// Typing indicators (XEP-0085) and read markers (XEP-0333) in 1:1 chats.
/// Both tell the contact what we're doing, so they only go to contacts in
/// our roster, and the user can turn each off.
extension XMPPSession {
    /// How long a chat stays inactive before we say we've left it (XEP-0085
    /// suggests about ten minutes).
    static let goneDelay: TimeInterval = 10 * 60

    /// Whether contacts see when we've read their messages.
    public var sendsReadMarkers: Bool { database.flag(.sendsReadMarkers, default: true) }

    public func setSendsReadMarkers(_ on: Bool) throws {
        try database.setFlag(.sendsReadMarkers, on)
    }

    /// Whether contacts see when we're typing, or looking at the chat.
    public var sendsChatStates: Bool { database.flag(.sendsChatStates, default: true) }

    public func setSendsChatStates(_ on: Bool) throws {
        try database.setFlag(.sendsChatStates, on)
    }

    // MARK: Chat states

    /// Tells `peer` what we're doing in our chat with them: looking at it,
    /// typing, stopped typing, away from it, or done with it. Only once they
    /// have shown they use chat states themselves, and never the same state
    /// twice in a row (XEP-0085 §5.1, §5.3).
    public func sendChatState(_ chatState: InboundMessage.ChatState, to peer: JID) {
        guard isConnected, let generation = claimChatState(chatState, to: peer) else { return }
        write(OutboundStanza.chatState(chatState, to: peer))
        if chatState == .inactive { scheduleGone(to: peer, generation: generation) }
    }

    /// Decides whether `chatState` goes to `peer` now, and if so records it
    /// as sent. Returns the tracker's inactive generation, or nil to send nothing.
    func claimChatState(_ chatState: InboundMessage.ChatState, to peer: JID) -> Int? {
        guard policy.sendsChatStates, !isGroup(peer), sendsChatStates,
              (try? database.isInRoster(peer)) == true else { return nil }
        return lock.withLock { state -> Int? in
            var tracker = state.chatStates[peer] ?? ChatStateTracker()
            guard tracker.supported == true, tracker.sent != chatState else { return nil }
            // Paused means we were typing, and nobody needs to hear we
            // stopped typing a message we never started.
            if chatState == .paused, tracker.sent != .composing { return nil }
            tracker.sent = chatState
            if chatState == .inactive { tracker.inactiveGeneration += 1 }
            state.chatStates[peer] = tracker
            return tracker.inactiveGeneration
        }
    }

    /// Says we're gone from the chat after `delay`, unless we've been active
    /// since, or went inactive again, which starts a delay of its own.
    func scheduleGone(to peer: JID, generation: Int, after delay: TimeInterval = XMPPSession.goneDelay) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.lock.withLock({ $0.chatStates[peer].map { $0.sent == .inactive && $0.inactiveGeneration == generation } ?? false }),
                  self.claimChatState(.gone, to: peer) != nil else { return }
            self.write(OutboundStanza.chatState(.gone, to: peer))
        }
    }

    /// Whether a message to `peer` should say we're active in the chat, as
    /// content messages should. Until the contact writes back, it must
    /// (XEP-0085 §5.1); if they then write without chat states, never again.
    /// Records that they've been told.
    func includesActiveState(to peer: JID) -> Bool {
        guard sendsChatStates else { return false }
        return lock.withLock { state in
            var tracker = state.chatStates[peer] ?? ChatStateTracker()
            guard tracker.supported != false else { return false }
            tracker.sent = .active
            state.chatStates[peer] = tracker
            return true
        }
    }

    /// Learns from what a contact sent us whether they use chat states: a
    /// message they wrote either carries one or doesn't. Only what they
    /// sent just now counts, from any of their devices.
    func noteChatStates(of inbound: InboundMessage, source: InboundMessage.Source) {
        guard !inbound.isGroupChat, !inbound.isOutgoing, !inbound.isError,
              inbound.correctionOf == nil, inbound.retractionOf == nil else { return }
        switch source {
        case .live, .carbon(sent: false): break
        default: return
        }
        let supported: Bool
        if inbound.chatState != nil {
            supported = true
        } else if inbound.body != nil {
            supported = false
        } else {
            // A receipt, a marker or a reaction says nothing either way.
            return
        }
        lock.withLock { state in
            var tracker = state.chatStates[inbound.peer] ?? ChatStateTracker()
            tracker.supported = supported
            state.chatStates[inbound.peer] = tracker
        }
    }

    // MARK: Read markers

    /// Tells `peer` we've read their messages, up to the newest that asked
    /// to know (XEP-0333) at or before `date`, once per message.
    func sendDisplayed(conversationId: Int64, to peer: JID, through date: Date = .distantFuture) {
        guard isConnected, let target = claimDisplayed(conversationId: conversationId, to: peer, through: date) else { return }
        write(OutboundStanza.displayed(to: peer, target: target))
    }

    /// The message id to mark as displayed for `peer`, if it's news to them.
    func claimDisplayed(conversationId: Int64, to peer: JID, through date: Date) -> String? {
        guard sendsReadMarkers, (try? database.isInRoster(peer)) == true,
              let message = try? database.lastIncoming(conversationId: conversationId, markable: true, through: date),
              let target = message.remoteId else { return nil }
        let isNew = lock.withLock { $0.sentDisplayed.updateValue(target, forKey: peer) != target }
        return isNew ? target : nil
    }
}
