import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

struct GroupSenderSpoofingTests {
    private let xml = """
        <message from='cake@rooms.example.org/mallory' type='groupchat' id='m1'>
          <body>trust me</body>
          <x xmlns='http://jabber.org/protocol/muc#user'><item jid='alice@example.org/phone'/></x>
        </message>
        """

    private func parse(source: InboundMessage.Source, occupants: [String: YapnestKit.JID] = [:], isNonAnonymous: Bool = false) throws -> InboundMessage {
        let context = RoomContext(jid: room, nickname: "me", occupants: occupants, isNonAnonymous: isNonAnonymous)
        return try #require(InboundMessage(groupchat: stanza(xml), room: context, account: me, source: source))
    }

    @Test func liveMessagesCannotClaimAnAddress() throws {
        let m = try parse(source: .live)
        #expect(m.sender != alice)
        #expect(!m.isOutgoing)
    }

    @Test func liveMessagesUseThePresenceAddress() throws {
        let m = try parse(source: .live, occupants: ["mallory": YapnestKit.JID("mallory@example.org")!])
        #expect(m.sender == YapnestKit.JID("mallory@example.org")!)
    }

    @Test func archivedMessagesCarryTheRealAddress() throws {
        let m = try parse(source: .archive(serverId: "r1", timestamp: nil), isNonAnonymous: true)
        #expect(m.sender == alice)
        // An anonymous room's archive may keep the sender's own claim and add none.
        let anonymous = try parse(source: .archive(serverId: "r1", timestamp: nil))
        #expect(anonymous.sender == room)
    }

    @Test func anArchiveThatGivesTwoOriginalSendersIsNotBelieved() throws {
        let openfire = """
            <message from='cake@rooms.example.org/bob' type='groupchat' id='m1'>
              <body>hi</body>
              <addresses xmlns='http://jabber.org/protocol/address'><address type='ofrom' jid='mallory@example.org'/></addresses>
              <addresses xmlns='http://jabber.org/protocol/address'><address type='ofrom' jid='alice@example.org/phone'/></addresses>
            </message>
            """
        let room = RoomContext(jid: room, nickname: "me", isNonAnonymous: true)
        // One of them is the sender's, and nothing says which.
        let archived = try #require(InboundMessage(groupchat: stanza(openfire), room: room, account: me, source: .archive(serverId: "r1", timestamp: nil)))
        #expect(archived.sender == room.jid)
        // Live, the same element is whatever the sender wrote.
        let live = try #require(InboundMessage(groupchat: stanza(openfire), room: room, account: me, source: .live))
        #expect(live.sender != alice)
    }

    @Test func claimingOurAddressLiveDoesNotMakeAMessageOurs() throws {
        let forged = xml.replacingOccurrences(of: "alice@example.org/phone", with: "me@example.org/laptop")
        let m = try #require(InboundMessage(groupchat: stanza(forged), room: RoomContext(jid: room, nickname: "me"), account: me, source: .live))
        #expect(!m.isOutgoing)
    }
}

/// What each dev server's room archive kept of a message whose sender
/// claimed to be Carol, both as a muc#user item and as an original sender.
struct ArchivedSenderTests {
    private let bob = YapnestKit.JID("bob@example.org")!
    private let x = "http://jabber.org/protocol/muc#user"
    private let addresses = "http://jabber.org/protocol/address"

    private func sender(_ inner: String, isNonAnonymous: Bool = true) throws -> YapnestKit.JID {
        let xml = "<message from='cake@rooms.example.org/bob' type='groupchat' id='m1'><body>hi</body>\(inner)</message>"
        let context = RoomContext(jid: room, nickname: "me", isNonAnonymous: isNonAnonymous)
        return try #require(InboundMessage(groupchat: stanza(xml), room: context, account: me, source: .archive(serverId: "r1", timestamp: nil))).sender
    }

    private var forgedItem: String { "<x xmlns='\(x)'><item jid='carol@example.org/x'/></x>" }
    private var forgedOriginal: String { "<addresses xmlns='\(addresses)'><address type='ofrom' jid='carol@example.org'/></addresses>" }

