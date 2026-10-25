import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// What the user does right after coming back to the app waits a few seconds
/// for the connection, rather than failing as offline while it comes up.
struct ConnectionGraceTests {
    let session: XMPPSession
    let wire = FakeWire()
    let room = JID("room@muc.example.org")!

    init() throws {
        session = try makeSession(JID("me@example.org")!)
    }

    private func answerCommandList() {
        wire.answer { iq in
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
            query.setAttribute("node", value: NS.commands)
            query.addChild(Element(name: "item", attributes: ["jid": "example.org", "node": "ping", "name": "Ping"]))
            return FakeWire.result(to: iq, query)
        }
    }

    private func wantConnection() {
        session.lock.withLock { $0.wantsConnection = true }
    }

    private func setGrace(_ seconds: TimeInterval) {
        session.lock.withLock { $0.connectionGrace = seconds }
    }

    private var requests: [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items") != nil || $0.firstChild(name: "query", xmlns: NS.mucAdmin) != nil }
    }

    @Test func aRequestWaitsForTheConnectionAndThenGoesOut() async throws {
        wantConnection()
        answerCommandList()
        let result = Task { try await session.adHocCommands(at: "example.org") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.isEmpty)
        session.connectForTesting(wire)
        let commands = try await result.value
        #expect(commands.map(\.node) == ["ping"])
        #expect(requests.count == 1)
    }

    @Test func aRefusedAccountFailsAtOnce() async throws {
        wantConnection()
        session.state.send(.failed("Wrong password."))
        setGrace(30)
        let start = Date()
        await #expect(throws: AdHocError.offline) { try await session.adHocCommands(at: "example.org") }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func aConnectionThatNeverComesFailsAsOfflineAfterTheGrace() async throws {
        wantConnection()
        setGrace(0.2)
        let start = Date()
        await #expect(throws: AdHocError.offline) { try await session.adHocCommands(at: "example.org") }
        #expect(Date().timeIntervalSince(start) >= 0.2)
        #expect(requests.isEmpty)
    }

    @Test func aSessionThatIsntWantedFailsAtOnce() async throws {
        setGrace(30)
        let start = Date()
        await #expect(throws: AdHocError.offline) { try await session.adHocCommands(at: "example.org") }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func aPendingLivenessCheckHoldsTheRequestUntilItIsAnswered() async throws {
        session.connectForTesting(wire)
        answerCommandList()
        wire.holdsPings = true
        session.verifyConnection(timeout: 30)
        #expect(session.livenessPending.value)
        let result = Task { try await session.adHocCommands(at: "example.org") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(requests.isEmpty)
        wire.releasePings()
        let commands = try await result.value
        #expect(commands.count == 1)
        #expect(!session.livenessPending.value)
    }

    @Test func aSilentStreamKeepsTheRequestWaitingForTheNextConnection() async throws {
        session.connectForTesting(wire)
        answerCommandList()
        wire.holdsPings = true
        session.verifyConnection(timeout: 0.2)
        let result = Task { try await session.adHocCommands(at: "example.org") }
        // Past the ping's timeout the stream is dropped, but it can still read
        // as connected for a moment: that is not an answer.
        try await Task.sleep(for: .milliseconds(700))
        #expect(requests.isEmpty)
        #expect(session.livenessPending.value)
        // What a new connection does, then it comes up.
        session.livenessPending.send(false)
        session.connectForTesting(wire)
        let commands = try await result.value
        #expect(commands.count == 1)
        #expect(requests.count == 1)
    }

    @Test func aRoomActionWaitsForTheRoomToBeJoined() async throws {
        session.connectForTesting(wire)
        _ = try session.database.joinGroupChat(room, nickname: "me")
        var joining = RoomStatus(phase: .joining, nickname: "me")
        joining.affiliation = .owner
        session.updateRoom(room) { $0 = joining }
        wire.answer { iq in
            FakeWire.result(to: iq, Element(name: "query", xmlns: NS.mucAdmin))
        }
        let result = Task { try await session.refreshBanList(of: room) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.isEmpty)
        session.updateRoom(room) { $0?.phase = .joined }
        try await result.value
        #expect(requests.count == 1)
    }

    @Test func aRoomWeLeftOrThatFailedFailsAtOnce() async throws {
        session.connectForTesting(wire)
        _ = try session.database.joinGroupChat(room, nickname: "me")
        try session.database.updateGroupChat(room) { $0.hasLeft = true }
        setGrace(30)
        let start = Date()
        await #expect(throws: GroupError.self) { try await session.refreshBanList(of: room) }

        let other = JID("other@muc.example.org")!
        _ = try session.database.joinGroupChat(other, nickname: "me")
        session.updateRoom(other) { $0 = RoomStatus(phase: .failed("Banned."), nickname: "me") }
        await #expect(throws: GroupError.self) { try await session.refreshBanList(of: other) }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
