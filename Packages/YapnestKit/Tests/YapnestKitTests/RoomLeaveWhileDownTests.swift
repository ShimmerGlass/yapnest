import Foundation
@preconcurrency @testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

struct RoomLeaveWhileDownTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        let database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database, mode: .app)
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        session.connectForTesting(wire)
        session.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: "me") }
    }

    private func unavailablePresences() -> [Martin.Presence] {
        wire.written.compactMap { $0 as? Martin.Presence }.filter { $0.type == .unavailable }
    }

    @Test func aRoomLeftWhileTheStreamWasDownIsToldWhenItResumes() async throws {
        session.client.update(state: .disconnected())
        session.leaveRoom(room)
        #expect(unavailablePresences().isEmpty)

        session.client.update(state: .connected(resumed: true))

        await eventually("the room to be told") { !unavailablePresences().isEmpty }
        #expect(unavailablePresences().map { $0.to?.description } == ["cake@rooms.example.org/me"])
    }

    @Test func aRoomIsToldOnlyOnce() async throws {
        session.client.update(state: .disconnected())
        session.leaveRoom(room)
        session.client.update(state: .connected(resumed: true))
        await eventually("the room to be told") { !unavailablePresences().isEmpty }

        session.client.update(state: .disconnected())
        session.client.update(state: .connected(resumed: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(unavailablePresences().count == 1)
    }

    @Test func aRoomLeftWhileTheStreamWasDownIsNotToldByANewSession() async throws {
        session.client.update(state: .disconnected())
        session.leaveRoom(room)

        session.client.update(state: .connected(resumed: false))
        try await Task.sleep(for: .milliseconds(200))
        #expect(unavailablePresences().isEmpty)

        session.client.update(state: .disconnected())
        session.client.update(state: .connected(resumed: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(unavailablePresences().isEmpty)
    }

    @Test func aRoomWeWereNotInIsNotToldAnything() async throws {
        session.updateRoom(room) { $0 = nil }
        session.client.update(state: .disconnected())
        session.leaveRoom(room)
        session.client.update(state: .connected(resumed: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(unavailablePresences().isEmpty)
    }
}
