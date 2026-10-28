import Foundation
@preconcurrency import Martin

/// What the session knows of who is in each group right now, apart from
/// `RoomStatus`: presences are told here one by one, in the order they came,
/// so a join and a leave within one batch of occupant changes both count.
/// Touched only on `XMPPSession.rosterQueue`.
final class RosterState: @unchecked Sendable {
    /// An occupant other than us, as their presences name them.
    struct Seen: Hashable {
        let nick: String
        let jid: JID?

        /// Who they are in a room that `showsAddresses` or not.
        func person(showsAddresses: Bool) -> RosterPerson {
            RosterPerson(nick: nick, jid: showsAddresses ? jid : nil)
        }
    }

    /// Who is present, by nickname.
    var present: [JID: [String: Seen]] = [:]
    /// Departures waiting out the grace, by group and key.
    var departures: [JID: [String: DispatchWorkItem]] = [:]

    func cancelDeparture(_ room: JID, _ key: String) {
        departures[room]?.removeValue(forKey: key)?.cancel()
    }

    func isPresent(_ room: JID, key: String, showsAddresses: Bool) -> Bool {
        present[room]?.values.contains { $0.person(showsAddresses: showsAddresses).key == key } ?? false
    }

    func people(_ room: JID, showsAddresses: Bool) -> [RosterPerson] {
        (present[room] ?? [:]).values.map { $0.person(showsAddresses: showsAddresses) }
    }

    /// Forgets `room`'s people and waiting departures, or every room's.
    func clear(_ room: JID?) {
        if let room {
            present[room] = nil
            departures.removeValue(forKey: room)?.values.forEach { $0.cancel() }
        } else {
            present = [:]
            departures.values.forEach { $0.values.forEach { $0.cancel() } }
            departures = [:]
        }
    }
}

/// Joins and leaves in a group, as lines in its chat. A room's service could
/// add someone who then receives everything we encrypt there, so the chat
/// says who came and went. See `AppDatabase.rosterArrived` for the counting.
extension XMPPSession {
    /// Groups with more occupants than this, unless private, say nothing.
    static let rosterLineLimit = 50

    /// A join begins: whoever was here before is told again.
    func rosterJoinStarted(_ room: JID) {
        rosterQueue.async { [self] in
            roster.clear(room)
            roster.present[room] = [:]
        }
    }

    /// A new connection starts over, and its joins are compared with what we
    /// counted. Not a dropped one: a stream that resumes sends nothing again,
    /// so the departures waiting out their grace go on.
    func rosterReset() {
        rosterQueue.async { [self] in roster.clear(nil) }
    }

    /// A group we left or that ended: coming back is a first join.
    func rosterForget(_ room: JID) {
        rosterQueue.async { [self] in
            roster.clear(room)
            if let id = (try? database.groupChat(room))?.conversationId { try? database.forgetRoster(conversationId: id) }
        }
    }

