import Foundation
import Testing
@testable import YapnestKit

/// Snapshots must reach their subject in the order they were built, or a
/// stale one can end up as its last value.
struct PublishOrderTests {
    private let room = JID("cake@rooms.example.org")!

    @Test func concurrentRoomUpdatesLeaveTheNewestSnapshot() throws {
        let session = try makeSession(JID("me@example.org")!)
        let count = 4000
        for _ in 0..<5 {
            session.clearRooms()
            // Mixed priorities make the scheduler preempt threads mid-update.
            let group = DispatchGroup()
            let jids = (0..<count).map { JID("u\($0)@example.org")! }
            for (offset, qos) in [DispatchQoS.QoSClass.userInteractive, .utility, .userInitiated, .background].enumerated() {
                DispatchQueue.global(qos: qos).async(group: group) {
                    for index in stride(from: offset, to: count, by: 4) {
                        session.updateRoom(room) { status in
                            var next = status ?? RoomStatus(phase: .joining, nickname: "me")
                            next.setAffiliation(.member, of: jids[index])
                            status = next
                        }
                    }
                }
            }
            group.wait()
            #expect(session.roomStatus(room)?.members.count == count)
            #expect(session.rooms.value[room]?.members.count == count)
        }
    }

    @Test func concurrentProgressLeavesTheNewestSnapshot() throws {
        let session = try makeSession(JID("me@example.org")!)
        for _ in 0..<5 {
            #expect(session.beginTransfer(1))
            let steps = 2000
            // Whichever update ran last decides the state; the subject must agree.
            DispatchQueue.concurrentPerform(iterations: steps) { index in
                session.setProgress(Double(index) / Double(steps), for: 1)
            }
            let expected = session.lock.withLock { $0.transferProgress }
            #expect(session.transfers.value == expected)
            session.lock.withLock { $0.transferProgress = [:] }
            session.transfers.send([:])
        }
    }
}
