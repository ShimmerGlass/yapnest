import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!
private let bob = JID("bob@example.org")!
private let long_ago = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))

extension YapnestKit.Message {
    /// Whether this is the event that marks the end of an answered call.
    var endsACall: Bool {
        if case .callEnded = event { true } else { false }
    }
}

struct CallLogTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
        try db.writer.write { try Contact(jid: alice, subscription: .both, isInRoster: true).insert($0) }
    }

    private func signal(_ action: CallSignal.Action, sid: String = "s1", fromAccount: Bool = false, peer: JID = alice, at offset: TimeInterval = 0) -> CallSignal {
        CallSignal(
            sid: sid, action: action, sender: fromAccount ? me : peer, recipient: fromAccount ? peer : me,
            from: fromAccount ? "me@example.org/tablet" : "\(peer)/phone", isFromAccount: fromAccount, timestamp: long_ago + offset,
        )
    }

    private func apply(_ signals: CallSignal..., isHistory: Bool = false) throws {
        for signal in signals { try db.applyCallSignal(signal, account: me, isHistory: isHistory) }
    }

    private func rows() throws -> [Message] {
        try db.reader.read { try Message.filter(sql: "callOutcome IS NOT NULL OR json_type(event, '$.callEnded') IS NOT NULL").order(Column("id")).fetchAll($0) }
    }

    private let propose = CallSignal.Action.propose(media: [.audio])

    // MARK: Live

    @Test func aFinishedCallIsOneRowWithNoBody() throws {
        let record = CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .answered, startedAt: long_ago, answeredAt: long_ago + 5, duration: 42)
        let inserted = try db.recordCall(record)
        let row = try #require(try rows().first)
        #expect(inserted?.id == row.id)
        #expect(row.body == "")
        #expect(row.remoteId == "s1")
        #expect(row.callOutcome == .answered)
        #expect(row.callDuration == 42)
        #expect(row.callAnsweredAt == long_ago + 5)
        #expect(row.direction == .incoming)
        #expect(row.sender == alice)
        #expect(row.isRead)
        #expect(row.status == .received)
        #expect(row.call == CallSummary(outcome: .answered, direction: .incoming, duration: 42))
    }

    @Test func aVideoCallsRowSaysSo() throws {
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "v", direction: .outgoing, outcome: .answered, startedAt: long_ago, duration: 10, isVideo: true))
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "a", direction: .outgoing, outcome: .answered, startedAt: long_ago + 100, duration: 10))
        let logged = try rows()
        #expect(logged.map(\.callIsVideo) == [true, false])
        #expect(logged.first?.call == CallSummary(outcome: .answered, direction: .outgoing, duration: 10, isVideo: true))
    }

    @Test func aVideoProposeInTheArchiveMakesTheRowVideo() throws {
        try apply(signal(.propose(media: [.audio, .video]), sid: "v"), signal(.propose(media: [.audio]), sid: "a", at: 100))
        #expect(try rows().map(\.callIsVideo) == [true, false])
    }

    @Test func aMissedCallIsUnreadAndOtherEndingsAreRead() throws {
        for (sid, outcome) in [("a", CallOutcome.missed), ("b", .declined), ("c", .cancelled), ("d", .busy), ("e", .failed)] {
            try db.recordCall(CallRecord(peer: alice, account: me, sid: sid, direction: .incoming, outcome: outcome, startedAt: long_ago))
        }
        let unread = try rows().filter { !$0.isRead }.map(\.remoteId)
        #expect(unread == ["a"])
    }

    @Test func anOutgoingCallIsOursAndRead() throws {
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .outgoing, outcome: .cancelled, startedAt: long_ago))
        let row = try #require(try rows().first)
        #expect(row.direction == .outgoing)
        #expect(row.sender == me)
        #expect(row.isRead)
        #expect(row.status == .sent)
    }

    @Test func aCallOpensTheChatAndMovesItUp() throws {
        try db.recordCall(CallRecord(peer: bob, account: me, sid: "s1", direction: .outgoing, outcome: .busy, startedAt: long_ago))
        let chat = try #require(try db.reader.read { try Conversation.filter(Column("peer") == bob).fetchOne($0) })
        #expect(chat.lastActivityAt == long_ago)
    }

    @Test func writingTheSameCallAgainChangesNoneOfTheRows() throws {
        let record = CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .missed, startedAt: long_ago)
        #expect(try db.recordCall(record) != nil)
        #expect(try db.recordCall(record) == nil)
        #expect(try rows().count == 1)
    }

    @Test func theEndOfACallCompletesTheRowAnArchiveReplayMade() throws {
        try apply(signal(propose, at: 0), signal(.retract(nil), at: 2))
        #expect(try rows().first?.callOutcome == .missed)
        // The device saw it differently: it was answered, here.
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .answered, startedAt: long_ago, answeredAt: long_ago + 1, duration: 9))
        let row = try #require(try rows().first)
        #expect(try rows().count == 1)
        #expect(row.callOutcome == .answered)
        #expect(row.callDuration == 9)
        #expect(row.isRead)
    }

    // MARK: Replays

    @Test func aProposeAndARetractAreAMissedCall() throws {
        try apply(signal(propose), signal(.retract(.cancel), at: 8))
        let row = try #require(try rows().first)
        #expect(try rows().count == 1)
        #expect(row.callOutcome == .missed)
        #expect(row.direction == .incoming)
        #expect(!row.isRead)
        #expect(row.timestamp == long_ago)
    }

    @Test func ourProposeAndRetractAreACancelledCall() throws {
        try apply(signal(propose, fromAccount: true), signal(.retract(.cancel), fromAccount: true, at: 8))
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .cancelled)
        #expect(row.direction == .outgoing)
        #expect(row.isRead)
    }

    @Test func anOldProposeAloneIsMissed() throws {
        try apply(signal(propose))
        #expect(try rows().first?.callOutcome == .missed)
    }

    @Test func ourRejectMakesItDeclined() throws {
        try apply(signal(propose), signal(.reject(.decline), fromAccount: true, at: 3))
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .declined)
        #expect(row.isRead)
    }

    @Test func ourAnswerMakesItAnsweredAndFinishGivesTheLength() throws {
        try apply(
            signal(propose),
            signal(.proceed, fromAccount: true, at: 4),
            signal(.accept, fromAccount: true, at: 4),
            signal(.finish(.success), at: 94),
        )
        let row = try #require(try rows().first)
        #expect(try rows().map(\.endsACall) == [false, true])
        #expect(row.callOutcome == .answered)
        #expect(row.callAnsweredAt == long_ago + 4)
        #expect(row.callDuration == 90)
        #expect(row.isRead)
    }

    @Test func theirAnswerToOurCallMakesItAnswered() throws {
        try apply(
            signal(propose, fromAccount: true),
            signal(.proceed, at: 6),
            signal(.finish(.success), fromAccount: true, at: 66),
        )
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .answered)
        #expect(row.direction == .outgoing)
        #expect(row.callDuration == 60)
    }

    @Test func theirRejectIsDeclinedOrBusy() throws {
        try apply(signal(propose, sid: "a", fromAccount: true), signal(.reject(.busy), sid: "a", at: 1))
        try apply(signal(propose, sid: "b", fromAccount: true), signal(.reject(nil), sid: "b", at: 1))
        #expect(try rows().map(\.callOutcome) == [.busy, .declined])
    }

    @Test func aFinishWithAnErrorMakesItFailed() throws {
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 2), signal(.finish(.connectivityError), at: 4))
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .failed)
        #expect(row.callDuration == nil)
    }

    @Test func aFinishWithoutAnAnswerDoesNothing() throws {
        try apply(signal(propose), signal(.finish(.success), at: 5))
        #expect(try rows().first?.callOutcome == .missed)
        try apply(signal(.finish(.success), sid: "unknown"))
        #expect(try rows().count == 1)
    }

    @Test func replayingTheSequenceChangesNothing() throws {
        let sequence = [
            signal(propose), signal(.ringing, fromAccount: true, at: 1), signal(.proceed, fromAccount: true, at: 4),
            signal(.accept, fromAccount: true, at: 4), signal(.finish(.success), at: 94),
        ]
        try apply(sequence[0], sequence[1], sequence[2], sequence[3], sequence[4])
        let first = try rows()
        try apply(sequence[0], sequence[1], sequence[2], sequence[3], sequence[4])
        #expect(try rows() == first)
    }

    @Test func aLaterRetractNeverUndoesAnAnswer() throws {
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 2), signal(.retract(nil), at: 3))
        #expect(try rows().first?.callOutcome == .answered)
    }

    @Test func aReplayedVideoProposeMakesAnAnsweredRowVideoWithoutMissingIt() throws {
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 2))
        try apply(signal(.propose(media: [.audio, .video])), isHistory: true)
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .answered)
        #expect(row.callIsVideo)
        #expect(row.isRead)
    }

    @Test func anAnswerArrivingFirstStillMakesTheRow() throws {
        // A page boundary can drop the propose.
        try apply(signal(.proceed, fromAccount: true, at: 2))
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .answered)
        #expect(row.direction == .incoming)
        try apply(signal(.retract(nil), sid: "s2", at: 2))
        #expect(try rows().last?.callOutcome == .missed)
        #expect(try rows().last?.direction == .incoming)
    }

    @Test func anAcceptToOurselvesFindsTheCallByItsId() throws {
        let toSelf = CallSignal(sid: "s1", action: .accept, sender: me, recipient: me, from: "me@example.org/tablet", isFromAccount: true, timestamp: long_ago + 3)
        try apply(signal(propose))
        try apply(toSelf)
        #expect(try rows().first?.callOutcome == .answered)
        // With no call to find it does nothing.
        try apply(CallSignal(sid: "nope", action: .accept, sender: me, recipient: me, from: "me@example.org/tablet", isFromAccount: true, timestamp: long_ago))
        #expect(try rows().count == 1)
    }

    @Test func aStrangerCannotChangeAnotherChatsCall() throws {
        try db.writer.write { try Contact(jid: bob, subscription: .both, isInRoster: true).insert($0) }
        try apply(signal(propose, sid: "s1"))
        try apply(signal(.proceed, sid: "s1", peer: bob), signal(.reject(.busy), sid: "s1", peer: bob))
        let alices = try #require(try rows().first { $0.sender == alice })
        #expect(alices.callOutcome == .missed)
    }

    @Test func aFreshProposeWaitsForHowItEnds() throws {
        let now = Date()
        let fresh = CallSignal(sid: "s1", action: propose, sender: alice, recipient: me, from: "alice@example.org/phone", timestamp: now.addingTimeInterval(-5))
        try db.applyCallSignal(fresh, account: me, isHistory: false, now: now)
        #expect(try rows().isEmpty)
        // Its end then makes the row.
        try db.applyCallSignal(CallSignal(sid: "s1", action: .retract(nil), sender: alice, recipient: me, from: "alice@example.org/phone", timestamp: now), account: me, isHistory: false, now: now)
        #expect(try rows().first?.callOutcome == .missed)
    }

    @Test func historyIsReadAndLeavesTheChatWhereItIs() throws {
        let chat = try db.conversation(with: alice)
        let before = try #require(try db.reader.read { try Conversation.fetchOne($0, key: chat.id!) })
        try apply(signal(propose), signal(.retract(nil), at: 3), isHistory: true)
        let row = try #require(try rows().first)
        #expect(row.callOutcome == .missed)
        #expect(row.isRead)
        let after = try #require(try db.reader.read { try Conversation.fetchOne($0, key: chat.id!) })
        #expect(after.lastActivityAt == before.lastActivityAt)
    }

    @Test func strangersDoNotOpenChats() throws {
        let stranger = JID("mallory@example.org")!
        try apply(signal(propose, peer: stranger), signal(.retract(nil), peer: stranger, at: 2))
        #expect(try rows().isEmpty)
        #expect(try db.reader.read { try Conversation.filter(Column("peer") == stranger).fetchCount($0) } == 0)
    }

    @Test func aBlockedContactsCallOpensNoChat() throws {
        let blocked = JID("carol@example.org")!
        try db.writer.write { try Contact(jid: blocked, subscription: .both, isInRoster: true, isBlocked: true).insert($0) }
        try apply(signal(propose, peer: blocked), signal(.retract(nil), peer: blocked, at: 2))
        #expect(try rows().isEmpty)
        #expect(try db.reader.read { try Conversation.filter(Column("peer") == blocked).fetchCount($0) } == 0)
    }

    @Test func aChatWeHaveStaysOpenForItsCalls() throws {
        _ = try db.conversation(with: bob)
        try apply(signal(propose, peer: bob), signal(.retract(nil), peer: bob, at: 2))
        #expect(try rows().count == 1)
    }

    @Test func ringingSaysNothing() throws {
        try apply(signal(.ringing))
        #expect(try rows().isEmpty)
    }

    // MARK: The end of a call

    private func ends() throws -> [Message] { try rows().filter(\.endsACall) }

    private func answered(sid: String = "s1", duration: TimeInterval? = 90, endedAt: Date? = long_ago + 100) -> CallRecord {
        CallRecord(peer: alice, account: me, sid: sid, direction: .outgoing, outcome: .answered, startedAt: long_ago, answeredAt: long_ago + 10, duration: duration, endedAt: endedAt)
    }

    @Test func anAnsweredCallGetsAnEndRowWhenItEnds() throws {
        let inserted = try db.recordCall(answered())
        let logged = try rows()
        #expect(logged.map(\.endsACall) == [false, true])
        #expect(inserted?.id == logged.first?.id)
        let end = try #require(logged.last)
        #expect(end.timestamp == long_ago + 100)
        #expect(end.event == .callEnded(sid: "s1", duration: 90, isVideo: false))
        #expect(end.remoteId == nil && end.callOutcome == nil && end.callDuration == nil)
        #expect(end.direction == .event && end.sender == me)
        #expect(end.isRead)
        #expect(end.call == CallSummary(outcome: .answered, direction: .event, duration: 90, isEnd: true))
        #expect(logged.first?.call?.isEnd == false)
    }

    @Test func theEndRowIsReadEvenForAnIncomingCallAndIsNeverClaimed() throws {
        _ = try db.conversation(with: alice)
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .answered, startedAt: Date(), answeredAt: Date(), duration: 4, endedAt: Date()))
        #expect(try ends().first?.isRead == true)
        #expect(try db.claimNotifications().isEmpty)
        #expect(try db.unreadCount() == 0)
    }

    @Test func aReplayedFinishMakesTheEndRowAtItsOwnTime() throws {
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 4), signal(.finish(.success), at: 94))
        let end = try #require(try ends().first)
        #expect(end.timestamp == long_ago + 94)
        #expect(end.event == .callEnded(sid: "s1", duration: 90, isVideo: false))
    }

    @Test func aReplayedFinishCompletesARowThatHasItsLengthButNoEnd() throws {
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 4))
        try db.writer.write { try $0.execute(sql: "UPDATE message SET callDuration = 90") }
        #expect(try ends().isEmpty)
        try apply(signal(.finish(.success), at: 94))
        #expect(try ends().map(\.timestamp) == [long_ago + 94])
    }

    @Test func applyingTheSamePageTwiceAddsNothing() throws {
        let page = [signal(propose), signal(.proceed, fromAccount: true, at: 4), signal(.finish(.success), at: 94)]
        try apply(page[0], page[1], page[2], isHistory: true)
        let first = try rows()
        try apply(page[0], page[1], page[2], isHistory: true)
        try apply(page[2], isHistory: true)
        #expect(try rows() == first)
        #expect(first.count == 2)
    }

    /// Archive pages come newest first, so the propose that says it was video
    /// can follow both rows.
    @Test func anOlderPageSayingItWasVideoReachesTheEndRow() throws {
        try apply(signal(.proceed, fromAccount: true, at: 4), signal(.finish(.success), at: 94), isHistory: true)
        #expect(try rows().first?.callIsVideo == false)
        #expect(try ends().first?.event == .callEnded(sid: "s1", duration: 90, isVideo: false))
        try apply(signal(.propose(media: [.audio, .video])), isHistory: true)
        #expect(try rows().first?.callIsVideo == true)
        #expect(try ends().first?.event == .callEnded(sid: "s1", duration: 90, isVideo: true))
        #expect(try ends().first?.call?.isVideo == true)
    }

    /// A peer knows the call's id, so can send a message named like its end.
    @Test func aMessageNamedLikeTheEndRowIsntTakenForIt() throws {
        let chat = try db.conversation(with: alice)
        let text = try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "hi", timestamp: long_ago + 1, remoteId: "s1/end"))
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 4))
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .outgoing, outcome: .failed, startedAt: long_ago))
        #expect(try db.reader.read { try Message.fetchOne($0, key: text.id) }?.body == "hi")
    }

    @Test func recordingAfterAReplayAddsNoSecondEndRowAndMovesTheFirst() throws {
        try apply(signal(propose), signal(.proceed, fromAccount: true, at: 4), signal(.finish(.success), at: 94))
        try db.recordCall(answered(duration: 95, endedAt: long_ago + 99))
        let end = try #require(try ends().first)
        #expect(try ends().count == 1)
        #expect(end.timestamp == long_ago + 99)
        #expect(end.event == .callEnded(sid: "s1", duration: 95, isVideo: false))
        #expect(try rows().first?.callDuration == 95)
    }

    @Test func recordingTwiceAddsNoSecondEndRow() throws {
        try db.recordCall(answered())
        try db.recordCall(answered())
        #expect(try rows().count == 2)
    }

    @Test func aFailedEndingHasNoEndRowAndRemovesOne() throws {
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "f", direction: .outgoing, outcome: .failed, startedAt: long_ago, answeredAt: long_ago + 1, duration: 5, endedAt: long_ago + 6))
        #expect(try rows().count == 1)

        try apply(signal(propose, sid: "s2"), signal(.proceed, sid: "s2", fromAccount: true, at: 4), signal(.finish(.success), sid: "s2", at: 94))
        #expect(try ends().count == 1)
        try apply(signal(.finish(.failedApplication), sid: "s2", at: 95))
        #expect(try rows().filter { $0.remoteId?.hasPrefix("s2") == true }.map(\.callOutcome) == [.failed])
        #expect(try ends().isEmpty)
    }

    @Test func callsThatWereNotAnsweredOrHaveNoLengthHaveNoEndRow() throws {
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "m", direction: .incoming, outcome: .missed, startedAt: long_ago, endedAt: long_ago + 5))
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "d", direction: .incoming, outcome: .declined, startedAt: long_ago, endedAt: long_ago + 5))
        try db.recordCall(answered(sid: "n", duration: nil))
        try db.recordCall(answered(sid: "e", endedAt: nil))
        #expect(try ends().isEmpty)
    }

    @Test func aLiveEndMovesTheChatUpAndHistoryDoesNot() throws {
        try db.recordCall(answered())
        let chat = try #require(try db.reader.read { try Conversation.filter(Column("peer") == alice).fetchOne($0) })
        #expect(chat.lastActivityAt == long_ago + 100)

        let other = try db.conversation(with: bob)
        let before = try #require(try db.reader.read { try Conversation.fetchOne($0, key: other.id!) })
        try db.writer.write { try Contact(jid: bob, subscription: .both, isInRoster: true).insert($0) }
        try apply(signal(propose, sid: "h", peer: bob), signal(.proceed, sid: "h", fromAccount: true, peer: bob, at: 4), signal(.finish(.success), sid: "h", peer: bob, at: 94), isHistory: true)
        let after = try #require(try db.reader.read { try Conversation.fetchOne($0, key: other.id!) })
        #expect(after.lastActivityAt == before.lastActivityAt)
        #expect(try ends().filter { $0.event == .callEnded(sid: "h", duration: 90, isVideo: false) }.count == 1)
    }

    @Test func aSelfAddressedFinishFindsTheStartRow() throws {
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .answered, startedAt: long_ago, answeredAt: long_ago + 2))
        let finish = CallSignal(sid: "s1", action: .finish(.success), sender: me, recipient: me, from: "me@example.org/tablet", isFromAccount: true, timestamp: long_ago + 50)
        try apply(finish)
        #expect(try ends().count == 1)
        try apply(finish)
        #expect(try rows().count == 2)
    }

    @Test func theMigrationGivesStoredAnsweredCallsAnEndRow() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v61-pending-roster-preauth")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('alice@example.org', 'chat', '2025-01-01 10:00:00.000')")
            let columns = "conversationId, direction, sender, body, timestamp, status, isRead, encryption, remoteId, callOutcome, callDuration, callAnsweredAt, callIsVideo"
            try db.execute(sql: """
                INSERT INTO message (\(columns)) VALUES
                (1, 'outgoing', 'me@example.org', '', '2025-01-01 10:00:00.000', 'sent', 1, 'none', 'a', 'answered', 90.5, '2025-01-01 10:00:10.250', 1),
                (1, 'incoming', 'alice@example.org', '', '2025-01-01 10:05:00.000', 'received', 1, 'none', 'b', 'answered', 30, NULL, 0),
                (1, 'incoming', 'alice@example.org', '', '2025-01-01 10:06:00.000', 'received', 0, 'none', 'c', 'missed', NULL, NULL, 0),
                (1, 'incoming', 'alice@example.org', '', '2025-01-01 10:07:00.000', 'received', 1, 'none', 'd', 'answered', NULL, NULL, 0)
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        let (ends, count, activity) = try queue.read { db in
            (try Message.filter(sql: "event IS NOT NULL").order(Column("timestamp")).fetchAll(db),
             try Message.fetchCount(db),
             try Conversation.fetchOne(db, key: 1)?.lastActivityAt)
        }
        #expect(count == 6)
        #expect(ends.map(\.event) == [.callEnded(sid: "a", duration: 90.5, isVideo: true), .callEnded(sid: "b", duration: 30, isVideo: false)])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(ends[0].timestamp == formatter.date(from: "2025-01-01T10:00:10.250Z")!.addingTimeInterval(90.5))
        #expect(ends[1].timestamp == formatter.date(from: "2025-01-01T10:05:30.000Z")!)
        #expect(ends.allSatisfy { $0.isRead && $0.direction == .event && $0.remoteId == nil && $0.callOutcome == nil })
        #expect(activity == formatter.date(from: "2025-01-01T10:00:00.000Z"))
    }

    /// A database that has run v62 holds the end as a copy of the call's row.
    @Test func theMigrationTurnsStoredEndRowsIntoEvents() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v62-call-ended")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('alice@example.org', 'chat', '2025-01-01 10:01:30.500')")
            let columns = "conversationId, direction, sender, body, timestamp, status, isRead, encryption, remoteId, callOutcome, callDuration, callAnsweredAt, callIsVideo, callEnded"
            try db.execute(sql: """
                INSERT INTO message (\(columns)) VALUES
                (1, 'outgoing', 'me@example.org', '', '2025-01-01 10:00:00.000', 'sent', 1, 'none', 'a', 'answered', 90.5, '2025-01-01 10:00:10.250', 1, 0),
                (1, 'outgoing', 'me@example.org', '', '2025-01-01 10:01:40.750', 'sent', 1, 'none', 'a/end', 'answered', 90.5, '2025-01-01 10:00:10.250', 1, 1),
                (1, 'incoming', 'alice@example.org', '', '2025-01-01 10:05:00.000', 'received', 1, 'none', 'b', 'answered', 30, NULL, 0, 0),
                (1, 'incoming', 'alice@example.org', '', '2025-01-01 10:05:30.000', 'received', 1, 'none', 'b/end', 'answered', 30, NULL, 0, 1)
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        let (rows, columns, indexed) = try queue.read { db in
            (try Message.order(Column("id")).fetchAll(db),
             try db.columns(in: "message").map(\.name),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageSearch_docsize"))
        }
        #expect(!columns.contains("callEnded"))
        #expect(indexed == 0)
        let plan = try queue.read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN SELECT * FROM message WHERE conversationId = 1 AND event IS NOT NULL AND json_extract(event, '$.callEnded.sid') = 'a'").map { $0["detail"] as String }.joined() }
        #expect(plan.contains("message_on_call_end"))
        #expect(rows.map(\.callOutcome) == [.answered, nil, .answered, nil])
        #expect(rows.map(\.remoteId) == ["a", nil, "b", nil])
        #expect(rows.map(\.direction) == [.outgoing, .event, .incoming, .event])
        #expect(rows[1].event == .callEnded(sid: "a", duration: 90.5, isVideo: true))
        #expect(rows[3].event == .callEnded(sid: "b", duration: 30, isVideo: false))
        #expect(rows[1].call == CallSummary(outcome: .answered, direction: .event, duration: 90.5, isVideo: true, isEnd: true))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(rows[1].timestamp == formatter.date(from: "2025-01-01T10:01:40.750Z")!)
        #expect(rows[3].timestamp == formatter.date(from: "2025-01-01T10:05:30.000Z")!)
        #expect(rows.allSatisfy { $0.isRead })
        #expect(rows[0].callDuration == 90.5 && rows[0].callIsVideo && rows[2].callDuration == 30)

        // What reads calls finds the start only, and the chat's last line is the end.
        let database = try AppDatabase(queue)
        try database.recordCall(CallRecord(peer: alice, account: me, sid: "a", direction: .outgoing, outcome: .answered, startedAt: long_ago, answeredAt: long_ago + 10, duration: 91, endedAt: long_ago + 101))
        let after = try queue.read { try Message.filter(sql: "event IS NOT NULL").fetchAll($0) }
        #expect(after.count == 2)
        #expect(after.first?.event == .callEnded(sid: "a", duration: 91, isVideo: true))
    }

    /// The end is an event, which other events keep out of the preview, but
    /// it is the chat's last line, as it was when it was a copy of the call.
    @Test func theEndRowIsTheChatListsLastMessage() throws {
        try db.recordCall(answered())
        let item = try #require(try db.reader.read { try ChatListItem.fetch($0, archived: false) }.first)
        #expect(item.lastMessage?.call == CallSummary(outcome: .answered, direction: .event, duration: 90, isEnd: true))
        #expect(item.unreadCount == 0)
    }

    @Test func theEndRowCountsAsNewerThanAnArchivedChat() throws {
        try db.recordCall(answered())
        let chat = try #require(try db.reader.read { try Conversation.filter(Column("peer") == alice).fetchOne($0) })
        let counted = try db.reader.read { try Message.filter(Column("conversationId") == chat.id! && Column("timestamp") > long_ago + 50).excludingEvents().fetchCount($0) }
        #expect(counted == 1)
    }

    // MARK: Elsewhere

    @Test func aMissedCallNotifiesWithWordsOfItsOwn() throws {
        _ = try db.conversation(with: alice)
        #expect(try db.claimNotifications().isEmpty)
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .missed, startedAt: Date()))
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s2", direction: .incoming, outcome: .answered, startedAt: Date(), duration: 4))
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["Missed call"])
        #expect(claimed.first?.peer == alice)
        #expect(try db.unreadCount() == 1)
    }

    @Test func callsAreNotSearchable() throws {
        let note = try db.insert(Message(conversationId: try db.conversation(with: alice).id!, direction: .incoming, sender: alice, body: "call me"))
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .missed, startedAt: Date()))
        #expect(try db.searchMessages("call").map(\.messageId) == [note.id!])
        #expect(try db.searchMessages("s1").isEmpty)
        try db.writer.write { try $0.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('integrity-check')") }
    }

    @Test func theChatListShowsTheCallAsTheLastMessage() throws {
        try db.recordCall(CallRecord(peer: alice, account: me, sid: "s1", direction: .incoming, outcome: .missed, startedAt: Date()))
        let item = try #require(try db.chatList().first)
        #expect(item.lastMessage?.call?.outcome == .missed)
        #expect(item.unreadCount == 1)
    }

    @Test func theColumnsExistAndOrdinaryMessagesLeaveThemEmpty() throws {
        let message = try db.insert(Message(conversationId: try db.conversation(with: alice).id!, direction: .incoming, sender: alice, body: "hi"))
        let columns = try db.reader.read { try Row.fetchAll($0, sql: "PRAGMA table_info(message)").map { $0["name"] as String } }
        #expect(columns.contains("callOutcome") && columns.contains("callDuration") && columns.contains("callAnsweredAt") && columns.contains("callIsVideo"))
        let stored = try #require(try db.reader.read { try Message.fetchOne($0, key: message.id!) })
        #expect(stored.callOutcome == nil)
        #expect(stored.call == nil)
    }
}
