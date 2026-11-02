import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

/// How a session estimates the server's clock for the times it syncs.
struct ServerClockTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(JID("me@example.org")!, database: db)
    }

    private func timeAnswer(_ utc: String) -> @Sendable (Iq) -> Iq? {
        { iq in
            guard iq.firstChild(name: "time", xmlns: "urn:xmpp:time") != nil else { return FakeWire.result(to: iq) }
            let time = Element(name: "time", xmlns: "urn:xmpp:time")
            time.addChild(Element(name: "tzo", cdata: "Z"))
            time.addChild(Element(name: "utc", cdata: utc))
            return FakeWire.result(to: iq, time)
        }
    }

    @Test func theServersTimeLessTheRoundTripsMidpointIsTheOffset() {
        let sent = Date(timeIntervalSince1970: 1000)
        let received = sent.addingTimeInterval(2)
        #expect(XMPPSession.offset(server: Date(timeIntervalSince1970: 1121), sent: sent, received: received) == 120)
        #expect(XMPPSession.offset(server: Date(timeIntervalSince1970: 881), sent: sent, received: received) == -120)
    }

    @Test func theServersAnswerSetsTheOffset() async throws {
        session.connectForTesting(wire)
        let ahead = Date().addingTimeInterval(300)
        wire.answer(timeAnswer(ISO8601DateFormatter().string(from: ahead)))

        session.estimateServerClock()
        await session.lock.withLock { $0.clockEstimate }?.value

        let stored = try #require(try db.setting(.serverClockOffset).flatMap(Double.init))
        #expect(abs(stored / 1000 - 300) < 3)
        let asked = wire.written.compactMap { $0 as? Iq }.first { $0.firstChild(name: "time", xmlns: "urn:xmpp:time") != nil }
        #expect(asked?.to?.description == "example.org")
    }

    @Test func aServerThatRefusesLeavesNoOffset() async throws {
        session.connectForTesting(wire)
        wire.answer { FakeWire.error(to: $0, condition: "service-unavailable") }

        session.estimateServerClock()
        await session.lock.withLock { $0.clockEstimate }?.value

        #expect(try db.setting(.serverClockOffset) == nil)
    }

    @Test func theRecordedOffsetIsKeptForLaterStanzas() throws {
        #expect(session.serverClockOffset == 0)
        session.noteClockOffset(120)
        // Read from the cache: the database no longer matters.
        try db.writer.write { try AppDatabase.setSetting($0, .serverClockOffset, "5000") }
        #expect(session.serverClockOffset == 120)
        #expect(session.serverTime(of: Date(timeIntervalSince1970: 880)) == Date(timeIntervalSince1970: 1000))
    }

    @Test func theStoredOffsetIsLoadedOnFirstUse() throws {
        try db.noteServerClockOffset(-90)
        #expect(session.serverClockOffset == -90)
    }

    @Test func archiveStampsDoNotMoveTheOffset() throws {
        let arrival = Date()
        session.handle(parseStanza("<message from='alice@example.org/p' to='me@example.org' type='chat' id='m1'><body>hi</body></message>"),
                       source: .archive(serverId: "s1", timestamp: arrival.addingTimeInterval(300)))
        session.flushArchive()
        #expect(try db.setting(.serverClockOffset) == nil)
        #expect(session.serverClockOffset == 0)
    }
}
