import Foundation
import GRDB
import Combine
import Martin
import os
import Testing
@testable import YapnestKit

/// Invitations through rooms that can't vouch for the inviter, waiting for an answer.
struct GroupInvitationTests {
    let db: AppDatabase
    let room = YapnestKit.JID("club@groups.example.net")!
    let other = YapnestKit.JID("book@groups.example.net")!
    let alice = YapnestKit.JID("alice@example.org")!
    let bob = YapnestKit.JID("bob@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func pending() throws -> [GroupInvitation] {
        try db.reader.read(AppDatabase.groupInvitations)
    }

    @Test func recordsAnInvitation() throws {
        let date = Date(timeIntervalSince1970: 1000)
        try db.recordGroupInvitation(room: room, inviter: alice, reason: "Join us", at: date)
        let invitation = try #require(try db.groupInvitation(room))
        #expect(invitation == GroupInvitation(room: room, inviter: alice, reason: "Join us", receivedAt: date))
    }

    @Test func keepsThePasswordTheInviterSent() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, password: "s3cret")
        #expect(try db.groupInvitation(room)?.password == "s3cret")
    }

    @Test func aRepeatReplacesTheOldOne() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: "Join us", at: Date(timeIntervalSince1970: 1000))
        let later = Date(timeIntervalSince1970: 2000)
        try db.recordGroupInvitation(room: room, inviter: bob, reason: nil, at: later)
        let all = try pending()
        #expect(all.count == 1)
        #expect(all.first?.inviter == bob)
        #expect(all.first?.reason == nil)
        #expect(all.first?.receivedAt == later)
    }

    @Test func removingOneLeavesTheRest() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil)
        try db.recordGroupInvitation(room: other, inviter: alice, reason: nil)
        try db.removeGroupInvitation(room)
        #expect(try db.groupInvitation(room) == nil)
        #expect(try pending().map(\.room) == [other])
        // Nothing there is fine.
        try db.removeGroupInvitation(room)
    }

    @Test func newestComeFirst() throws {
        try db.recordGroupInvitation(room: room, inviter: alice, reason: nil, at: Date(timeIntervalSince1970: 1000))
        try db.recordGroupInvitation(room: other, inviter: bob, reason: nil, at: Date(timeIntervalSince1970: 2000))
        #expect(try pending().map(\.room) == [other, room])
    }
}

private let me = YapnestKit.JID("me@example.org")!

