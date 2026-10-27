import Combine
import Foundation
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// A room sends everyone present when we join, one presence each, and
/// applying each as it came copied the room's state every time.
struct RoomOccupantBatchTests {
    let session: XMPPSession
    private let updates = Updates()

    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [RoomUpdate] = []
        var cancellable: AnyCancellable?
        var count: Int { lock.withLock { all.count } }
        var last: RoomUpdate? { lock.withLock { all.last } }
        func add(_ update: RoomUpdate) { lock.withLock { all.append(update) } }
    }

    init() throws {
        session = try makeSession(me)
        try session.database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        // Long enough that only the tests decide when the occupants are applied.
        session.occupantWindow = 60
        session.updateRoom(room) { $0 = RoomStatus(phase: .joining, nickname: "me") }
        let updates = updates
        updates.cancellable = session.roomUpdates.sink { updates.add($0) }
    }

    private func occupant(_ index: Int, type: String? = nil) -> Martin.Presence {
        let type = type.map { " type='\($0)'" } ?? ""
        return parseStanza("<presence from='cake@rooms.example.org/user\(index)'\(type)><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='participant' jid='user\(index)@example.org/phone'/></x></presence>")
    }

    private func selfPresence() -> Martin.Presence {
        parseStanza("<presence from='cake@rooms.example.org/me'><x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='member' role='participant'/><status code='110'/></x></presence>")
    }

    @Test func fiveHundredOccupantsAreOneUpdate() {
        for index in 0..<500 { session.roomPresence(occupant(index), room: room) }
        #expect(updates.count == 0)

        session.applyOccupantChanges()

        #expect(updates.count == 1)
        #expect(updates.last?.status?.occupants.count == 500)
        #expect(session.rooms.value[room]?.occupants.count == 500)
    }

    @Test func ourOwnPresenceEndsTheJoinWithTheOthersInTheSameUpdate() {
        for index in 0..<500 { session.roomPresence(occupant(index), room: room) }

        session.roomPresence(selfPresence(), room: room)

        #expect(updates.count == 1)
        #expect(updates.last?.status?.occupants.count == 501)
        #expect(updates.last?.status?.isJoined == true)
    }

    @Test func readingTheRoomAppliesWhatIsWaiting() {
        session.roomPresence(occupant(1), room: room)

        #expect(session.roomStatus(room)?.occupants.count == 1)
        #expect(updates.count == 1)
    }

    @Test func aDepartureAfterAnArrivalLeavesNobody() {
        session.roomPresence(occupant(1), room: room)
        session.roomPresence(occupant(1, type: "unavailable"), room: room)

        session.applyOccupantChanges()

        #expect(session.roomStatus(room)?.occupants.isEmpty == true)
    }

    @Test func clearingTheRoomsDropsWhatWasWaitingAndSaysTheyAreGone() {
        session.roomPresence(occupant(1), room: room)

        session.clearRooms()
        session.applyOccupantChanges()

        #expect(session.roomStatus(room) == nil)
        #expect(updates.last?.status == nil)
        #expect(updates.last?.room == room)
    }

    @Test func theWindowEndsByItselfAndAppliesTheOccupants() async throws {
        session.occupantWindow = 0.02
        session.roomPresence(occupant(1), room: room)
        session.roomPresence(occupant(2), room: room)

        await eventually("the window to end") { updates.count > 0 }

        #expect(updates.count == 1)
        #expect(updates.last?.status?.occupants.count == 2)
    }
}