    /// The room now shows or hides addresses, which changes who each person
    /// is. They are counted afresh, quietly, or a rejoin would take everyone
    /// for someone who left and someone who joined.
    func rosterKeysChanged(_ room: JID, isJoined: Bool) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room) else { return }
            let people = isJoined ? roster.people(room, showsAddresses: group.isNonAnonymous) : nil
            try? database.rosterRekeyed(conversationId: group.conversationId, present: people)
        }
    }

    /// An occupant other than us arrived. `isJoined` says whether our own
    /// join is over, as the join's end compares everyone who arrived before it.
    func rosterArrived(_ room: JID, nick: String, jid: JID?, ownNick: String, isJoined: Bool) {
        guard nick != ownNick, jid != account else { return }
        rosterQueue.async { [self] in
            let seen = RosterState.Seen(nick: nick, jid: jid)
            // A change of show or status, which counts no one.
            if roster.present[room]?[nick] == seen { return }
            roster.present[room, default: [:]][nick] = seen
            guard isJoined, let group = try? database.groupChat(room) else { return }
            let person = seen.person(showsAddresses: group.isNonAnonymous)
            roster.cancelDeparture(room, person.key)
            try? database.rosterArrived(conversationId: group.conversationId, room: room, person: person, writesLines: rosterWritesLines(group), at: Date())
        }
    }

    /// Our own join is over: the first time, everyone present is the baseline.
    func rosterSelfJoined(_ room: JID) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room) else { return }
            do {
                try database.rosterSelfJoined(
                    conversationId: group.conversationId, room: room, present: roster.people(room, showsAddresses: group.isNonAnonymous),
                    writesLines: rosterWritesLines(group), at: Date(),
                )
            } catch {
                logger.error("Failed to count a group's people: \(error)")
            }
        }
    }

    /// An occupant other than us left, or changed nickname (303, to `newNick`).
    /// A kick, ban or removal counts at once; any other leaving only after the
    /// grace, as a connection may only have dropped.
    func rosterDeparted(_ room: JID, nick: String, jid: JID?, statuses: Set<Int>, newNick: String?, ownNick: String, isJoined: Bool) {
        guard nick != ownNick else { return }
        rosterQueue.async { [self] in
            let known = roster.present[room]?.removeValue(forKey: nick)
            let renaming = statuses.contains(303)
            guard isJoined || renaming, let group = try? database.groupChat(room) else { return }
            let showsAddresses = group.isNonAnonymous
            let seen = known ?? RosterState.Seen(nick: nick, jid: jid)
            let person = seen.person(showsAddresses: showsAddresses)
            if renaming {
                guard let newNick else { return }
                roster.present[room, default: [:]][newNick] = RosterState.Seen(nick: newNick, jid: seen.jid)
                guard isJoined else { return }
                roster.cancelDeparture(room, person.key)
                try? database.rosterRenamed(conversationId: group.conversationId, from: person.key, to: RosterPerson(nick: newNick, jid: person.jid))
                return
            }
            let key = person.key
            // Still here under another nickname.
            guard !roster.isPresent(room, key: key, showsAddresses: showsAddresses) else { return }
            if !statuses.isDisjoint(with: Self.departureStatuses) {
                roster.cancelDeparture(room, key)
                rosterDepart(group, key: key, endsMembership: !statuses.isDisjoint(with: Self.membershipEndStatuses))
                return
            }
            roster.cancelDeparture(room, key)
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                roster.departures[room]?[key] = nil
                // Back under another nickname, or since.
                guard let group = try? database.groupChat(room),
                      !roster.isPresent(room, key: key, showsAddresses: group.isNonAnonymous) else { return }
                rosterDepart(group, key: key, endsMembership: false)
            }
            roster.departures[room, default: [:]][key] = item
            rosterQueue.asyncAfter(deadline: .now() + rosterGrace, execute: item)
        }
    }

    /// On `rosterQueue`.
    private func rosterDepart(_ group: GroupChat, key: String, endsMembership: Bool) {
        try? database.rosterDeparted(conversationId: group.conversationId, room: group.jid, key: key, endsMembership: endsMembership, writesLines: rosterWritesLines(group), at: Date())
    }

    /// The room listed its members. Only where being a member is what lets
    /// someone read what we send: a private group.
    func rosterListed(_ room: JID, members: [JID]) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            try? database.rosterListed(
                conversationId: group.conversationId, room: room, members: members.filter { $0 != account },
                writesLines: rosterWritesLines(group), at: Date(),
            )
        }
    }

    /// The members asked for after joining have all come, so the next list
    /// that names someone we haven't counted is news.
    func rosterListingDone(_ room: JID) {
        rosterQueue.async { [self] in
            guard let group = try? database.groupChat(room) else { return }
            try? database.rosterListingDone(conversationId: group.conversationId)
        }
    }

    /// The room announced someone's affiliation, live.
    func rosterAffiliated(_ room: JID, jid: JID, affiliation: RoomAffiliation) {
        guard jid != account else { return }
        rosterQueue.async { [self] in
            // As for member lists.
            guard let group = try? database.groupChat(room), group.isPrivate else { return }
            let isPresent = roster.isPresent(room, key: jid.description, showsAddresses: group.isNonAnonymous)
            try? database.rosterAffiliated(
                conversationId: group.conversationId, room: room, jid: jid, isMember: affiliation.isMember, isPresent: isPresent,
                writesLines: rosterWritesLines(group), at: Date(),
            )
        }
    }

    /// Private groups always say; others only while they are small.
    private func rosterWritesLines(_ group: GroupChat) -> Bool {
        group.isPrivate || (roster.present[group.jid]?.count ?? 0) + 1 <= Self.rosterLineLimit
    }

    /// Waits for what has been told to the roster so far, for tests.
    func settleRoster() {
        rosterQueue.sync {}
    }
}
