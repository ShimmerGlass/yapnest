import Foundation
import Observation
import Testing
import YapnestKit
@testable import Yapnest

/// A view that reads one contact's or room's box is redrawn by changes to it
/// and to nobody else's.
@MainActor
struct LiveStatesTests {
    private let anna = JID("anna@example.com")!
    private let ben = JID("ben@example.com")!
    private let cake = JID("cake@rooms.example.com")!
    private let book = JID("book@rooms.example.com")!

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// Whether `change` invalidates a view that reads `read`.
    private func invalidates(reading read: () -> Void, by change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.raise() }
        change()
        return flag.isRaised
    }

    private func room(_ phase: RoomStatus.Phase = .joined, occupants: Int = 0) -> RoomStatus {
        var status = RoomStatus(phase: phase, nickname: "me")
        for index in 0..<occupants {
            status.occupants["u\(index)"] = RoomOccupant(nick: "u\(index)", jid: nil, affiliation: .none, role: "participant", occupantId: nil)
        }
        return status
    }

    @Test func oneContactTypingLeavesTheOthersViewsAlone() {
        let live = LiveStates()
        let annaBox = live.peer(anna)
        _ = live.peer(ben)

        #expect(!invalidates(reading: { _ = annaBox.isTyping }, by: { live.setTyping(ben, true) }))
        #expect(invalidates(reading: { _ = annaBox.isTyping }, by: { live.setTyping(anna, true) }))
        #expect(annaBox.isTyping)
        #expect(live.peer(ben).isTyping)
    }

    @Test func aPresenceTableOnlyChangesTheBoxesItChanges() {
        let live = LiveStates()
        live.apply(presences: [anna: .online, ben: .online])
        let annaBox = live.peer(anna)

        #expect(!invalidates(reading: { _ = annaBox.presence }, by: { live.apply(presences: [anna: .online, ben: .away]) }))
        #expect(invalidates(reading: { _ = annaBox.presence }, by: { live.apply(presences: [anna: .offline, ben: .away]) }))
        #expect(live.peer(ben).presence == .away)
        #expect(invalidates(reading: { _ = annaBox.presence }, by: { live.apply(presences: [ben: .away]) }))
        #expect(annaBox.presence == nil)
    }

    @Test func aStatusIsKeptApartFromAvailability() {
        let live = LiveStates()
        live.apply(presences: [anna: .online])
        let annaBox = live.peer(anna)

        #expect(!invalidates(reading: { _ = annaBox.presence }, by: { live.apply(statuses: [anna: "out for lunch"]) }))
        #expect(annaBox.status == "out for lunch")
        #expect(!invalidates(reading: { _ = annaBox.status }, by: { live.apply(presences: [anna: .away]) }))
    }

    @Test func oneRoomChangingLeavesTheOthersViewsAlone() {
        let live = LiveStates()
        live.apply(room: cake, status: room())
        live.apply(room: book, status: room())
        let cakeBox = live.room(cake)

        #expect(!invalidates(reading: { _ = cakeBox.status }, by: { live.apply(room: book, status: room(occupants: 3)) }))
        #expect(invalidates(reading: { _ = cakeBox.status }, by: { live.apply(room: cake, status: room(occupants: 3)) }))
        #expect(cakeBox.memberCount == 3)
    }

    @Test func aRoomsHeaderIgnoresOccupantsThatDontChangeItsCountOrPhase() {
        let live = LiveStates()
        live.apply(room: cake, status: room(occupants: 3))
        let box = live.room(cake)
        var moved = room(occupants: 3)
        moved.occupants["u0"]?.role = "moderator"

        #expect(!invalidates(reading: { _ = box.phase; _ = box.memberCount }, by: { live.apply(room: cake, status: moved) }))
        #expect(invalidates(reading: { _ = box.memberCount }, by: { live.apply(room: cake, status: room(occupants: 4)) }))
        #expect(invalidates(reading: { _ = box.phase }, by: { live.apply(room: cake, status: room(.failed("gone"), occupants: 4)) }))
        #expect(box.phase == .failed("gone"))
    }

    @Test func aRoomThatIsGoneEmptiesItsBox() {
        let live = LiveStates()
        live.apply(room: cake, status: room(occupants: 2))
        let box = live.room(cake)

        live.apply(room: cake, status: nil)

        #expect(box.status == nil)
        #expect(box.phase == nil)
        #expect(box.memberCount == 0)
    }

    @Test func resettingEmptiesTheBoxesViewsHold() {
        let live = LiveStates()
        live.apply(presences: [anna: .online])
        live.apply(statuses: [anna: "busy"])
        live.apply(room: cake, status: room())
        live.setTyping(anna, true)
        let annaBox = live.peer(anna), cakeBox = live.room(cake)

        live.reset()

        #expect(annaBox.presence == nil && annaBox.status == nil && !annaBox.isTyping)
        #expect(cakeBox.status == nil)
        #expect(live.peer(anna) === annaBox)
    }

    @Test func aSessionsTypingAndPresenceReachOnlyTheirOwnBoxes() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        let session = try #require(fixture.model.session)
        let live = fixture.model.live
        let annaBox = live.peer(anna), benBox = live.peer(ben)
        let flag = Flag()
        withObservationTracking({ _ = annaBox.isTyping; _ = annaBox.presence }) { flag.raise() }

        session.events.send(.chatState(ben, .composing))
        session.presences.send([ben: .away])
        await eventually("ben's state arrives") { benBox.isTyping && benBox.presence == .away }

        #expect(!flag.isRaised)
    }

    @Test func aBurstOfRoomUpdatesEndsAtTheLastOne() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        let session = try #require(fixture.model.session)
        let box = fixture.model.live.room(cake)
        let flag = Flag()
        withObservationTracking({ _ = box.status }) { flag.raise() }

        for count in 1...50 { session.roomUpdates.send(RoomUpdate(room: cake, status: room(occupants: count))) }
        await eventually("the last update arrives") { box.memberCount == 50 }

        #expect(flag.isRaised)
        #expect(box.status?.occupants.count == 50)
    }
}
