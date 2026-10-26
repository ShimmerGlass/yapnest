import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The notification for a held group invitation, claimed with the messages'.
struct InvitationNotificationTests {
    let db: AppDatabase
    let room = YapnestKit.JID("club@conference.example.org")!
    let foreign = YapnestKit.JID("book@groups.example.net")!
    let alice = YapnestKit.JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
        try db.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        // The first claim only sets the mark.
        _ = try db.claimNotifications()
    }

    @Test func aNewInvitationIsClaimedOnce() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.invitationRoom) == [room])
        #expect(try db.claimNotifications().isEmpty)
    }

    @Test func aReplacementIsNotClaimedAgain() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        _ = try db.claimNotifications()
        try db.recordGroupInvitation(room: room, inviter: alice, reason: "Again", isVouched: true)
        #expect(try db.claimNotifications().isEmpty)
    }

    @Test func aReplacementBeforeTheClaimIsOneNotification() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        try db.recordGroupInvitation(room: room, inviter: alice, reason: "Again", isVouched: true)
        #expect(try db.claimNotifications().count == 1)
    }

    @Test func aVouchedInvitationSaysWhoInvitedYou() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        let notification = try #require(try db.claimNotifications().first)
        #expect(notification.body == "Alice invited you to club@conference.example.org")
        #expect(notification.invitationRoom == room)
        #expect(!notification.isQuiet)
        let content = notification.content(badge: nil)
        #expect(content.userInfo[MessageNotification.peerKey] == nil)
        #expect(content.userInfo[MessageNotification.invitationKey] as? String == room.description)
        #expect(notification.requestIdentifier == "invitation-club@conference.example.org")
    }

    @Test func anUnvouchedInvitationSaysTheRoomClaimsIt() throws {
        try db.recordGroupInvitation(room: foreign, inviter: alice, reason: nil)
        let notification = try #require(try db.claimNotifications().first)
        #expect(notification.body == "book@groups.example.net says Alice invited you")
    }

    @Test func aClaimThatDoesNotNotifyStillUsesTheInvitationUp() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        #expect(try db.claimNotifications(notifies: false).isEmpty)
        #expect(try db.claimNotifications().isEmpty)
    }

    @Test func anInvitationAnsweredBeforeTheClaimIsNotNotified() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        try db.removeGroupInvitation(room)
        #expect(try db.claimNotifications().isEmpty)
    }

    @Test func aDeliveredNotificationOfAnInvitationNoLongerHeldIsRemoved() {
        let delivered: [(identifier: String, userInfo: [AnyHashable: Any])] = [
            ("push-1", [MessageNotification.invitationKey: room.description]),
            ("invitation-book", [MessageNotification.invitationKey: foreign.description]),
            ("message-4", [MessageNotification.peerKey: alice.description]),
        ]
        #expect(MessageNotification.staleInvitationNotifications(among: delivered, held: [foreign]) == ["push-1"])
        #expect(MessageNotification.staleInvitationNotifications(among: delivered, held: []) == ["push-1", "invitation-book"])
    }

    @Test func anInvitationNotificationSurvivesTheBadgeCleanup() {
        let bob = YapnestKit.JID("bob@example.org")!
        let delivered = [
            (id: "invitation-club", thread: MessageNotification.invitationsThread),
            (id: "message-1", thread: bob.description),
            (id: "message-2", thread: alice.description),
        ]
        let stale = AppDatabase.staleNotifications(threads: delivered, unread: [alice: 1, bob: 0])
        #expect(stale == ["message-1"])
    }

    @Test func anInvitationNotificationIsOnTheInvitationsThread() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        let notification = try #require(try db.claimNotifications().first)
        #expect(notification.content(badge: nil).threadIdentifier == MessageNotification.invitationsThread)
    }

    @Test func migrationDoesNotNotifyAboutInvitationsHeldBefore() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v41-invitation-origin")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO groupInvitation (room, inviter, receivedAt) VALUES ('x@rooms.example.org', 'a@example.org', 0)")
        }
        try AppDatabase.migrator.migrate(queue)
        #expect(try queue.read { try GroupInvitation.fetchAll($0) }.map(\.isNotified) == [true])
    }
}
