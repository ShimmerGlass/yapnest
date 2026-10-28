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

    /// How many contacts have a box, for the tests.
    var peerCount: Int { peers.count }

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

    /// Applies one contact's availability and status, touching only what
    /// differs. Returns the availability it replaces.
    @discardableResult
    func apply(peer jid: JID, presence: ContactPresence?, status: String?) -> ContactPresence? {
        // A peer nobody has asked about needs no box until someone does.
        guard presence != nil || status != nil || peers[jid] != nil else { return nil }
        let box = peer(jid)
        let before = box.presence
        if box.presence != presence { box.presence = presence }
        if box.status != status { box.status = status }
        return before
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
        for (jid, box) in peers {
            apply(peer: jid, presence: nil, status: nil)
            if box.isTyping { box.isTyping = false }
        }
        for jid in rooms.keys { apply(room: jid, status: nil) }
    }
}
