import Foundation
@preconcurrency import Martin

/// Moderating a group: who is in it, and which messages stay.
extension XMPPSession {
    // MARK: Requests

    /// Asks the room, and again while the answer is one that can pass. What
    /// it throws is for the user: the server's own error, which `ServerError`
    /// can tell apart, or that we're offline. The request is made anew for
    /// each attempt, as a stanza keeps its id.
    func roomRequest(_ iq: @autoclosure () -> Iq) async throws -> Iq {
        do {
            return try await retryingPassingErrors { try await client.context.writer.write(iq: iq()) }
        } catch {
            throw Self.roomRequestError(error, isConnected: isConnected)
        }
    }

    /// A connection that went away reads as Martin's not-authorized, which
    /// would be taken for the room refusing us.
    static func roomRequestError(_ error: Error, isConnected: Bool) -> Error {
        if !isConnected { return GroupError.notConnected }
        if case XMPPError.not_authorized(let message?) = error, message.contains("not connected") { return GroupError.notConnected }
        return error
    }

    // MARK: Members

    /// Takes `member` out of the group. In a members-only room losing the
    /// membership also puts them out of it.
    public func removeMember(_ member: JID, from room: JID) async throws {
        try await changeAffiliation(of: member, in: room, to: .none, requires: \.canRemove)
    }

    /// Takes `member` out of the group and keeps them from coming back.
    public func banMember(_ member: JID, from room: JID) async throws {
        try await changeAffiliation(of: member, in: room, to: .outcast, requires: \.canBan)
    }

    /// Makes `member` an admin, or an ordinary member again.
    public func setAdmin(_ isAdmin: Bool, member: JID, in room: JID) async throws {
        if isAdmin {
            try await changeAffiliation(of: member, in: room, to: .admin, requires: \.canMakeAdmin)
        } else {
            try await changeAffiliation(of: member, in: room, to: .member, requires: \.canRemoveAdmin)
        }
    }

    /// Lets a banned `member` back in as an ordinary non-member. Only a
    /// members-only room still keeps them out.
    public func unban(_ member: JID, in room: JID) async throws {
        try await changeAffiliation(of: member, in: room, to: .none, requires: \.canUnban)
    }

    /// Makes `member` an owner, or takes ownership away, leaving an admin
    /// (§10.4 allows either that or a member; an admin keeps what they could
    /// do as an owner short of changing the room). Only owners do either.
    /// We may give up ours too, unless we are the last owner.
    public func setOwner(_ isOwner: Bool, member: JID, in room: JID) async throws {
        if isOwner {
            try await changeAffiliation(of: member, in: room, to: .owner, requires: \.canMakeOwner)
        } else {
            try await changeAffiliation(of: member, in: room, to: .admin, requires: \.canRemoveOwner)
        }
    }

    /// Puts the occupant `nickname` out of the room for now, for a moderator.
    /// They keep their membership and may come back (§8.2).
    public func kick(nickname: String, reason: String? = nil, in room: JID) async throws {
        let status = try await joinedStatus(room)
        guard let occupant = status.occupants[nickname],
              GroupModeration.actions(
                  by: status.affiliation, on: occupant.affiliation, isSelf: nickname == status.nickname,
                  actorRole: status.role, targetIsPresent: true,
              ).canKick else { throw GroupError.notAllowed }
        _ = try await roomRequest(OutboundStanza.kick(nickname: nickname, reason: reason, in: room))
        updateRoom(room) { status in
            _ = status?.occupants.removeValue(forKey: nickname)
        }
    }

    /// Asks the room for who is banned, which `RoomStatus.banned` keeps.
    public func refreshBanList(of room: JID) async throws {
        guard try await joinedStatus(room).canSeeBans else { throw GroupError.notAllowed }
        let response = try await roomRequest(OutboundStanza.affiliationList(.outcast, of: room))
        listReceived(.outcast, in: room, response)
    }

    private func changeAffiliation(
        of member: JID, in room: JID, to affiliation: RoomAffiliation, requires needs: KeyPath<GroupModeration.MemberActions, Bool>,
    ) async throws {
        let status = try await joinedStatus(room)
        guard GroupModeration.actions(
            by: status.affiliation, on: status.affiliation(of: member), isSelf: member == account, isLastOwner: status.isLastOwner(account),
        )[keyPath: needs] else { throw GroupError.notAllowed }
        _ = try await roomRequest(OutboundStanza.affiliation(affiliation, of: member, in: room))
        // Someone who isn't here sends no presence to tell by.
        updateRoom(room) { status in
            status?.setAffiliation(affiliation, of: member)
            if member == account { status?.affiliation = affiliation }
        }
    }