    /// Prosody appends its own item after the sender's.
    @Test func prosodysOwnItemComesLast() throws {
        let real = "<x xmlns='\(x)'><item role='participant' affiliation='none' jid='bob@example.org'/></x>"
        #expect(try sender(forgedItem + forgedOriginal + real) == room)
        #expect(try sender(real) == bob)
    }

    /// ejabberd replaces the sender's item but keeps their original sender.
    @Test func ejabberdKeepsTheSendersOriginalSender() throws {
        let real = "<x xmlns='\(x)'><item jid='bob@example.org/probe'/></x>"
        #expect(try sender(real + forgedOriginal) == room)
        #expect(try sender(real) == bob)
    }

    /// Openfire keeps the sender's item, the only one, and appends its own
    /// original sender.
    @Test func openfiresOnlyItemIsTheSenders() throws {
        let real = "<addresses xmlns='\(addresses)'><address type='ofrom' jid='bob@example.org/probe'/></addresses>"
        #expect(try sender(forgedItem + forgedOriginal + real) == room)
        #expect(try sender(real) == bob)
    }

    /// Openfire's anonymous archive keeps the sender's claims and adds nothing.
    @Test func anAnonymousRoomsArchiveIsNotBelieved() throws {
        #expect(try sender(forgedItem + forgedOriginal, isNonAnonymous: false) == room)
        #expect(try sender(forgedItem, isNonAnonymous: false) == room)
    }

    @Test func aSenderRepeatingTheirOwnAddressIsStillThemselves() throws {
        let item = "<x xmlns='\(x)'><item jid='bob@example.org/phone'/></x>"
        let original = "<addresses xmlns='\(addresses)'><address type='ofrom' jid='bob@example.org'/></addresses>"
        #expect(try sender(item + original) == bob)
    }

    @Test func anAddressThatDoesntParseIsADisagreement() throws {
        let real = "<x xmlns='\(x)'><item jid='bob@example.org'/></x>"
        let garbage = "<addresses xmlns='\(addresses)'><address type='ofrom' jid='@@'/></addresses>"
        #expect(try sender(real + garbage) == room)
    }
}

/// Whose sessions an encrypted group message is decrypted with.
struct EncryptedGroupSenderTests {
    private let carol = YapnestKit.JID("carol@example.org")!
    private let archive = InboundMessage.Source.archive(serverId: "r1", timestamp: nil)

    private func sender(nick: String, occupantId: String? = nil, source: InboundMessage.Source, ownOccupantId: String? = nil) -> YapnestKit.JID? {
        let id = occupantId.map { "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='\($0)'/>" } ?? ""
        let message = stanza("<message from='cake@rooms.example.org/\(nick)' type='groupchat' id='m1'>\(id)</message>")
        let context = RoomContext(jid: room, nickname: "me", occupants: ["carol": carol], trustsOccupantIds: true, ownOccupantId: ownOccupantId, isNonAnonymous: true)
        return XMPPSession.encryptedSender(of: message, nick: nick, in: context, account: me, source: source)
    }

    @Test func liveTheOccupantsAddressIsUsed() {
        #expect(sender(nick: "carol", source: .live) == carol)
        #expect(sender(nick: "me", source: .live) == me)
    }

    /// Someone else held the nick when it was written.
    @Test func archivedTheNickSaysNothing() {
        #expect(sender(nick: "carol", source: archive) == nil)
        #expect(sender(nick: "me", source: archive) == nil)
    }

    @Test func archivedOursIsKnownByOurOccupantId() {
        #expect(sender(nick: "me", occupantId: "ours", source: archive, ownOccupantId: "ours") == me)
        #expect(sender(nick: "me", occupantId: "theirs", source: archive, ownOccupantId: "ours") == nil)
    }
}

struct ArchiveResultOwnershipTests {
    private func accepted(_ xml: String, from source: YapnestKit.JID, isAccount: Bool = false) -> Bool {
        XMPPSession.archivedMessage(stanza(xml), belongsTo: source, isAccount: isAccount)
    }

