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

    @Test func archiveStampsStandInUntilTheServerAnswers() throws {
        let arrival = Date(timeIntervalSince1970: 5000)
        session.noteArchiveStamp(arrival.addingTimeInterval(118), arrivedAt: arrival)
        #expect(try db.setting(.serverClockOffset) == "118000")
        // A message that waited, such as one from the catch-up, says less.
        session.noteArchiveStamp(arrival.addingTimeInterval(-60), arrivedAt: arrival)
        #expect(try db.setting(.serverClockOffset) == "118000")
        session.noteArchiveStamp(arrival.addingTimeInterval(-3600), arrivedAt: arrival)
        #expect(try db.setting(.serverClockOffset) == "118000")
        session.noteArchiveStamp(arrival.addingTimeInterval(120), arrivedAt: arrival)
        #expect(try db.setting(.serverClockOffset) == "120000")

        session.noteClockOffset(121.5)
        session.noteArchiveStamp(arrival.addingTimeInterval(500), arrivedAt: arrival)
        #expect(try db.setting(.serverClockOffset) == "121500")
        #expect(session.lock.withLock { $0.clock } == .entityTime)
    }

    @Test func aStampThatMovesTheEstimateByLessThanASecondIsNotRecorded() {
        let arrival = Date(timeIntervalSince1970: 5000)
        session.noteArchiveStamp(arrival.addingTimeInterval(118), arrivedAt: arrival)
        session.noteArchiveStamp(arrival.addingTimeInterval(118.5), arrivedAt: arrival)
        #expect(session.lock.withLock { $0.clock } == .archive(best: 118.5))
        #expect(session.lock.withLock { $0.recordedClockOffset } == 118)
        session.noteArchiveStamp(arrival.addingTimeInterval(119.5), arrivedAt: arrival)
        #expect(session.lock.withLock { $0.recordedClockOffset } == 119.5)
    }
}
