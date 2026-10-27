import Foundation
import Martin
import GRDB
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

private let context = RoomContext(jid: room, nickname: "me", occupants: ["anna": alice], isNonAnonymous: true)

private func parse(_ xml: String, source: InboundMessage.Source = .live) -> InboundMessage? {
    InboundMessage(groupchat: stanza(xml), room: context, account: me, source: source, now: Date(timeIntervalSince1970: 0))
}

struct GroupChatParsingTests {
    @Test func occupantMessageUsesRealAddressAndRoomId() throws {
        let m = try #require(parse("""
            <message from='cake@rooms.example.org/anna' type='groupchat' id='m1'>
              <body>hello all</body>
              <stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r1'/>
              <stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='mine'/>
            </message>
            """))
        #expect(m.peer == room)
        #expect(m.sender == alice)
        #expect(m.nick == "anna")
        #expect(!m.isOutgoing)
        #expect(m.serverId == "r1")
        #expect(m.isGroupChat)
        #expect(!m.requestsReceipt)
    }

    @Test func unknownOccupantSpeaksAsTheRoom() throws {
        let m = try #require(parse("<message from='cake@rooms.example.org/bob' type='groupchat' id='m1'><body>hi</body></message>"))
        #expect(m.sender == room)
        #expect(m.nick == "bob")
    }

    @Test func ourEchoIsOutgoing() throws {
        let m = try #require(parse("<message from='cake@rooms.example.org/me' type='groupchat' id='o1'><body>mine</body></message>"))
        #expect(m.isOutgoing)
        #expect(m.sender == me)
    }

    @Test func archiveCarriesRealAddress() throws {
        let m = try #require(parse("""
            <message from='cake@rooms.example.org/old-nick' type='groupchat' id='m1'>
              <body>from the past</body>
              <x xmlns='http://jabber.org/protocol/muc#user'><item jid='alice@example.org/phone'/></x>
            </message>
            """, source: .archive(serverId: "r9", timestamp: nil)))
        #expect(m.sender == alice)
        #expect(m.serverId == "r9")
    }

    @Test func subjectWithoutBody() throws {
        let m = try #require(parse("<message from='cake@rooms.example.org/anna' type='groupchat' id='s'><subject>Baking</subject></message>"))
        #expect(m.subject == "Baking")
        #expect(m.body == nil)
        let cleared = try #require(parse("<message from='cake@rooms.example.org/anna' type='groupchat' id='s'><subject/></message>"))
        #expect(cleared.subject == "")
    }

    @Test func roomAnnouncementsAreIgnored() {
        #expect(parse("<message from='cake@rooms.example.org' type='groupchat' id='a'><body>Room is now members-only</body></message>") == nil)
        #expect(parse("<message from='other@rooms.example.org/anna' type='groupchat' id='a'><body>wrong room</body></message>") == nil)
    }

    @Test func occupantIdOnlyFromRoomsThatVouchForIt() throws {
        let xml = "<message from='cake@rooms.example.org/bob' type='groupchat' id='m1'><body>hi</body><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/></message>"
        #expect(try #require(parse(xml)).occupantId == nil)
        let trusting = RoomContext(jid: room, nickname: "me", trustsOccupantIds: true)
        let m = try #require(InboundMessage(groupchat: stanza(xml), room: trusting, account: me, source: .live))
        #expect(m.occupantId == "occ-bob")
        #expect(m.author.occupantId == "occ-bob")
    }

    @Test func ourOccupantIdMarksOurEchoUnderAnotherNick() throws {
        // We were renamed since: the occupant id still says it's us.
        let context = RoomContext(jid: room, nickname: "me_", trustsOccupantIds: true, ownOccupantId: "occ-me")
        let mine = "<message from='cake@rooms.example.org/me' type='groupchat' id='o1'><body>mine</body><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/></message>"
        #expect(try #require(InboundMessage(groupchat: stanza(mine), room: context, account: me, source: .live)).isOutgoing)
        let impostor = "<message from='cake@rooms.example.org/me_' type='groupchat' id='o2'><body>hi</body><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-x'/></message>"
        #expect(try #require(InboundMessage(groupchat: stanza(impostor), room: context, account: me, source: .live)).isOutgoing == false)
    }

    @Test func plainParserRefusesGroupChat() {
        #expect(InboundMessage(stanza("<message from='cake@rooms.example.org/anna' type='groupchat'><body>x</body></message>"), account: me, source: .live) == nil)
    }
}

@Suite struct GroupChatStorageTests {
    let db: AppDatabase
    let group: GroupChat

    init() throws {
        db = try AppDatabase.inMemory()
        group = try db.joinGroupChat(room, nickname: "me", name: "Cake")
    }

    @discardableResult
    private func ingest(_ xml: String, source: InboundMessage.Source = .live, occupants: [String: YapnestKit.JID] = ["anna": alice], trustsOccupantIds: Bool = false) throws -> IngestResult {
        let context = RoomContext(jid: room, nickname: "me", occupants: occupants, trustsOccupantIds: trustsOccupantIds)
        return try db.ingest(try #require(InboundMessage(groupchat: stanza(xml), room: context, account: me, source: source)))
    }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    @Test func joiningCreatesAGroupConversation() throws {
        let list = try db.chatList()
        #expect(list.count == 1)
        #expect(list[0].conversation.kind == .groupchat)
        #expect(list[0].title == "Cake")
        #expect(list[0].conversation.isEncrypted == false)
    }

    @Test func messageIsStoredWithNickname() throws {
        try ingest("<message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>hi</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r1'/></message>")
        let m = try #require(try messages().first)
        #expect(m.nick == "anna")
        #expect(m.sender == alice)
        #expect(m.serverId == "r1")
    }

    @Test func groupMessagesNeedTheGroup() throws {
        let other = RoomContext(jid: JID("other@rooms.example.org")!, nickname: "me")
        let inbound = try #require(InboundMessage(groupchat: stanza("<message from='other@rooms.example.org/x' type='groupchat' id='m'><body>hi</body></message>"), room: other, account: me, source: .live))
        #expect(try db.ingest(inbound).newMessage == nil)
        #expect(try db.chatList().count == 1)
    }

    @Test func echoConfirmsOurMessage() throws {
        let sent = try db.insert(YapnestKit.Message(conversationId: group.conversationId, direction: .outgoing, sender: me, nick: "me", body: "mine", status: .sent, remoteId: "o1", originId: "o1"))
        let result = try ingest("<message from='cake@rooms.example.org/me' type='groupchat' id='o1'><body>mine</body><origin-id xmlns='urn:xmpp:sid:0' id='o1'/><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r5'/></message>")
        #expect(result.newMessage == nil)
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(stored[0].id == sent.id)
        #expect(stored[0].serverId == "r5")
    }

    @Test func reactionsByStanzaIdAndNickname() throws {
        try ingest("<message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>cake?</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r1'/></message>")
        // Two anonymous occupants share the room's address.
        try ingest("<message from='cake@rooms.example.org/bob' type='groupchat' id='x1'><reactions id='r1' xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction></reactions></message>", occupants: [:])
        try ingest("<message from='cake@rooms.example.org/carol' type='groupchat' id='x2'><reactions id='r1' xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction></reactions></message>", occupants: [:])
        try ingest("<message from='cake@rooms.example.org/bob' type='groupchat' id='x3'><reactions id='r1' xmlns='urn:xmpp:reactions:0'><reaction>🎂</reaction></reactions></message>", occupants: [:])
        let reactions = try db.reader.read { try Reaction.order(Column("nick")).fetchAll($0) }
        #expect(reactions.map(\.nick) == ["bob", "carol"])
        #expect(reactions.map(\.emoji) == ["🎂", "👍"])
        #expect(reactions.allSatisfy { $0.sender == room })
    }

    @Test func reactionsFollowOccupantIdAcrossNicknames() throws {
        try ingest("<message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>cake?</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r1'/></message>")
        try ingest("<message from='cake@rooms.example.org/bob' type='groupchat' id='x1'><reactions id='r1' xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction></reactions><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/></message>", occupants: [:], trustsOccupantIds: true)
        // Bob renamed himself, then changed his reaction.
        try ingest("<message from='cake@rooms.example.org/robert' type='groupchat' id='x2'><reactions id='r1' xmlns='urn:xmpp:reactions:0'><reaction>🎂</reaction></reactions><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/></message>", occupants: [:], trustsOccupantIds: true)
        let reactions = try db.reader.read { try Reaction.fetchAll($0) }
        #expect(reactions.map(\.emoji) == ["🎂"])
        #expect(reactions.first?.nick == "robert")
        #expect(reactions.first?.occupantId == "occ-bob")
    }

    @Test func ourEchoedReactionReplacesTheOneWeStored() throws {
        try ingest("<message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>cake?</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r1'/></message>")
        // Stored on sending, before we knew our occupant id.
        try db.setReactions(["👍"], from: Author(jid: me, nick: "me"), conversationId: group.conversationId, messageRef: "r1")
        try ingest("<message from='cake@rooms.example.org/me' type='groupchat' id='x1'><reactions id='r1' xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction></reactions><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/></message>", trustsOccupantIds: true)
        let reactions = try db.reader.read { try Reaction.fetchAll($0) }
        #expect(reactions.count == 1)
        #expect(reactions.first?.occupantId == "occ-me")
    }

    @Test func subjectIsStored() throws {
        try ingest("<message from='cake@rooms.example.org/anna' type='groupchat' id='s'><subject>Baking</subject></message>")
        #expect(try db.groupChat(room)?.subject == "Baking")
        #expect(try messages().isEmpty)
    }

    @Test func privateRoomEncryptsUntilWeWrite() throws {
        try db.setRoomInfo(room, name: "Cake club", isMembersOnly: true, isNonAnonymous: true)
        #expect(try db.chatList()[0].conversation.isEncrypted)
        #expect(try db.groupChat(room)?.name == "Cake club")
        try db.setRoomInfo(room, name: nil, isMembersOnly: false, isNonAnonymous: true)
        #expect(try db.chatList()[0].conversation.isEncrypted == false)
    }

    @Test func rejoiningKeepsHistory() throws {
        try ingest("<message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>hi</body></message>")
        try db.updateGroupChat(room) { $0.hasLeft = true }
        let again = try db.joinGroupChat(room, nickname: "me2")
        #expect(again.hasLeft == false)
        #expect(again.nickname == "me2")
        #expect(again.name == "Cake")
        #expect(try messages().count == 1)
    }

    @Test func migrationAddsRoomPasswordsToWhatWasStored() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v38-action-errors")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('room@rooms.example.org', 'groupchat', 0)")
            try db.execute(sql: "INSERT INTO groupChat (conversationId, jid, nickname) VALUES (1, 'room@rooms.example.org', 'me')")
            try db.execute(sql: "INSERT INTO groupInvitation (room, inviter, receivedAt) VALUES ('x@rooms.example.org', 'a@example.org', 0)")
        }
        try AppDatabase.migrator.migrate(queue)
        #expect(try queue.read { try GroupChat.fetchAll($0) }.map(\.password) == [nil])
        #expect(try queue.read { try GroupInvitation.fetchAll($0) }.map(\.password) == [nil])
    }

    @Test func migrationKeepsReactions() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6-attachments")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('a@example.org', 'chat', 0)")
            try db.execute(sql: """
                INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption)
                VALUES (1, 'incoming', 'a@example.org', 'hi', 0, 'received', 0, 'none')
                """)
            try db.execute(sql: "INSERT INTO reaction (messageId, sender, emoji) VALUES (1, 'a@example.org', '👍')")
        }
        try AppDatabase.migrator.migrate(queue)
        let reactions = try queue.read { try Reaction.fetchAll($0) }
        #expect(reactions == [Reaction(messageId: 1, sender: JID("a@example.org")!, emoji: "👍")])
        // Still cleaned up with its message.
        try queue.write { db in try db.execute(sql: "PRAGMA foreign_keys = ON; DELETE FROM message") }
        #expect(try queue.read { try Reaction.fetchCount($0) } == 0)
    }
}

struct RoomJoinTests {
    @Test func joiningARoomChattedWithBeforeMakesItAGroup() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.conversation(with: room)
        try db.joinGroupChat(room, nickname: "me")
        let conversation = try #require(db.reader.read { try Conversation.filter(Column("peer") == room).fetchOne($0) })
        #expect(conversation.kind == .groupchat)
        #expect(!conversation.isEncrypted)
    }
}

struct RoomResendTests {
    private func message(_ id: Int64) -> YapnestKit.Message {
        var message = YapnestKit.Message(conversationId: 1, direction: .outgoing, sender: me, body: "m\(id)")
        message.id = id
        return message
    }

    @Test func roomsWithAnArchiveResendWhatDidNotComeBack() {
        let resent = XMPPSession.roomResends(hasArchive: true, reachedEnd: true, unconfirmed: [message(1), message(2)], pending: [message(2), message(3)])
        #expect(resent.map(\.id) == [3, 1, 2])
    }

    @Test func roomsWithoutAnArchiveResendOnlyWhatWasNeverSent() {
        let resent = XMPPSession.roomResends(hasArchive: false, reachedEnd: true, unconfirmed: [message(1), message(2)], pending: [message(2), message(3)])
        #expect(resent.map(\.id) == [2, 3])
    }

    /// The echo may be in what's left of the archive.
    @Test func aCatchUpThatStoppedShortResendsOnlyWhatWasNeverSent() {
        let resent = XMPPSession.roomResends(hasArchive: true, reachedEnd: false, unconfirmed: [message(1), message(2)], pending: [message(2), message(3)])
        #expect(resent.map(\.id) == [2, 3])
    }
}

struct BookmarkNotifyTests {
    private func bookmark(_ xml: String) -> Bookmark? {
        Bookmark(id: room.description, payload: Element.from(string: xml))
    }

    @Test func phoneSettingWinsOverEveryone() throws {
        let b = try #require(bookmark("""
            <conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'>
              <extensions>
                <notify xmlns='urn:xmpp:notification-settings:1'>
                  <never identity-category='client' identity-type='pc'/>
                  <on-mention identity-category='client' identity-type='phone'/>
                  <always/>
                </notify>
              </extensions>
            </conference>
            """))
        #expect(b.notify == .onMention)
        #expect(try #require(bookmark("<conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/>")).notify == .always)
    }

    @Test func roundTrips() throws {
        for notify in GroupChat.Notify.allCases {
            let published = Bookmark(jid: room, name: "Cake", autojoin: true, nick: "me", notify: notify).element
            #expect(Bookmark(id: room.description, payload: published)?.notify == notify)
        }
    }
}

struct LegacyBookmarkTests {
    @Test func theListIsReadFromConversationsStyleStorage() throws {
        let storage = try #require(Element.from(string: """
            <storage xmlns='storage:bookmarks'>
              <conference jid='cake@rooms.example.org' name='Cake' autojoin='true'><nick>me</nick></conference>
              <conference jid='tea@rooms.example.org' autojoin='false'/>
              <url name='site' url='https://example.org'/>
            </storage>
            """))
        let list = Bookmark.legacyList(in: storage)
        #expect(list.map(\.jid.description) == ["cake@rooms.example.org", "tea@rooms.example.org"])
        #expect(list.map(\.autojoin) == [true, false])
        #expect(list.first?.nick == "me")
        #expect(list.first?.name == "Cake")
    }

    @Test func roundTrips() throws {
        let written = Bookmark(jid: room, name: "Cake", autojoin: true, nick: "me").legacyElement
        let read = try #require(Bookmark(legacy: written))
        #expect(read.jid == room && read.name == "Cake" && read.autojoin && read.nick == "me")
    }
}

/// XEP-0410's reading of a self-ping's answer.
struct SelfPingTests {
    @Test func answersMeanWhatTheXEPSays() {
        #expect(XMPPSession.selfPingResult(.success(())) == .joined)
        #expect(XMPPSession.selfPingResult(.failure(.service_unavailable)) == .joined)
        #expect(XMPPSession.selfPingResult(.failure(.feature_not_implemented)) == .joined)
        #expect(XMPPSession.selfPingResult(.failure(.item_not_found)) == .joined)
        #expect(XMPPSession.selfPingResult(.failure(.remote_server_timeout)) == .unknown)
        #expect(XMPPSession.selfPingResult(.failure(.remote_server_not_found)) == .unknown)
        #expect(XMPPSession.selfPingResult(.failure(.not_acceptable)) == .notJoined)
        #expect(XMPPSession.selfPingResult(.failure(.bad_request)) == .notJoined)
    }
}
