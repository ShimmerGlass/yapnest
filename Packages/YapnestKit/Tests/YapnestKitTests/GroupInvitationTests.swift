import Foundation
import Martin
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

    @Test func noReasonIsNone() throws {
        session.invitationReceived(relayed(reason: nil))
        #expect(try database.groupInvitation(foreign)?.reason == nil)
    }

    @Test func aRoomOnTheirServerIsNotHeld() throws {
        session.invitationReceived(relayed(room: "club@conference.example.org"))
        #expect(try database.reader.read(AppDatabase.groupInvitations).isEmpty)
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
}