    /// The room tells everyone present when it changes the affiliation of
    /// someone, present or not, with their address if it shows those.
    func affiliationChanged(in room: JID, _ stanza: Martin.Message) {
        guard let x = stanza.firstChild(name: "x", xmlns: NS.mucUser) else { return }
        let changes = x.filterChildren(name: "item", xmlns: nil).compactMap { item -> (JID, RoomAffiliation)? in
            guard let jid = item.getAttribute("jid").flatMap(JID.init(_:)),
                  let affiliation = item.getAttribute("affiliation").flatMap(RoomAffiliation.init) else { return nil }
            return (jid, affiliation)
        }
        guard !changes.isEmpty else { return }
        updateRoom(room) { status in
            for (jid, affiliation) in changes { status?.setAffiliation(affiliation, of: jid) }
        }
    }

    // MARK: Messages

    /// Whether the user may take `message`, in the group `room`, back for
    /// everyone: someone else's, still standing, and stamped by a room that
    /// offers moderated retraction, to a moderator. Takes the room so a menu
    /// can ask without a database read.
    public func canRetractForEveryone(_ message: Message, in room: JID) -> Bool {
        message.direction == .incoming && !message.isRetracted && message.serverId != nil
            && roomStatus(room)?.canModerateMessages == true
    }

    /// Takes someone else's message back for everyone (XEP-0425). The room
    /// announces it to all, us included, but the message goes at once.
    public func retractForEveryone(_ message: Message) async throws {
        guard let target = message.serverId,
              let conversation = try database.conversation(id: message.conversationId) else { throw GroupError.notConnected }
        _ = try await joinedStatus(conversation.peer)
        guard canRetractForEveryone(message, in: conversation.peer) else { throw GroupError.notAllowed }
        _ = try await roomRequest(OutboundStanza.moderatedRetraction(of: target, in: conversation.peer))
        if let attachment = try database.applyModeratedRetraction(in: conversation.peer, target: target) { attachments.remove(attachment) }
    }

    /// The room-stanza-id a moderator's retraction (XEP-0425) names, if
    /// `stanza` is one. It must come from the room itself, its bare address:
    /// from an occupant it would let anyone delete what others wrote.
    static func moderatedRetraction(in stanza: Martin.Message) -> String? {
        guard stanza.type == .groupchat, let from = stanza.from, from.resource == nil else { return nil }
        if let retract = stanza.firstChild(name: "retract", xmlns: NS.retraction), retract.firstChild(name: "moderated", xmlns: NS.moderation) != nil {
            return retract.getAttribute("id").flatMap { $0.isEmpty ? nil : $0 }
        }
        // The older form, wrapped in XEP-0422 apply-to.
        if let applyTo = stanza.firstChild(name: "apply-to", xmlns: NS.fasten),
           applyTo.firstChild(name: "moderated", xmlns: NS.moderationV0)?.firstChild(name: "retract", xmlns: NS.retractionV0) != nil {
            return applyTo.getAttribute("id").flatMap { $0.isEmpty ? nil : $0 }
        }
        return nil
    }
}

// MARK: Fixtures

extension XMPPSession {
    /// Puts the session in `room` without a server, so UI tests can show what
    /// an owner or a plain member sees. We are the occupant with our address.
    public func joinForFixture(_ room: JID, occupants: [RoomOccupant], banned: [JID] = []) {
        guard let me = occupants.first(where: { $0.jid == account }) else { return }
        updateRoom(room) { status in
            var joined = RoomStatus(phase: .joined, nickname: me.nick)
            joined.affiliation = me.affiliation
            joined.role = me.role
            joined.supportsModeration = true
            joined.occupants = Dictionary(uniqueKeysWithValues: occupants.map { ($0.nick, $0) })
            for occupant in occupants {
                if let jid = occupant.jid { joined.setAffiliation(occupant.affiliation, of: jid) }
            }
            for jid in banned { joined.setAffiliation(.outcast, of: jid) }
            status = joined
        }
    }
}
