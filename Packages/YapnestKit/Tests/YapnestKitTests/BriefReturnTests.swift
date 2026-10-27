import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let room = JID("cake@rooms.example.org")!
private let failedRoom = JID("lost@rooms.example.org")!

/// Coming back to the app after a banner or a Cmd-Tab shouldn't ask every
/// room whether we're still in it, or start the failed rooms' rejoins over.
struct BriefReturnTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
        session.updateRoom(failedRoom) {
            var failed = RoomStatus(phase: .failed("x"), nickname: "me")
            failed.canRetry = true
            $0 = failed
        }
        session.lock.withLock { $0.rejoinAttempts[failedRoom] = 4 }
    }

    private func roomPings() -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.to?.bareJid.description == room.description && $0.firstChild(name: "ping", xmlns: "urn:xmpp:ping") != nil }
    }

    private func comeBack(after away: TimeInterval) {
        session.lock.withLock { $0.isActive = false; $0.idleSince = Date().addingTimeInterval(-away) }
        session.setActive(true)
    }

    @Test func aBriefAbsenceDoesNotPingTheRoomsOrRestartTheBackoff() async throws {
        comeBack(after: 5)
        try await Task.sleep(for: .milliseconds(300))
        #expect(roomPings().isEmpty)
        #expect(session.lock.withLock { $0.rejoinAttempts[failedRoom] } == 4)
    }

    @Test func aRealAbsencePingsTheRooms() async throws {
        comeBack(after: XMPPSession.roomRecheckAbsence + 1)
        #expect(await eventually { roomPings().count == 1 })
    }

    @Test func theThresholdIsAboutHowLongTheAppWasAway() {
        #expect(!XMPPSession.recheckRooms(afterAbsence: nil))
        #expect(!XMPPSession.recheckRooms(afterAbsence: 3))
        #expect(XMPPSession.recheckRooms(afterAbsence: XMPPSession.roomRecheckAbsence))
    }
}
