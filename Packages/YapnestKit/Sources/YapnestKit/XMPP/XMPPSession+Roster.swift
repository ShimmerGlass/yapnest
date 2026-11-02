import Foundation
@preconcurrency import Martin

/// When each room last took membership from someone, kept in memory so that
/// a member listing begun before it doesn't count them again. Touched only on
/// `XMPPSession.rosterQueue`; what a restart loses is a fetch that is lost too.
final class RosterRemovals: @unchecked Sendable {
    private var at: [JID: [JID: Date]] = [:]

    func record(_ jid: JID, in room: JID, at date: Date) { at[room, default: [:]][jid] = date }

    /// Who was removed after `since`. Older records can't matter to any later
    /// fetch, so they are dropped.
    func removed(in room: JID, after since: Date) -> Set<JID> {
        at[room] = at[room]?.filter { $0.value >= since }
        return Set(at[room]?.keys.map { $0 } ?? [])
    }

    func forget(_ room: JID) { at[room] = nil }
}

/// Joins and leaves in a private group, as lines in its chat. A room's service
/// could add someone who then receives everything we encrypt there, so the
/// chat says who became a member and who stopped being one. Being online in
/// the room says nothing about that, so going offline, coming back, a new
/// nickname or a kick that leaves the affiliation alone write nothing. Groups
/// that are not private write nothing at all: there, who reads what we send
/// is not decided by membership. See `AppDatabase.rosterListingDone` for the
/// counting. Everything runs on `rosterQueue`, in the order it was told.
extension XMPPSession {
    /// A group we left or that ended: coming back is a first join.
    func rosterForget(_ room: JID) {
        rosterQueue.async { [self] in
            rosterRemovals.forget(room)
            if let id = (try? database.groupChat(room))?.conversationId { try? database.forgetRoster(conversationId: id) }
        }
    }

    /// Runs `change` for a private group on `rosterQueue`; other groups count
    /// nothing, as there being a member is not what lets someone read what we send.
    private func countingPrivate(_ room: JID, _ change: @escaping @Sendable (GroupChat) throws -> Void) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            do {
                try change(group)
            } catch {
                logger.error("Failed to count a group's members: \(error)")
            }
        }
    }

    /// Our own join is over: the first time, the baseline begins. A rejoin
    /// compares nothing, as the member lists are what is compared.
    func rosterSelfJoined(_ room: JID) {
        // Dated now, not when the queue gets to it: the member fetch that
        // follows must count as begun after it.
        let date = Date()
        countingPrivate(room) { [database] in try database.rosterSelfJoined(conversationId: $0.conversationId, at: date) }
    }

    /// A presence took someone's membership (301, 321, 322), which the
    /// affiliation notice usually reports too.
    func rosterRemoved(_ room: JID, jid: JID?, statuses: Set<Int>) {
        guard let jid, jid != account, !statuses.isDisjoint(with: Self.membershipEndStatuses) else { return }
        rosterAffiliated(room, jid: jid, isMember: false)
    }

    /// The owner, admin and member lists of the fetch begun at `since` have
    /// all come, and `members` is their union. Only then can absence be
    /// judged: a list that failed or was forbidden would make its members
    /// look gone.
    func rosterListingDone(_ room: JID, members: [JID], since: Date) {
        let members = members.filter { $0 != account }
        countingPrivate(room) { [database, rosterRemovals] in
            let removed = rosterRemovals.removed(in: room, after: since)
            try database.rosterListingDone(conversationId: $0.conversationId, room: room, members: members, since: since, removed: removed, at: Date())
        }
    }

    /// The room refused the member lists of the fetch begun at `since`.
    func rosterListingRefused(_ room: JID, since: Date) {
        countingPrivate(room) { [database] in try database.rosterListingRefused(conversationId: $0.conversationId, since: since) }
    }

    /// The room announced someone's affiliation, live.
    func rosterAffiliated(_ room: JID, jid: JID, affiliation: RoomAffiliation) {
        rosterAffiliated(room, jid: jid, isMember: affiliation.isMember)
    }

    private func rosterAffiliated(_ room: JID, jid: JID, isMember: Bool) {
        guard jid != account else { return }
        let date = Date()
        countingPrivate(room) { [database, rosterRemovals] in
            if !isMember { rosterRemovals.record(jid, in: room, at: date) }
            try database.rosterAffiliated(conversationId: $0.conversationId, room: room, jid: jid, isMember: isMember, at: Date())
        }
    }

    /// Waits for what has been told to the roster so far, for tests.
    func settleRoster() {
        rosterQueue.sync {}
    }
}
