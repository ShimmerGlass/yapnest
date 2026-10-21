import Foundation
@preconcurrency import Martin

/// The roster, and presence subscription requests (RFC 6121) from people
/// we haven't added, which wait for the user to accept or decline them.
extension XMPPSession {
    public enum ContactError: Error, LocalizedError {
        case offline
        case notInRoster

        public var errorDescription: String? {
            switch self {
            case .offline: String(localized: "You're offline.")
            case .notInRoster: String(localized: "They aren't one of your contacts.")
            }
        }
    }

    /// Adds `jid` to the roster and asks to see their presence. Also
    /// pre-approves theirs, so adding each other works in one step. Writes to
    /// the database, so call it off the main thread. A `preauth` token from
    /// an invitation (XEP-0379) goes with the request.
    public func addContact(_ jid: JID, name: String? = nil, preauth: String? = nil) {
        guard isConnected, jid != account else { return }
        markAddedBeforeAsking(jid)
        client.module(.roster).addItem(jid: Martin.JID(jid.martin), name: name, groups: [], completionHandler: nil)
        askToSubscribe(to: jid, preauth: preauth)
    }

    /// `addContact` for a button that shows the outcome: it waits for the
    /// server to take the roster item, and throws if it refuses or never
    /// answers. The subscription request is only sent once it has.
    public func addContactAndWait(_ jid: JID, name: String? = nil, preauth: String? = nil) async throws {
        guard isConnected else { throw ContactError.offline }
        guard jid != account else { return }
        _ = try await client.module(.roster).addItem(jid: Martin.JID(jid.martin), name: name, groups: [])
        // Only once the server took the item: a refused or unanswered add
        // must not leave a stranger's later request auto-approved.
        markAddedBeforeAsking(jid)
        askToSubscribe(to: jid, preauth: preauth)
    }

    /// Before the subscription request is sent, so their request, which may
    /// come straight back, is already known to be welcome.
    private func markAddedBeforeAsking(_ jid: JID) {
        do {
            try database.markAddedByUser(jid)
        } catch {
            logger.error("Failed to note an added contact: \(error)")
        }
    }

    private func askToSubscribe(to jid: JID, preauth: String?) {
        // Tells them who is asking (XEP-0172), as they only have an address.
        write(OutboundStanza.subscriptionRequest(to: jid, nickname: nickname, preauth: preauth))
        client.module(.presence).subscribed(by: Martin.JID(jid.martin))
    }

    /// Takes `jid` off the roster on all our devices: neither of us sees the
    /// other's presence any more, and a request we sent them is withdrawn.
    /// The chat stays, and they can still message us.
    public func removeContact(_ jid: JID) async throws {
        guard isConnected else { throw ContactError.offline }
        // Removing the item should withdraw our request too (RFC 6121),
        // but ejabberd keeps it, and they'd still be asked.
        if (try? database.contact(jid))??.isSubscriptionPending == true {
            try await client.module(.presence).unsubscribe(from: Martin.JID(jid.martin))
        }
        _ = try await client.module(.roster).removeItem(jid: Martin.JID(jid.martin))
        // The server's push says the same; this is for the UI, right away.
        try database.removeRosterItem(jid: jid)
    }

    /// Gives a contact the name the user chose for them, on all their devices;
    /// nil or blank goes back to the name they publish. Only for people
    /// already in the roster: a roster set would otherwise add them, which
    /// shares our presence. The database follows the server's roster push.
    public func setContactName(_ jid: JID, name: String?) async throws {
        guard isConnected else { throw ContactError.offline }
        guard let contact = try database.contact(jid), contact.isInRoster else { throw ContactError.notInRoster }
        // A roster set replaces the item's name and groups, so the groups are
        // the current ones. Its subscription is left out, which keeps it.
        _ = try await client.module(.roster).updateItem(jid: Martin.JID(jid.martin), name: Self.normalizedNickname(name), groups: contact.rosterGroups)
    }

    /// Adds them back and lets them see our presence, as `addContact` does.
    public func acceptContactRequest(from jid: JID) throws {
        guard isConnected else { throw ContactError.offline }
        // Their chosen name isn't copied into the roster: it would be ours on
        // every device, set by a stranger. The roster name stays the user's.
        addContact(jid)
        try database.clearContactRequest(from: jid)
    }

    /// Befriends someone the user starts a chat with. A request of theirs is
    /// accepted, which also takes it off the chat list; anyone else not yet
    /// on the roster is added. Offline it does nothing: the chat opens all the
    /// same, and its banner offers the same step once there's a connection.
    public func befriendForNewChat(_ jid: JID) {
        guard isConnected else { return }
        if (try? database.contact(jid))??.hasContactRequest == true {
            try? acceptContactRequest(from: jid)
        } else if (try? database.isInRoster(jid)) != true {
            addContact(jid)
        }
    }

    /// Refuses to share our presence. They aren't told anything else, and
    /// can still message us.
    public func declineContactRequest(from jid: JID) throws {
        guard isConnected else { throw ContactError.offline }
        client.module(.presence).unsubscribed(by: Martin.JID(jid.martin))
        try database.clearContactRequest(from: jid)
    }

    /// A stranger's request. The name they give is their own claim, so it's
    /// cleaned like any other remote name.
    func recordContactRequest(from jid: JID, nickname: String?) throws {
        let isNew = (try database.contact(jid))?.subscriptionRequestedAt == nil
        try database.recordContactRequest(from: jid, nickname: Self.normalizedNickname(nickname))
        if isNew { fetchAvatar(of: jid) }
    }

    func subscriptionChanged(_ change: PresenceModule.SubscriptionChange) {
        guard let jid = JID(change.jid), jid != account else { return }
        do {
            switch change.action {
            case .subscribe:
                lock.withLock { _ = $0.repeatedContactRequests.insert(jid) }
                // Approved without asking when the user already agreed: we
                // approved them before (subscription from or both), we asked
                // them and they ask back (the server's pending ask, seen by
                // all the user's devices), or the user added them here (a
                // fallback if the server dropped our pre-approval). The
                // roster alone doesn't say so: a server can put a stranger in it.
                if try database.hasApprovedOrAdded(jid) {
                    client.module(.presence).subscribed(by: Martin.JID(jid.martin))
                    return
                }
                try recordContactRequest(from: jid, nickname: change.presence.nickname)
            case .unsubscribe:
                // A request they withdrew.
                try database.clearContactRequest(from: jid)
            case .unsubscribed:
                break
            }
        } catch {
            logger.error("Failed to store a contact request: \(error)")
        }
    }

    /// Forgets requests the server didn't repeat when we signed in: another
    /// device answered them, or they were withdrawn while we were away.
    /// Only after a new session's initial presence, which they follow.
    func pruneContactRequests() {
        let repeated = lock.withLock { state -> Set<JID>? in
            defer { state.prunesContactRequests = false }
            return state.prunesContactRequests ? state.repeatedContactRequests : nil
        }
        guard let repeated else { return }
        do {
            try database.clearContactRequests(except: repeated)
        } catch {
            logger.error("Failed to prune contact requests: \(error)")
        }
    }
}
