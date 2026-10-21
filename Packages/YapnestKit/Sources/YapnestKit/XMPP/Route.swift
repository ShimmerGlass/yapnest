import Foundation

/// Where an operation on a chat goes, resolved once per operation so that
/// everything it needs to know about the peer comes from one place: whether
/// it's a group, whether the room is ready, who to encrypt for, and which id
/// names a message.
enum Route: Sendable {
    case direct(JID)
    /// A group chat, with the room's live state as it was when resolved.
    case room(JID, status: RoomStatus?)

    /// Why an operation has to wait, if it does. Only rooms ever wait: a
    /// direct chat needs nothing but the connection.
    enum Readiness: Sendable {
        case ready
        /// The room hasn't confirmed our join.
        case notJoined
        /// We're in, but still catching up on what the room has.
        case syncing
    }

    var peer: JID {
        switch self {
        case .direct(let peer), .room(let peer, _): peer
        }
    }

    /// Whether stanzas are `type="groupchat"`, and read markers and
    /// references use the room's ids.
    var isGroup: Bool {
        if case .room = self { true } else { false }
    }

    var readiness: Readiness {
        switch self {
        case .direct: .ready
        case .room(_, let status): status?.readiness ?? .notJoined
        }
    }

    /// The single rule for every group operation: sends, edits, retractions
    /// and reactions all wait until the room has us and we've caught up.
    var isReady: Bool { readiness == .ready }

    /// Our nickname in the room, if it's a group we're in.
    var nickname: String? {
        if case .room(_, let status) = self { status?.nickname } else { nil }
    }

    /// Our XEP-0421 occupant id in the room, if it vouches for us.
    var occupantId: String? {
        if case .room(_, let status) = self { status?.occupantId } else { nil }
    }

    /// The addresses OMEMO encrypts for, besides our own devices.
    func recipients(excluding account: JID) -> [JID] {
        switch self {
        case .direct(let peer): [peer]
        case .room(_, let status): status?.recipients(excluding: account) ?? []
        }
    }

    /// How replies, reactions and retractions point at `message`: by the
    /// room's stanza-id in group chats, by the stanza's own id in 1:1 chats.
    func reference(to message: Message) -> String? {
        isGroup ? message.serverId : Self.directReference(to: message)
    }

    static func directReference(to message: Message) -> String? {
        message.remoteId ?? message.originId
    }
}

extension RoomStatus {
    var readiness: Route.Readiness {
        if !isJoined { .notJoined } else if isSyncing { .syncing } else { .ready }
    }

    /// Who an encrypted group message goes to, besides our own devices.
    func recipients(excluding account: JID) -> [JID] {
        let present = occupants.values.compactMap(\.jid)
        return Array(members.union(present).subtracting([account])).sorted()
    }
}

extension XMPPSession {
    /// The route to `peer`, by the rooms we know of.
    func route(to peer: JID) -> Route {
        isGroup(peer) ? .room(peer, status: roomStatus(peer)) : .direct(peer)
    }

    /// The route to a conversation's peer, by what the conversation is.
    func route(for conversation: Conversation) -> Route {
        conversation.kind == .groupchat ? .room(conversation.peer, status: roomStatus(conversation.peer)) : .direct(conversation.peer)
    }

    /// Runs `send` now if `route` is ready, else once the room has us and has
    /// caught up (`sendDeferred`). What waits here is lost if the app quits, so
    /// whatever matters is also stored as pending (a message, a reaction, a
    /// correction or retraction) and sent again by `sendUnclaimedPending`.
    func whenReady(_ route: Route, _ send: @escaping @Sendable () -> Void) {
        guard case .room(let room, _) = route else { return send() }
        // Checked and queued under one lock hold, so the catch-up ending
        // can't slip in between and leave this waiting for nothing.
        let ready = lock.withLock { state -> Bool in
            if state.rooms[room]?.readiness == .ready { return true }
            state.deferredSends[room, default: []].append(send)
            return false
        }
        if ready { send() }
    }

    /// Sends what waited for `room` to be ready. Call after it is.
    func sendDeferred(in room: JID) {
        let sends = lock.withLock { $0.deferredSends.removeValue(forKey: room) ?? [] }
        for send in sends { send() }
    }

    /// Forgets what waited for a room we've left.
    func dropDeferred(in room: JID) {
        lock.withLock { _ = $0.deferredSends.removeValue(forKey: room) }
    }
}
