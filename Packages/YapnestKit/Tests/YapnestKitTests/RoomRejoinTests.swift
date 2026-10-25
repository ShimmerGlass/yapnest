import Foundation
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

struct RoomRejoinTests {
    @Test func transientJoinErrorsAreRetried() {
        for condition in ["remote-server-timeout", "remote-server-not-found", "internal-server-error", "resource-constraint", nil] {
            #expect(XMPPSession.isRetryable(joinCondition: condition), "\(condition ?? "none")")
        }
    }

    @Test func refusalsAreNotRetried() {
        for condition in ["registration-required", "forbidden", "not-authorized", "conflict", "item-not-found", "not-allowed", "service-unavailable", "bad-request"] {
            #expect(!XMPPSession.isRetryable(joinCondition: condition), "\(condition)")
        }
    }

    @Test func onlyARestartIsRetriedAfterRemoval() {
        #expect(XMPPSession.isRetryable(removalStatuses: [110, 332]))
        #expect(!XMPPSession.isRetryable(removalStatuses: [110, 307]))
        #expect(!XMPPSession.isRetryable(removalStatuses: [110, 301]))
        #expect(!XMPPSession.isRetryable(removalStatuses: [110]))
    }

    @Test func backoffGrowsThenSettles() {
        let delays = (0..<6).map { XMPPSession.rejoinDelay(attempt: $0, jitter: 0) }
        #expect(delays == [5, 15, 60, 300, 300, 300])
    }

    @Test func backoffIsJitteredSoRoomsDontRetryInLockstep() {
        let delays = (0..<50).map { _ in XMPPSession.rejoinDelay(attempt: 1) }
        #expect(delays.allSatisfy { (15...18.75).contains($0) })
        #expect(Set(delays).count > 1)
    }

    @Test func leavingCancelsAScheduledRejoin() throws {
        let session = try makeSession(me)
        try session.database.joinGroupChat(room, nickname: "me")
        session.scheduleRejoin(room)
        #expect(session.hasScheduledRejoin(room))
        session.leaveRoom(room)
        #expect(!session.hasScheduledRejoin(room))
    }

    @Test func leavingOfflineThrowsAndChangesNothing() async throws {
        let session = try makeSession(me)
        try session.database.joinGroupChat(room, nickname: "me")
        await #expect(throws: GroupError.self) { try await session.leaveGroup(room) }
        #expect(try session.database.groupChat(room)?.hasLeft == false)
    }

    @Test func disconnectingCancelsEveryScheduledRejoin() throws {
        let session = try makeSession(me)
        session.scheduleRejoin(room)
        session.cancelAllRejoins()
        #expect(!session.hasScheduledRejoin(room))
    }

    @Test func joiningStartsTheBackoffOver() throws {
        let session = try makeSession(me)
        session.scheduleRejoin(room)
        session.scheduleRejoin(room)
        #expect(session.lock.withLock { $0.rejoinAttempts[room] } == 2)
        session.cancelRejoin(room, resettingBackoff: true)
        #expect(session.lock.withLock { $0.rejoinAttempts[room] } == nil)
    }
}
