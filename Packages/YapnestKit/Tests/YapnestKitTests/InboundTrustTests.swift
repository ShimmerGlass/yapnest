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

private func parse(_ xml: String, encryption: YapnestKit.Message.Encryption = .none) -> InboundMessage? {
    InboundMessage(stanza(xml), account: me, source: .live, encryption: encryption)
}

private func message(_ body: String, fallback: String, encryption: YapnestKit.Message.Encryption) throws -> InboundMessage {
    try #require(parse("""
        <message from='alice@example.org/phone' type='chat' id='m1'><body>\(body)</body>
          <reply id='m0' xmlns='urn:xmpp:reply:0'/>
          <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'>\(fallback)</fallback>
        </message>
        """, encryption: encryption))
}

struct DelayTrustTests {
    @Test func theLatestTrustedStampWins() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = try #require(InboundMessage(stanza("""
            <message from='alice@example.org/phone' type='chat' id='d'><body>hi</body>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='2001-01-01T00:00:00Z'/>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='2024-01-01T10:00:00Z'/>
            </message>
            """), account: me, source: .live, now: now))
        #expect(m.timestamp == ISO8601DateFormatter().date(from: "2024-01-01T10:00:00Z"))
        #expect(m.isDelayed)
    }

    @Test func aMessageWithoutATrustedDelayIsntDelayed() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='d'><body>hi</body>
              <delay xmlns='urn:xmpp:delay' from='alice@example.org' stamp='2001-01-01T00:00:00Z'/>
            </message>
            """))
        #expect(!m.isDelayed)
    }

    @Test func aForgedDelayIsntBackdatedAndStillNotifies() throws {
        let db = try AppDatabase.inMemory()
        let chat = try db.conversation(with: alice)
        let newest = Date().addingTimeInterval(-3600)
        try db.insert(YapnestKit.Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "earlier", timestamp: newest, remoteId: "e"))
        #expect(try db.claimNotifications().isEmpty)

        let forged = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='f'><body>send the code</body>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='2001-01-01T00:00:00Z'/>
            </message>
            """))
        let stored = try #require(try db.ingest(forged).newMessage)
        #expect(stored.timestamp >= newest)
        #expect(try db.claimNotifications().map(\.body) == ["send the code"])
    }

    @Test func aGenuineOfflineMessageKeepsItsStamp() throws {
        let db = try AppDatabase.inMemory()
        let chat = try db.conversation(with: alice)
        let stamp = Date().addingTimeInterval(-600)
        try db.insert(YapnestKit.Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "earlier", timestamp: stamp.addingTimeInterval(-3600), remoteId: "e"))
        let offline = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='o'><body>while away</body>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='\(ISO8601DateFormatter().string(from: stamp))'/>
            </message>
            """))
        let stored = try #require(try db.ingest(offline).newMessage)
        #expect(abs(stored.timestamp.timeIntervalSince(stamp)) < 1)
    }
}

/// A stream resumed after the app was away replays what the server held for
/// it with a `<delay>` on each stanza. On a carbon that is the wrapper's, so
/// a message sent from the Mac meanwhile would take the time the phone woke.
struct CarbonDelayTests {
    @Test func aReplayedCarbonKeepsTheServersStamp() async throws {
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database)
        let stamp = Date().addingTimeInterval(-3600)
        session.handleTopLevel(parseStanza("""
            <message from='me@example.org' to='me@example.org/phone'>
              <sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>
                <message from='me@example.org/mac' to='alice@example.org' type='chat' id='c1'><body>from the Mac</body></message>
              </forwarded></sent>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='\(ISO8601DateFormatter().string(from: stamp))'/>
            </message>
            """))
        let deadline = Date().addingTimeInterval(5)
        var stored: YapnestKit.Message?
        while stored == nil, Date() < deadline {
            stored = try await database.reader.read { try YapnestKit.Message.filter(Column("body") == "from the Mac").fetchOne($0) }
            if stored == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let message = try #require(stored)
        #expect(abs(message.timestamp.timeIntervalSince(stamp)) < 1)
    }
}

struct ReplyFallbackTrustTests {
    // "> hi\n" is five code points.
    private let quote = "<body start='0' end='5'/>"

    @Test func aLegitQuoteIsStrippedFromAnEncryptedBody() throws {
        let m = try message("&gt; hi\nsure", fallback: quote, encryption: .omemo)
        #expect(m.body == "sure")
        #expect(m.reply?.fallback == "hi")
    }

    @Test func aQuoteRangeThatEndsMidLineIsIgnoredOnAnEncryptedBody() throws {
        let m = try message("&gt; hi\nsure", fallback: "<body start='0' end='4'/>", encryption: .omemo)
        #expect(m.body == "&gt; hi\nsure".replacingOccurrences(of: "&gt;", with: ">"))
        #expect(m.reply?.fallback == nil)
    }

