import Foundation
@preconcurrency import Martin

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
            if let id = (try? database.groupChat(room))?.conversationId { try? database.forgetRoster(conversationId: id) }
        }
    }

    /// The room became private or stopped being so. What was counted under the
    /// other rules is dropped, and a room we are in counts afresh from its
    /// next complete listing, quietly.
    func rosterKeysChanged(_ room: JID, isJoined: Bool) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room) else { return }
            try? database.rosterRekeyed(conversationId: group.conversationId, takesBaseline: isJoined && group.isPrivate)
        }
    }

    /// Our own join is over: the first time, the baseline begins. A rejoin
    /// compares nothing, as the member lists are what is compared.
    func rosterSelfJoined(_ room: JID) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            do {
                try database.rosterSelfJoined(conversationId: group.conversationId)
            } catch {
                logger.error("Failed to begin counting a group's members: \(error)")
            }
        }
    }

    /// A presence took someone's membership (301, 321, 322), which the
    /// affiliation notice usually reports too.
    func rosterRemoved(_ room: JID, jid: JID?, statuses: Set<Int>) {
        guard let jid, jid != account, !statuses.isDisjoint(with: Self.membershipEndStatuses) else { return }
        rosterAffiliated(room, jid: jid, affiliation: statuses.contains(301) ? .outcast : .none)
    }

    /// The room listed members. Only a private group counts them, as there
    /// being a member is what lets someone read what we send.
    func rosterListed(_ room: JID, members: [JID]) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            try? database.rosterListed(conversationId: group.conversationId, room: room, members: members.filter { $0 != account }, at: Date())
        }
    }

    /// The owner, admin and member lists of one fetch have all come, and
    /// `members` is their union. Only then can absence be judged: a list that
    /// failed or was forbidden would make its members look gone.
    func rosterListingDone(_ room: JID, members: [JID]) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            try? database.rosterListingDone(conversationId: group.conversationId, room: room, members: members.filter { $0 != account }, at: Date())
        }
    }

    /// The room announced someone's affiliation, live.
    func rosterAffiliated(_ room: JID, jid: JID, affiliation: RoomAffiliation) {
        guard jid != account else { return }
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            try? database.rosterAffiliated(conversationId: group.conversationId, room: room, jid: jid, isMember: affiliation.isMember, at: Date())
        }
    }

    /// Waits for what has been told to the roster so far, for tests.
    func settleRoster() {
        rosterQueue.sync {}
    }
}
