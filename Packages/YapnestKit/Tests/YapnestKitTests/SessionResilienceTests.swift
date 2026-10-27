import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
private let other = YapnestKit.JID("book@rooms.example.org")!

/// What a resumed stream does.
struct ResumeTests {
    @Test func theFollowUpWaitsForMartinToHoldTheNewState() {
        // Martin publishes the state before storing it: still connecting.
        #expect(XMPPSession.connectedStep(isConnected: false, startedOn: 4, now: 4) == .wait)
        #expect(XMPPSession.connectedStep(isConnected: true, startedOn: 4, now: 4) == .run)
    }

    @Test func theFollowUpIsDroppedWhenTheConnectionChanged() {
        #expect(XMPPSession.connectedStep(isConnected: true, startedOn: 4, now: 5) == .abandon)
        #expect(XMPPSession.connectedStep(isConnected: false, startedOn: 4, now: 5) == .abandon)
    }

    @Test func onlyTheAppResendsPendingMessages() {
        #expect(XMPPSession.Policy.app.resendsPending)
        #expect(!XMPPSession.Policy.share.resendsPending)
        #expect(!XMPPSession.Policy.notificationService.resendsPending)
    }

    @Test func roomsStillJoiningAreTheOnesToJoinAgain() {
        let rooms: [YapnestKit.JID: RoomStatus] = [
            room: RoomStatus(phase: .joining, nickname: "me"),
            other: RoomStatus(phase: .joined, nickname: "me"),
            YapnestKit.JID("c@rooms.example.org")!: RoomStatus(phase: .failed("x"), nickname: "me"),
        ]
        #expect(XMPPSession.stuckJoins(rooms) == [room])
    }

    @Test func aResumeLeavesAnOfflineSessionAlone() throws {
        let session = try makeSession(me)
        try session.database.joinGroupChat(room, nickname: "me")
        session.resumeWork()
        #expect(session.roomStatus(room) == nil)
    }
}

/// How the rooms follow their archive.
struct RoomFollowsArchiveTests {
    private func status(reachedEnd: Bool, syncing: Bool = false) -> RoomStatus {
        var status = RoomStatus(phase: .joined, nickname: "me")
        status.isSyncing = syncing
        status.catchUpReachedEnd = reachedEnd
        return status
    }

    @Test func aRoomThatReadToTheEndOfItsArchiveIsFollowed() {
        #expect(XMPPSession.followsArchive(source: .live, isHistory: false, status: status(reachedEnd: true)))
    }

    @Test func aRoomWhoseCatchUpGaveUpIsNot() {
        #expect(!XMPPSession.followsArchive(source: .live, isHistory: false, status: status(reachedEnd: false)))
    }

    @Test func aNewVisitStartsWithoutHavingReachedTheEnd() {
        #expect(!RoomStatus(phase: .joining, nickname: "me").catchUpReachedEnd)
    }

    @Test func aSyncingRoomIsNotFollowed() {
        #expect(!XMPPSession.followsArchive(source: .live, isHistory: false, status: status(reachedEnd: true, syncing: true)))
    }

    @Test func historyAndUnknownRoomsAreNotFollowed() {
        #expect(!XMPPSession.followsArchive(source: .live, isHistory: true, status: status(reachedEnd: true)))
        #expect(!XMPPSession.followsArchive(source: .live, isHistory: false, status: nil))
    }
}

struct InvitationJoinTests {
    @Test func aRoomMustBeATextConferenceToBeJoined() {
        #expect(XMPPSession.isGroupChat(identities: [("conference", "text")]))
        #expect(!XMPPSession.isGroupChat(identities: [("account", "registered")]))
        #expect(!XMPPSession.isGroupChat(identities: [("conference", "irc")]))
        #expect(!XMPPSession.isGroupChat(identities: []))
    }

    @Test func aRoomJoinedFromAnInvitationMustAlreadyExist() {
        #expect(RoomStatus(phase: .joining, nickname: "me").mayCreate)
        #expect(!RoomStatus(phase: .joining, nickname: "me", mayCreate: false).mayCreate)
    }
}

struct NotificationCatchUpRoomsTests {
    @Test func aRoomThatNeverNotifiesIsNotReadForAPush() {
        let loud = GroupChat(conversationId: 1, jid: JID("a@rooms.example.org")!, nickname: "me")
        let mentions = GroupChat(conversationId: 2, jid: JID("b@rooms.example.org")!, nickname: "me", notify: .onMention)
        let muted = GroupChat(conversationId: 3, jid: JID("c@rooms.example.org")!, nickname: "me", notify: .never)
        let left = GroupChat(conversationId: 4, jid: JID("d@rooms.example.org")!, nickname: "me", hasLeft: true)
        let rooms = XMPPSession.roomsToCatchUpForNotifications([loud, mentions, muted, left])
        #expect(rooms.map(\.conversationId) == [1, 2])
    }
}

struct NotificationRoomTimeoutTests {
    @Test func aRoomThatNeverAnswersDoesNotHoldThePushOrMoveItsCursor() async throws {
        let room = JID("a@rooms.example.org")!
        let database = try AppDatabase.inMemory()
        let session = try makeSession(JID("me@example.org")!, database: database)
        let wire = FakeWire()
        session.connectForTesting(wire)
        try database.joinGroupChat(room, nickname: "me", name: "A")
        try database.updateGroupChat(room) { $0.lastArchiveId = "cursor" }

        await withCheckedContinuation { continuation in
            session.catchUpRoomArchives(timeout: 0.2) { continuation.resume() }
        }
        #expect(try database.groupChat(room)?.lastArchiveId == "cursor")
    }
}

struct NotificationPageTests {
    @Test func aCursorReadsOnFromIt() {
        #expect(XMPPSession.notificationPage(after: "a", since: nil) == .after("a"))
        #expect(XMPPSession.notificationPage(after: "a", since: Date()) == .after("a"))
    }

    @Test func noCursorAndNoDateReadsTheNewest() {
        #expect(XMPPSession.notificationPage(after: nil, since: nil) == .newest)
    }

    @Test func aDateReadsForwardSoABusyRoomIsNotSkipped() {
        #expect(XMPPSession.notificationPage(after: nil, since: Date()) == .forward)
    }
}
