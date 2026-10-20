import Foundation
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!
private let bob = JID("bob@example.org")!
private let room = JID("cake@rooms.example.org")!

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// The one rule for when an operation on a chat may go out, and what
/// happens to those that arrive too early.
struct RouteTests {
    private func status(_ phase: RoomStatus.Phase, syncing: Bool) -> RoomStatus {
        var status = RoomStatus(phase: phase, nickname: "me")
        status.isSyncing = syncing
        return status
    }

    @Test func aRoomIsReadyOnlyOnceJoinedAndCaughtUp() {
        #expect(Route.direct(alice).isReady)
        #expect(Route.room(room, status: nil).readiness == .notJoined)
        #expect(Route.room(room, status: status(.joining, syncing: false)).readiness == .notJoined)
        #expect(Route.room(room, status: status(.failed("no"), syncing: false)).readiness == .notJoined)
        #expect(Route.room(room, status: status(.joined, syncing: true)).readiness == .syncing)
        #expect(Route.room(room, status: status(.joined, syncing: false)).isReady)
    }

    @Test func messagesAreNamedByTheIdTheirChatUses() {
        let message = Message(conversationId: 1, direction: .outgoing, sender: me, body: "x", timestamp: Date(), remoteId: "r", originId: "o", serverId: "s")
        #expect(Route.direct(alice).reference(to: message) == "r")
        #expect(Route.room(room, status: nil).reference(to: message) == "s")
        let unconfirmed = Message(conversationId: 1, direction: .outgoing, sender: me, body: "x", timestamp: Date(), originId: "o")
        #expect(Route.direct(alice).reference(to: unconfirmed) == "o")
        #expect(Route.room(room, status: nil).reference(to: unconfirmed) == nil)
    }

    @Test func recipientsAreTheContactOrTheRoomsMembersWithoutUs() {
        var joined = status(.joined, syncing: false)
        for jid in [me, alice, bob] { joined.setAffiliation(.member, of: jid) }
        #expect(Route.direct(alice).recipients(excluding: me) == [alice])
        #expect(Route.room(room, status: joined).recipients(excluding: me) == [alice, bob])
        #expect(Route.room(room, status: nil).recipients(excluding: me).isEmpty)
    }

    @Test func routesComeFromWhatTheSessionKnows() throws {
        let session = try makeSession(me)
        #expect(!session.route(to: alice).isGroup)
        session.lock.withLock { $0.knownRooms = [room] }
        #expect(session.route(to: room).isGroup)
        #expect(session.route(to: room).readiness == .notJoined)
    }

    @Test func operationsOnARoomWaitForItsCatchUpAndThenGoOutInOrder() throws {
        let session = try makeSession(me)
        let sent = Box<[String]>([])
        func send(_ what: String) -> @Sendable () -> Void { { sent.withLock { $0.append(what) } } }

        // A direct chat never waits.
        session.whenReady(.direct(alice), send("direct"))
        #expect(sent.withLock { $0 } == ["direct"])

        session.lock.withLock { $0.knownRooms = [room] }
        // Not joined yet, then joined but still syncing: both wait.
        session.whenReady(session.route(to: room), send("edit"))
        session.updateRoom(room) { $0 = status(.joined, syncing: true) }
        session.whenReady(.room(room, status: session.roomStatus(room)), send("retraction"))
        session.whenReady(.room(room, status: session.roomStatus(room)), send("reaction"))
        #expect(sent.withLock { $0 } == ["direct"])

        // Ready when the sync ends; what waited goes out once, in order.
        session.updateRoom(room) { $0?.isSyncing = false }
        session.sendDeferred(in: room)
        session.sendDeferred(in: room)
        #expect(sent.withLock { $0 } == ["direct", "edit", "retraction", "reaction"])

        // Now ready: goes straight out.
        session.whenReady(.room(room, status: session.roomStatus(room)), send("later"))
        #expect(sent.withLock { $0.last } == "later")
    }

    @Test func whatWaitedForARoomWeLeftIsDropped() throws {
        let session = try makeSession(me)
        let sent = Box(0)
        session.whenReady(.room(room, status: nil)) { sent.withLock { $0 += 1 } }
        session.dropDeferred(in: room)
        session.sendDeferred(in: room)
        #expect(sent.withLock { $0 } == 0)
    }
}
