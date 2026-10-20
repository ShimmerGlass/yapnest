import Foundation
@preconcurrency import Martin

/// Last seen (XEP-0012): see `LastActivity`.
extension XMPPSession {
    /// Whether the user shares when they were last active, and sees contacts'.
    public var sharesLastSeen: Bool { database.flag(.sharesLastSeen, default: false) }

    public func setSharesLastSeen(_ on: Bool) throws {
        try database.setFlag(.sharesLastSeen, on)
        try sharingLastSeenChanged()
    }

    /// What follows from the setting changing, whether the user changed it
    /// here or another of their devices did.
    func sharingLastSeenChanged() throws {
        if !sharesLastSeen {
            try database.clearLastSeen()
            lock.withLock { $0.lastSeenSchedule.reset() }
        }
        // The feature is in our capabilities only while sharing.
        client.modulesManager.module(CapabilitiesModule.IDENTIFIER).invalidateVerificationString()
        sendPresence()
    }

    /// Whether we tell contacts how long we've been idle, and say so in our
    /// capabilities.
    var offersLastActivity: Bool { policy.announcesPresence && sharesLastSeen }

    /// Seconds since the user last used the app, or left it: nothing while
    /// they're in it.
    func idleSeconds(now: Date = Date()) -> Int {
        guard let since = lock.withLock({ $0.idleSince }) else { return 0 }
        return max(0, Int(now.timeIntervalSince(since)))
    }

    /// What to tell `requester` when they ask, nil to refuse. The one place
    /// that decides: the module answers whatever this gives.
    func lastActivityAnswer(for requester: JID) -> Int? {
        guard offersLastActivity, LastActivity.mayAnswer(requester: try? database.contact(requester)) else { return nil }
        return idleSeconds()
    }

    /// A contact we saw online has gone, so they were last seen just now, and
    /// the header needn't ask their server. Only while the user shares theirs,
    /// as last seen is a favour between those who do.
    func contactWentOffline(_ jid: JID, now: Date = Date()) {
        guard offersLastActivity, !isGroup(jid) else { return }
        lock.withLock { $0.lastSeenSchedule.sawLeaving(jid) }
        Task.detached(priority: .utility) { [database] in
            guard (try? database.contact(jid))?.seesPresence == true else { return }
            try? database.setLastSeen(now, for: jid)
        }
    }

    /// Asks `peer`'s server when they were last online, if the user shares
    /// theirs and `peer` is an offline contact whose presence we see. Rate
    /// limited, so opening a chat again soon asks nothing.
    public func refreshLastSeen(of peer: JID) async {
        guard offersLastActivity, isConnected, !isGroup(peer),
              (try? database.contact(peer))?.seesPresence == true,
              (presences.value[peer] ?? .offline) == .offline,
              lock.withLock({ $0.lastSeenSchedule.claim(peer, now: Date()) }) else { return }
        do {
            let seconds = try await lastActivity(of: Martin.JID(peer.martin))
            // The user may have stopped sharing while we waited.
            guard sharesLastSeen else { return }
            try database.setLastSeen(Date().addingTimeInterval(-TimeInterval(seconds)), for: peer)
        } catch XMPPError.remote_server_timeout {
            // Worth asking again later.
        } catch {
            logger.info("No last seen from \(peer.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lock.withLock { $0.lastSeenSchedule.refuse(peer) }
        }
    }

    /// The seconds since `jid` was last active, as their server or client says.
    func lastActivity(of jid: Martin.JID) async throws -> Int {
        let iq = Iq()
        iq.type = .get
        iq.to = jid
        iq.addChild(Element(name: "query", xmlns: NS.last))
        let response = try await client.context.writer.write(iq: iq)
        guard let seconds = LastActivity.seconds(in: response.element) else { throw XMPPError.undefined_condition }
        return seconds
    }
}
