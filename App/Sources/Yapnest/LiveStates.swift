import Foundation
import Observation
import YapnestKit

/// What the screens show of one contact, in a box of its own. A view reads
/// the boxes of the contacts it shows and nobody else's, so someone starting
/// to type, or one presence, redraws that contact's views and not all of them.
@MainActor
@Observable
final class PeerState {
    fileprivate(set) var isTyping = false
    /// Nil when the session has none for them: not the same as offline.
    fileprivate(set) var presence: ContactPresence?
    fileprivate(set) var status: String?
}

/// The same for one group chat. `phase` and `memberCount` are kept apart
/// from `status`, so the header isn't redrawn at every occupant's change in
/// the room it shows.
@MainActor
@Observable
final class RoomState {
    fileprivate(set) var status: RoomStatus?
    fileprivate(set) var phase: RoomStatus.Phase?
    fileprivate(set) var memberCount = 0
}

/// The boxes, by contact and by room. The dictionaries aren't observed: a box
/// is made the first time a view asks for it, and then stays for the session,
/// so a view never holds one that later changes are made to another of. Their
/// number is bounded by the people and rooms we hear of.
@MainActor
final class LiveStates {
    private var peers: [JID: PeerState] = [:]
    private var rooms: [JID: RoomState] = [:]
    /// What was last applied, to find what a new whole table changes.
    private var presences: [JID: ContactPresence] = [:]
    private var statuses: [JID: String] = [:]

    func peer(_ jid: JID) -> PeerState {
        if let box = peers[jid] { return box }
        let box = PeerState()
        peers[jid] = box
        return box
    }

    func room(_ jid: JID) -> RoomState {
        if let box = rooms[jid] { return box }
        let box = RoomState()
        rooms[jid] = box
        return box
    }

    func setTyping(_ jid: JID, _ typing: Bool) {
        // Nobody is watching a peer that has no box, and none is typing.
        guard typing || peers[jid] != nil else { return }
        let box = peer(jid)
        if box.isTyping != typing { box.isTyping = typing }
    }

    /// Applies a whole table of availabilities, touching only the boxes it
    /// changes. Returns the table it replaces.
    @discardableResult
    func apply(presences new: [JID: ContactPresence]) -> [JID: ContactPresence] {
        let before = presences
        for (jid, presence) in new where before[jid] != presence { peer(jid).presence = presence }
        for jid in before.keys where new[jid] == nil { peers[jid]?.presence = nil }
        presences = new
        return before
    }

    func apply(statuses new: [JID: String]) {
        for (jid, status) in new where statuses[jid] != status { peer(jid).status = status }
        for jid in statuses.keys where new[jid] == nil { peers[jid]?.status = nil }
        statuses = new
    }

    func apply(room jid: JID, status: RoomStatus?) {
        // A room nobody has asked about needs no box until someone does.
        guard status != nil || rooms[jid] != nil else { return }
        let box = room(jid)
        if box.status != status { box.status = status }
        if box.phase != status?.phase { box.phase = status?.phase }
        let count = status?.memberCount ?? 0
        if box.memberCount != count { box.memberCount = count }
    }

    /// Empties every box, as the account they belonged to is gone.
    func reset() {
        apply(presences: [:])
        apply(statuses: [:])
        for jid in rooms.keys { apply(room: jid, status: nil) }
        for box in peers.values where box.isTyping { box.isTyping = false }
    }
}