    @Test func aForgedMidBodyRangeIsIgnoredOnAnEncryptedBody() throws {
        let m = try message("I do not agree", fallback: "<body start='5' end='9'/>", encryption: .omemo)
        #expect(m.body == "I do not agree")
        #expect(m.reply?.id == "m0")
    }

    @Test func aRangeOverPlainTextFromTheStartIsIgnoredOnAnEncryptedBody() throws {
        let m = try message("I do not agree", fallback: "<body start='0' end='5'/>", encryption: .omemo)
        #expect(m.body == "I do not agree")
    }

    @Test func aWholeBodyFallbackKeepsTheEncryptedBody() throws {
        #expect(try message("I do not agree", fallback: "", encryption: .omemo).body == "I do not agree")
        #expect(try message("I do not agree", fallback: "<body start='0' end='14'/>", encryption: .omemo).body == "I do not agree")
    }

    @Test func plaintextKeepsItsBehaviour() throws {
        #expect(try message("I do not agree", fallback: "<body start='5' end='9'/>", encryption: .none).body == "I do agree")
        #expect(try message("I do not agree", fallback: "", encryption: .none).body == nil)
    }
}

struct BodyCapTests {
    @Test func anOversizedBodyIsCutBetweenCharacters() throws {
        let text = String(repeating: "👨‍👩‍👧", count: InboundMessage.maxBodyCharacters)
        let m = try #require(parse("<message from='alice@example.org/phone' type='chat' id='b'><body>\(text)</body></message>"))
        #expect(m.body?.count == InboundMessage.maxBodyCharacters)
        #expect(m.body?.hasSuffix("👨‍👩‍👧") == true)
    }

    @Test func aBodyUnderTheCapIsUntouched() throws {
        let m = try #require(parse("<message from='alice@example.org/phone' type='chat' id='b'><body>hello</body></message>"))
        #expect(m.body == "hello")
    }
}

struct ArchivedGroupSenderTests {
    let db: AppDatabase
    let group: GroupChat

    init() throws {
        db = try AppDatabase.inMemory()
        group = try db.joinGroupChat(room, nickname: "me", name: "Cake")
    }

    private func item(_ extra: String = "", nick: String = "me", source: InboundMessage.Source, occupants: [String: YapnestKit.JID] = [:]) throws -> InboundMessage {
        let context = RoomContext(jid: room, nickname: "me", occupants: occupants, trustsOccupantIds: true, ownOccupantId: "occ-me", isNonAnonymous: true)
        return try #require(InboundMessage(groupchat: stanza("""
            <message from='cake@rooms.example.org/\(nick)' type='groupchat' id='x1'><body>hi</body>
              <origin-id xmlns='urn:xmpp:sid:0' id='orig1'/>\(extra)
            </message>
            """), room: context, account: me, source: source))
    }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    @Test func anArchivedItemFromOurNickWithoutAnAddressIsIncoming() throws {
        let m = try item(source: .archive(serverId: "r1", timestamp: nil))
        #expect(!m.isOutgoing)
        #expect(m.sender == room)
        #expect(m.nick == "me")
        let stored = try #require(try db.ingest(m).newMessage)
        #expect(stored.direction == .incoming)
    }

    @Test func anArchivedItemIsntMatchedAgainstCurrentOccupants() throws {
        let m = try item(nick: "anna", source: .archive(serverId: "r1", timestamp: nil), occupants: ["anna": alice])
        #expect(m.sender == room)
    }

    @Test func anArchivedItemWithOurAddressOrOccupantIdIsOurs() throws {
        let addressed = try item("<x xmlns='http://jabber.org/protocol/muc#user'><item jid='me@example.org/phone'/></x>", nick: "old", source: .archive(serverId: "r1", timestamp: nil))
        #expect(addressed.isOutgoing)
        let vouched = try item("<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/>", nick: "old", source: .archive(serverId: "r2", timestamp: nil))
        #expect(vouched.isOutgoing)
    }

    @Test func aLiveItemFromOurNickIsStillOurs() throws {
        #expect(try item(source: .live).isOutgoing)
    }

    @Test func anArchivedCopyOfAMessageWeSentIsntStoredTwice() throws {
        let sent = try db.insert(YapnestKit.Message(conversationId: group.conversationId, direction: .outgoing, sender: me, nick: "me", body: "hi", status: .sent, remoteId: "x1", originId: "orig1"))
        let result = try db.ingest(try item(source: .archive(serverId: "r1", timestamp: nil)))
        #expect(result.newMessage == nil)
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(stored[0].id == sent.id)
        #expect(stored[0].serverId == "r1")
        #expect(stored[0].direction == YapnestKit.Message.Direction.outgoing)
    }
}

struct SearchMarkerTrustTests {
    @Test func aSenderCannotForgeAMatchMarkerInABody() throws {
        let m = try #require(parse("<message from='alice@example.org/phone' type='chat' id='m'><body>he\u{E000}llo wor\u{E001}ld</body></message>"))
        #expect(m.body == "hello world")
    }
}