    @Test func aRoomMayReturnItsOwnMessages() {
        #expect(accepted("<message from='cake@rooms.example.org/bob' type='groupchat'><body>hi</body></message>", from: room))
        #expect(accepted("<message from='cake@rooms.example.org' type='groupchat'><body>hi</body></message>", from: room))
    }

    @Test func aRoomMayNotReturnAnotherRoomsMessages() {
        #expect(!accepted("<message from='team@conference.example.org/Boss' type='groupchat'><body>hi</body></message>", from: room))
    }

    @Test func aRoomResultWithoutASenderIsRejected() {
        #expect(!accepted("<message type='groupchat'><body>hi</body></message>", from: room))
    }

    @Test func ourArchiveMayReturnOurMessages() {
        #expect(accepted("<message from='alice@example.org/x' to='me@example.org' type='chat'><body>hi</body></message>", from: me, isAccount: true))
        #expect(accepted("<message from='me@example.org/x' to='alice@example.org' type='chat'><body>hi</body></message>", from: me, isAccount: true))
    }

    @Test func ourArchiveMayNotReturnOthersConversations() {
        #expect(!accepted("<message from='alice@example.org' to='bob@example.org' type='chat'><body>hi</body></message>", from: me, isAccount: true))
    }

    @Test func ourArchiveResultWithoutARecipientIsAccepted() {
        #expect(accepted("<message from='alice@example.org' type='chat'><body>hi</body></message>", from: me, isAccount: true))
    }
}

