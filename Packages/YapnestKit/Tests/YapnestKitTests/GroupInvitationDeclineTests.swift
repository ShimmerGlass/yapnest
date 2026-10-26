import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!

/// When declining tells the inviter, which a stranger must never learn from.
struct GroupInvitationDeclineTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let alice = YapnestKit.JID("alice@example.org")!
    let room = YapnestKit.JID("club@groups.example.net")!

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
    }

    private var declines: [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc#user")?.firstChild(name: "decline") != nil }
    }

    @Test func aContactWhoInvitedThroughTheRoomIsTold() throws {
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil)
        try session.declineGroupInvitation(room)

        let decline = try #require(declines.first)
        #expect(declines.count == 1)
        #expect(decline.to?.stringValue == "club@groups.example.net")
        #expect(decline.id != nil)
        let x = try #require(decline.firstChild(name: "x", xmlns: "http://jabber.org/protocol/muc#user"))
        #expect(x.firstChild(name: "decline")?.getAttribute("to") == "alice@example.org")
        // No reason, whatever the invitation said.
        #expect(x.firstChild(name: "decline")?.firstChild(name: "reason") == nil)
        #expect(try database.groupInvitation(room) == nil)
    }

    @Test func aStrangerIsNeverTold() throws {
        // Not in the roster at all, and in the roster without a subscription:
        // neither has been chosen by the user.
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil)
        try session.declineGroupInvitation(room)
        try database.updateRosterItem(jid: alice, name: nil, subscription: .none, isPending: false)
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil)
        try session.declineGroupInvitation(room)
        #expect(declines.isEmpty)
    }

    @Test func aContactWeOnlyHearFromStillCounts() throws {
        try database.updateRosterItem(jid: alice, name: nil, subscription: .from, isPending: false)
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil)
        try session.declineGroupInvitation(room)
        #expect(declines.count == 1)
    }

    @Test func offlineJustForgetsIt() throws {
        let offline = try makeSession(me, database: database)
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil)
        try offline.declineGroupInvitation(room)
        #expect(try database.groupInvitation(room) == nil)
        #expect(declines.isEmpty)
    }

    @Test func nothingPendingSendsNothing() throws {
        try session.declineGroupInvitation(room)
        #expect(declines.isEmpty)
    }

    @Test func aRelayedInvitationFromAContactIsHeld() throws {
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        let xml = "<message from='club@groups.example.net' to='me@example.org' id='i'><x xmlns='http://jabber.org/protocol/muc#user'><invite from='alice@example.org'/></x></message>"
        session.invitationReceived(parseStanza(xml))
        #expect(try database.groupInvitation(room)?.inviter == alice)
    }

    // MARK: Receiving one

    private func relayedDecline(from sender: String) -> Martin.Message {
        let xml = "<message from='\(sender)' to='me@example.org' id='d'><x xmlns='http://jabber.org/protocol/muc#user'><decline from='alice@example.org'><reason>No</reason></decline></x></message>"
        return parseStanza(xml)
    }

    @Test func aDeclineFromTheRoomIsReported() throws {
        let stanza = relayedDecline(from: "club@groups.example.net")
        #expect(XMPPSession.isInvitation(stanza))
        let found = try #require(XMPPSession.decline(in: stanza))
        #expect(found.room == room)
        #expect(found.from == alice)
    }

    @Test func aDeclineIsNotHeldAsAnInvitation() throws {
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        session.invitationReceived(relayedDecline(from: "club@groups.example.net"))
        #expect(try database.groupInvitation(room) == nil)
        #expect(try database.groupChat(room) == nil)
    }

    @Test func aDeclineFromAnOccupantIsAForgery() {
        #expect(XMPPSession.decline(in: relayedDecline(from: "club@groups.example.net/mallory")) == nil)
    }

    @Test func aDirectInvitationIsForgottenWithoutAnswer() throws {
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil, isDirect: true, isVouched: true)
        try session.declineGroupInvitation(room)
        #expect(try database.groupInvitation(room) == nil)
        #expect(declines.isEmpty)
        #expect(wire.messages.isEmpty)
    }

    @Test func aRelayedInvitationFromAVouchedRoomIsStillDeclined() throws {
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try database.recordGroupInvitation(room: room, inviter: alice, reason: nil, isVouched: true)
        try session.declineGroupInvitation(room)
        #expect(declines.count == 1)
    }
}
