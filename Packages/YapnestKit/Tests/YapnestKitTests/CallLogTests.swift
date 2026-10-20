import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!
private let bob = JID("bob@example.org")!
private let long_ago = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))

struct CallLogTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
        try db.writer.write { try Contact(jid: alice, isInRoster: true).insert($0) }
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
        try db.reader.read { try Message.filter(Column("callOutcome") != nil).order(Column("id")).fetchAll($0) }
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
        #expect(try rows().count == 1)
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
        try db.writer.write { try Contact(jid: bob, isInRoster: true).insert($0) }
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

    @Test func aChatWeHaveStaysOpenForItsCalls() throws {
        _ = try db.conversation(with: bob)
        try apply(signal(propose, peer: bob), signal(.retract(nil), peer: bob, at: 2))
        #expect(try rows().count == 1)
    }

    @Test func ringingSaysNothing() throws {
        try apply(signal(.ringing))
        #expect(try rows().isEmpty)
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