/// What the session does with an invitation, which needs no connection.
struct GroupInvitationSessionTests {
    let database: AppDatabase
    let session: XMPPSession
    let alice = YapnestKit.JID("alice@example.org")!
    let foreign = YapnestKit.JID("club@groups.example.net")!

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
    }

    private func relayed(room: String = "club@groups.example.net", from inviter: String = "alice@example.org", reason: String? = "Come along") -> Martin.Message {
        let why = reason.map { "<reason>\($0)</reason>" } ?? ""
        let xml = "<message from='\(room)' to='me@example.org' id='i'><x xmlns='http://jabber.org/protocol/muc#user'><invite from='\(inviter)'>\(why)</invite></x></message>"
        return Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
    }

    @Test func aRoomThatCantVouchLeavesItPending() throws {
        session.invitationReceived(relayed())
        let invitation = try #require(try database.groupInvitation(foreign))
        #expect(invitation.inviter == alice)
        #expect(invitation.reason == "Come along")
    }

    @Test func aHeldInvitationSaysSoToTheApp() throws {
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let subscription = session.events.sink { if case .invitationHeld = $0 { heard.withLock { $0 += 1 } } }
        session.invitationReceived(relayed())
        #expect(heard.withLock { $0 } == 1)
        subscription.cancel()
    }

    @Test func noReasonIsNone() throws {
        session.invitationReceived(relayed(reason: nil))
        #expect(try database.groupInvitation(foreign)?.reason == nil)
    }

    @Test func aRoomOnTheirServerIsHeldAsVouchedFor() throws {
        session.invitationReceived(relayed(room: "club@conference.example.org"))
        let invitation = try #require(try database.groupInvitation(YapnestKit.JID("club@conference.example.org")!))
        #expect(invitation.isVouched)
        #expect(!invitation.isDirect)
    }

    @Test func anotherUserOnTheirServerCantVouchForThem() throws {
        let impostor = YapnestKit.JID("evil@example.org")!
        session.invitationReceived(relayed(room: impostor.description, from: "alice@example.org"))
        #expect(try database.groupInvitation(impostor)?.isVouched == false)
    }

    @Test func aRoomThatCantVouchIsHeldAsUnvouched() throws {
        session.invitationReceived(relayed())
        #expect(try database.groupInvitation(foreign)?.isVouched == false)
    }

    @Test func aDirectInvitationFromAContactIsHeld() throws {
        let xml = "<message from='alice@example.org/phone' to='me@example.org'><x xmlns='jabber:x:conference' jid='club@groups.example.net' password='pw'/></message>"
        session.invitationReceived(parseStanza(xml))
        let invitation = try #require(try database.groupInvitation(foreign))
        #expect(invitation.isDirect)
        #expect(invitation.isVouched)
        #expect(invitation.inviter == alice)
        #expect(invitation.password == "pw")
    }

    @Test func aDirectInvitationFromAStrangerIsDropped() throws {
        let xml = "<message from='mallory@example.net/x' to='me@example.org'><x xmlns='jabber:x:conference' jid='club@groups.example.net'/></message>"
        session.invitationReceived(parseStanza(xml))
        #expect(try database.reader.read(AppDatabase.groupInvitations).isEmpty)
    }

    @Test func migrationMarksStoredInvitationsAsRelayed() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v40-notification-interval")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO groupInvitation (room, inviter, receivedAt) VALUES ('x@rooms.example.org', 'a@example.org', 0)")
        }
        try AppDatabase.migrator.migrate(queue)
        let stored = try queue.read { try GroupInvitation.fetchAll($0) }
        #expect(stored.map(\.isDirect) == [false])
        #expect(stored.map(\.isVouched) == [true])
    }

    @Test func aRosterItemWithoutASubscriptionIsDroppedAndDoesNotNotify() throws {
        try database.updateRosterItem(jid: alice, name: nil, subscription: .none, isPending: false)
        session.invitationReceived(relayed())
        session.invitationReceived(parseStanza("<message from='alice@example.org/x' to='me@example.org'><x xmlns='jabber:x:conference' jid='club@groups.example.net'/></message>"))
        #expect(try database.reader.read(AppDatabase.groupInvitations).isEmpty)
        #expect(try database.claimNotifications().isEmpty)
        try database.markAddedByUser(alice)
        session.invitationReceived(relayed())
        #expect(try database.groupInvitation(foreign) != nil)
        #expect(try database.claimNotifications().count == 1)
    }

    @Test func anInvitationFromSomeoneWeSubscribedToIsHeldAndNotified() throws {
        try database.updateRosterItem(jid: alice, name: nil, subscription: .to, isPending: false)
        #expect(try database.claimNotifications().isEmpty)
        session.invitationReceived(relayed())
        #expect(try database.groupInvitation(foreign) != nil)
        #expect(try database.claimNotifications().count == 1)
    }

    @Test func strangersAreDropped() throws {
        session.invitationReceived(relayed(from: "mallory@example.net"))
        #expect(try database.reader.read(AppDatabase.groupInvitations).isEmpty)
    }

    @Test func nothingIsHeldForAGroupWeAreIn() throws {
        try database.joinGroupChat(foreign, nickname: "me")
        session.invitationReceived(relayed())
        #expect(try database.groupInvitation(foreign) == nil)
        // One we left is worth asking about again.
        try database.updateGroupChat(foreign) { $0.hasLeft = true }
        session.invitationReceived(relayed())
        #expect(try database.groupInvitation(foreign) != nil)
    }

    @Test func declineForgetsItWithoutAConnection() throws {
        session.invitationReceived(relayed())
        try session.declineGroupInvitation(foreign)
        #expect(try database.groupInvitation(foreign) == nil)
    }

    @Test func aFailedJoinKeepsIt() async throws {
        session.invitationReceived(relayed())
        // Not connected, so the join throws.
        await #expect(throws: (any Error).self) { try await session.acceptGroupInvitation(foreign) }
        #expect(try database.groupInvitation(foreign) != nil)
    }

    @Test func aBookmarkFromAnotherDeviceAnswersIt() throws {
        session.invitationReceived(relayed())
        session.bookmarkChanged(.published(Bookmark(jid: foreign, name: nil, autojoin: true, nick: "me")))
        #expect(try database.groupInvitation(foreign) == nil)
    }

    @Test func refetchedBookmarksLeaveWhatWasRetractedAndKeepTheRest() throws {
        let kept = YapnestKit.JID("kept@groups.example.net")!, gone = YapnestKit.JID("gone@groups.example.net")!
        let unbookmarked = YapnestKit.JID("new@groups.example.net")!
        for (jid, bookmarked) in [(kept, true), (gone, true), (unbookmarked, false)] {
            _ = try database.joinGroupChat(jid, nickname: "me", isBookmarked: bookmarked)
        }
        session.reconcileBookmarks([Bookmark(jid: kept, name: "Renamed", autojoin: true, nick: "me")])
        #expect(try database.groupChat(kept)?.name == "Renamed")
        #expect(try database.groupChat(kept)?.hasLeft == false)
        #expect(try database.groupChat(gone)?.hasLeft == true)
        // Not bookmarked yet, perhaps because its publish is on its way: left alone, and not published here.
        #expect(try database.groupChat(unbookmarked)?.hasLeft == false)
    }
}
