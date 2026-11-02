import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// Message times are stored in this device's clock, converting the stamps a
/// server puts on them (the archive's, a delay's), so that they compare with
/// everything else we store (see `AppDatabase.serverClockOffset`).
struct ServerClockIngestTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let alice = YapnestKit.JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(YapnestKit.JID("me@example.org")!, database: db)
        session.connectForTesting(wire)
    }

    private func incoming(_ id: String, delayedTo stamp: String? = nil) -> Martin.Message {
        let delay = stamp.map { "<delay xmlns='urn:xmpp:delay' from='example.org' stamp='\($0)'/>" } ?? ""
        return parseStanza("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='\(id)'><body>hi</body>\(delay)</message>")
    }

    private func timestamps() throws -> [String: TimeInterval] {
        let rows = try db.reader.read { try YapnestKit.Message.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.remoteId.map { ($0, row.timestamp.timeIntervalSince1970) } })
    }

    private func isArchived() throws -> Bool {
        try db.reader.read { db in try Conversation.fetchOne(db)?.isArchived } ?? false
    }

    /// A device whose clock is two minutes slow archived a chat at server time
    /// 1000, and a message sent at 995 comes in by catch-up afterwards.
    @Test func aMessageSentBeforeTheArchivingStaysBehindItOnASlowClock() throws {
        try db.noteServerClockOffset(120)
        session.handle(incoming("m1"), source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 995)))
        session.flushArchive()
        let conversation = try #require(try db.reader.read { try Conversation.fetchOne($0) })
        try db.writer.write { db in
            _ = try AppDatabase.applyRemote(db, item: "chat:alice@example.org", entries: [
                SettingsEntry(key: "archivedAt", value: "1000000", version: SettingsVersion(ms: 1000, counter: 0), by: "other"),
            ])
        }
        // The stamp 995 is 875 on this clock, before the archiving's 880.
        #expect(try timestamps()["m1"] == 875)
        #expect(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) }?.isArchived == true)
    }

    @Test func aMessageSentAfterTheArchivingUnarchivesItOnASlowClock() throws {
        try db.noteServerClockOffset(120)
        session.handle(incoming("m1"), source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 1005)))
        session.flushArchive()
        try db.writer.write { db in
            _ = try AppDatabase.applyRemote(db, item: "chat:alice@example.org", entries: [
                SettingsEntry(key: "archivedAt", value: "1000000", version: SettingsVersion(ms: 1000, counter: 0), by: "other"),
            ])
        }
        #expect(try timestamps()["m1"] == 885)
        #expect(try isArchived() == false)
    }

    @Test func anArchiveStampIsStoredLessTheOffset() throws {
        try db.noteServerClockOffset(-90)
        session.handle(incoming("m1"), source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 1000)))
        session.flushArchive()
        #expect(try timestamps()["m1"] == 1090)
    }

    @Test func aTrustedDelayStampIsStoredLessTheOffset() throws {
        try db.noteServerClockOffset(120)
        session.handle(incoming("m1", delayedTo: "2001-09-09T01:46:40Z"), source: .live)
        #expect(try timestamps()["m1"] == 1_000_000_000 - 120)
    }

    @Test func aDelayedMessageIsStillNeverInTheFuture() throws {
        try db.noteServerClockOffset(-3600)
        let stamp = ISO8601DateFormatter().string(from: Date())
        session.handle(incoming("m1", delayedTo: stamp), source: .live)
        #expect(try #require(try timestamps()["m1"]) <= Date().timeIntervalSince1970)
    }

    @Test func withNoOffsetKnownStampsAreStoredAsTheyAre() throws {
        session.handle(incoming("m1"), source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 1000)))
        session.handle(incoming("m2", delayedTo: "2001-09-09T01:46:40Z"), source: .live)
        session.flushArchive()
        #expect(try timestamps()["m1"] == 1000)
        #expect(try timestamps()["m2"] == 1_000_000_000)
    }

    @Test func aStoredTimeGoesToTheServerInItsClock() throws {
        try db.noteServerClockOffset(120)
        #expect(session.serverTime(of: Date(timeIntervalSince1970: 880)) == Date(timeIntervalSince1970: 1000))
    }
}