struct InvitationParsingTests {
    @Test func aRoomRelaysFromItsBareAddress() throws {
        let invitation = try #require(XMPPSession.invitation(in: stanza("""
            <message from='cake@rooms.example.org'>
              <x xmlns='http://jabber.org/protocol/muc#user'><invite from='alice@example.org/phone'><reason>Join us</reason></invite></x>
            </message>
            """)))
        #expect(invitation == .init(room: room, inviter: alice, isDirect: false, reason: "Join us"))
    }

    /// A user on the inviter's server posing as a room: its server stamped a
    /// full address on what it sent, which no room would relay from.
    @Test func aUserCannotPoseAsARoom() {
        #expect(XMPPSession.invitation(in: stanza("""
            <message from='mallory@example.org/laptop'>
              <x xmlns='http://jabber.org/protocol/muc#user'><invite from='alice@example.org'/></x>
            </message>
            """)) == nil)
    }

    @Test func aDirectInvitationComesFromTheInviter() throws {
        let invitation = try #require(XMPPSession.invitation(in: stanza("""
            <message from='alice@example.org/phone'><x xmlns='jabber:x:conference' jid='cake@rooms.example.org'/></message>
            """)))
        #expect(invitation == .init(room: room, inviter: alice, isDirect: true))
    }

    @Test func aDirectInvitationMustNameARoom() {
        #expect(XMPPSession.invitation(in: stanza("""
            <message from='alice@example.org/phone'><x xmlns='jabber:x:conference' jid='rooms.example.org'/></message>
            """)) == nil)
    }
}

struct InvitationVouchingTests {
    @Test func theirOwnServersServicesVouch() {
        #expect(XMPPSession.vouches(room: room, for: alice))
        #expect(XMPPSession.vouches(room: YapnestKit.JID("cake@a.b.example.org")!, for: alice))
    }

    @Test func otherServersDoNot() {
        #expect(!XMPPSession.vouches(room: YapnestKit.JID("cake@rooms.other.org")!, for: alice))
        #expect(!XMPPSession.vouches(room: YapnestKit.JID("cake@evilexample.org")!, for: alice))
        #expect(!XMPPSession.vouches(room: YapnestKit.JID("cake@rooms.evilexample.org")!, for: alice))
        // A room never lives on a user's own domain: that is another user, who could name anyone.
        #expect(!XMPPSession.vouches(room: YapnestKit.JID("cake@example.org")!, for: alice))
        // A room's server can't speak for a parent domain.
        #expect(!XMPPSession.vouches(room: YapnestKit.JID("cake@example.org")!, for: YapnestKit.JID("bob@rooms.example.org")!))
    }
}

struct AvatarHashTests {
    @Test func acceptsASha1() {
        let hash = String(repeating: "aB3f", count: 10)
        #expect(AvatarStore.isValidHash(hash))
        #expect(AvatarStore.isValidHash(AvatarStore.hash(of: Data("x".utf8))))
    }

    @Test func rejectsAnythingElse() throws {
        for bad in ["../db.sqlite", "", "abc", String(repeating: "g", count: 40), String(repeating: "a", count: 39),
                    String(repeating: "a", count: 41), "../" + String(repeating: "a", count: 37), String(repeating: "a", count: 39) + "/"] {
            #expect(!AvatarStore.isValidHash(bad), "\(bad)")
        }
    }

    @Test func containsOnlyLooksUpValidHashes() throws {
        let store = AvatarStore.temporary()
        let data = try AvatarImages.png(side: 8)
        let hash = AvatarStore.hash(of: data)
        #expect(!store.contains(hash))
        #expect(store.save(data, hash: hash))
        #expect(store.contains(hash))
        #expect(store.contains(hash.uppercased()))
        #expect(!store.contains("../" + hash))
        #expect(!store.contains("../db.sqlite"))
        #expect(!store.contains("zz"))
        try FileManager.default.removeItem(at: store.directory)
    }
}

struct MeActionTests {
    @Test func actionAfterTheCommand() {
        #expect(Message.meAction(in: "/me waves") == "waves")
        #expect(Message.meAction(in: "/me waves  at you") == "waves  at you")
    }

    @Test func notACommandOtherwise() {
        #expect(Message.meAction(in: "/me ") == nil)
        #expect(Message.meAction(in: "/me    ") == nil)
        #expect(Message.meAction(in: "/me") == nil)
        #expect(Message.meAction(in: "/ME waves") == nil)
        #expect(Message.meAction(in: " /me waves") == nil)
        #expect(Message.meAction(in: "hello /me") == nil)
        #expect(Message.meAction(in: "/mean thing") == nil)
    }

    @Test func retractedAndUndecryptableMessagesHaveNone() {
        var message = Message(conversationId: 1, direction: .incoming, sender: alice, body: "/me waves")
        #expect(message.meAction == "waves")
        message.encryption = .omemoUndecryptable
        #expect(message.meAction == nil)
        message.encryption = .none
        message.isRetracted = true
        #expect(message.meAction == nil)
    }
}

struct OutboundFlagsTests {
    private func has(_ message: Martin.Message, _ name: String, _ xmlns: String) -> Bool {
        message.firstChild(name: name, xmlns: xmlns) != nil
    }

    @Test func activeOnlyWhenAsked() {
        let plain = OutboundStanza.text("hi", to: .direct(alice), id: "1")
        #expect(!has(plain, "active", NS.chatStates))
        #expect(has(plain, "request", NS.receipts))
        #expect(has(plain, "markable", NS.markers))

        let active = OutboundStanza.text("hi", to: .direct(alice), id: "2", active: true)
        #expect(has(active, "active", NS.chatStates))
        #expect(has(active, "request", NS.receipts))
        #expect(has(active, "markable", NS.markers))
    }

    @Test func groupMessagesAskForNothing() {
        for active in [false, true] {
            let message = OutboundStanza.text("hi", to: .room(room, status: nil), id: "1", active: active)
            #expect(!has(message, "request", NS.receipts))
            #expect(!has(message, "markable", NS.markers))
            // Chat states are for 1:1 chats; a caller asking for one in a room gets it as asked.
            #expect(has(message, "active", NS.chatStates) == active)
        }
    }

    @Test func chatStateHoldsOnlyTheState() {
        let message = OutboundStanza.chatState(.composing, to: alice)
        #expect(message.element.children.map(\.name) == ["composing"])
        #expect(has(message, "composing", NS.chatStates))
        #expect(message.firstChild(name: "no-store", xmlns: NS.hints) == nil)
        #expect(message.type == .chat)
        #expect(message.to?.stringValue == "alice@example.org")
    }

    @Test func advertisedFeatures() {
        for feature in ["urn:xmpp:receipts", "http://jabber.org/protocol/chatstates", "urn:xmpp:chat-markers:0"] {
            #expect(XMPPSession.messageFeatures.contains(feature), "\(feature)")
        }
    }
}
