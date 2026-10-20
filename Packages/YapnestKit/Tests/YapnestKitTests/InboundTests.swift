import Foundation
import Martin
import GRDB
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

private func parse(_ xml: String, source: InboundMessage.Source = .live, now: Date = Date(timeIntervalSince1970: 0)) -> InboundMessage? {
    InboundMessage(stanza(xml), account: me, source: source, now: now)
}

struct InboundParsingTests {
    @Test func plainMessage() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' to='me@example.org/yapnest' type='chat' id='m1'>
              <body>hello</body>
              <origin-id xmlns='urn:xmpp:sid:0' id='o1'/>
              <stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='s1'/>
              <request xmlns='urn:xmpp:receipts'/>
              <markable xmlns='urn:xmpp:chat-markers:0'/>
              <active xmlns='http://jabber.org/protocol/chatstates'/>
            </message>
            """))
        #expect(m.peer == alice)
        #expect(!m.isOutgoing)
        #expect(m.body == "hello")
        #expect(m.id == "m1")
        #expect(m.originId == "o1")
        #expect(m.serverId == "s1")
        #expect(m.requestsReceipt)
        #expect(m.isMarkable)
        #expect(m.chatState == .active)
    }

    @Test func stanzaIdFromOtherEntityIsIgnored() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='m1'>
              <body>x</body>
              <stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.org' id='spoofed'/>
            </message>
            """))
        #expect(m.serverId == nil)
    }

    @Test func replyFallbackIsStripped() throws {
        // The two quoted lines plus their newlines are 40 code points.
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='m2'>
              <body>&gt; Anna wrote:
            &gt; We should bake a cake 🎂
            Great idea!</body>
              <reply to='me@example.org/yapnest' id='m0' xmlns='urn:xmpp:reply:0'/>
              <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='40'/></fallback>
            </message>
            """))
        #expect(m.body == "Great idea!")
        #expect(m.reply?.id == "m0")
        #expect(m.reply?.to == "me@example.org/yapnest")
        #expect(m.reply?.fallback == "Anna wrote:\nWe should bake a cake 🎂")
    }

    @Test func reactions() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='r1'>
              <reactions id='m0' xmlns='urn:xmpp:reactions:0'><reaction>👍</reaction><reaction>🎉</reaction></reactions>
              <store xmlns='urn:xmpp:hints'/>
            </message>
            """))
        #expect(m.body == nil)
        #expect(m.reactions?.id == "m0")
        #expect(m.reactions?.emojis == ["👍", "🎉"])
    }

    @Test func reactionsAreLimited() throws {
        let kept = ["👍", "👍🏽", "🏳️‍🌈", "👨‍👩‍👧‍👦"]
        let tooMany = (0..<30).map { "<reaction>\(String(UnicodeScalar(0x1F600 + $0)!))</reaction>" }.joined()
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='r2'>
              <reactions id='m0' xmlns='urn:xmpp:reactions:0'>\(kept.map { "<reaction>\($0)</reaction>" }.joined())<reaction>👍</reaction>
              <reaction>ab</reaction><reaction>\(String(repeating: "x", count: 5000))</reaction><reaction>👍👍</reaction></reactions>
            </message>
            """))
        #expect(m.reactions?.emojis == Set(kept))

        let many = try #require(parse("<message from='alice@example.org/phone' type='chat' id='r3'><reactions id='m0' xmlns='urn:xmpp:reactions:0'>\(tooMany)</reactions></message>"))
        #expect(many.reactions?.emojis.count == InboundMessage.Reactions.maxDistinct)
        // The first ones sent are the ones kept.
        #expect(many.reactions?.emojis.contains("😀") == true)
        #expect(many.reactions?.emojis.contains(String(UnicodeScalar(0x1F600 + 25)!)) == false)
    }

    @Test func sentCarbonIsOutgoingToPeer() throws {
        let m = try #require(parse("""
            <message from='me@example.org/laptop' to='alice@example.org' type='chat' id='c1'><body>from laptop</body></message>
            """, source: .carbon(sent: true)))
        #expect(m.isOutgoing)
        #expect(m.peer == alice)
        #expect(m.sender == me)
    }

    @Test func archiveUsesResultIdAndTimestamp() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let m = try #require(parse("""
            <message from='alice@example.org/phone' to='me@example.org' type='chat' id='a1'><body>old</body></message>
            """, source: .archive(serverId: "mam1", timestamp: stamp)))
        #expect(m.serverId == "mam1")
        #expect(m.timestamp == stamp)
    }

    @Test func delayStampIsUsedForOfflineMessages() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='d1'>
              <body>offline</body>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='2024-01-01T10:00:00Z'/>
            </message>
            """, now: now2025))
        #expect(m.timestamp == ISO8601DateFormatter().date(from: "2024-01-01T10:00:00Z"))
    }

    private let now2025 = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func delayed(_ stamp: String, from: String?, source: InboundMessage.Source = .live) throws -> Date {
        let attribute = from.map { " from='\($0)'" } ?? ""
        return try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='d2'>
              <body>hi</body>
              <delay xmlns='urn:xmpp:delay'\(attribute) stamp='\(stamp)'/>
            </message>
            """, source: source, now: now2025)).timestamp
    }

    private func groupDelayed(_ delays: String) throws -> Date {
        let room = RoomContext(jid: YapnestKit.JID("room@muc.example.org")!, nickname: "me")
        let m = try #require(InboundMessage(groupchat: stanza("""
            <message from='room@muc.example.org/bob' type='groupchat' id='g1'><body>hi</body>\(delays)</message>
            """), room: room, account: me, source: .live, now: now2025))
        return m.timestamp
    }

    @Test func aDelayFromOurServerIsKept() throws {
        #expect(try delayed("2001-01-01T00:00:00Z", from: "example.org") == date("2001-01-01T00:00:00Z"))
    }

    @Test func aDelayFromOurOwnAddressIsKept() throws {
        #expect(try delayed("2001-01-01T00:00:00Z", from: "me@example.org") == date("2001-01-01T00:00:00Z"))
        #expect(try delayed("2001-01-01T00:00:00Z", from: "me@example.org/phone") == date("2001-01-01T00:00:00Z"))
    }

    @Test func aDelayFromTheSenderOrWithoutOriginIsIgnored() throws {
        #expect(try delayed("2001-01-01T00:00:00Z", from: nil) == now2025)
        #expect(try delayed("2001-01-01T00:00:00Z", from: "alice@example.org/phone") == now2025)
        #expect(try delayed("2001-01-01T00:00:00Z", from: "other.example") == now2025)
    }

    @Test func aTrustedDelayInTheFutureIsClampedToNow() throws {
        #expect(try delayed("2099-01-01T00:00:00Z", from: "example.org") == now2025)
    }

    @Test func aTrustedDelayAmongOthersIsUsed() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' type='chat' id='d3'>
              <body>hi</body>
              <delay xmlns='urn:xmpp:delay' from='alice@example.org' stamp='2001-01-01T00:00:00Z'/>
              <delay xmlns='urn:xmpp:delay' from='example.org' stamp='2024-01-01T10:00:00Z'/>
            </message>
            """, now: now2025))
        #expect(m.timestamp == date("2024-01-01T10:00:00Z"))
    }

    @Test func aCarbonsForwardedDelayFromTheSenderIsIgnored() throws {
        let m = try #require(parse("""
            <message from='alice@example.org/phone' to='me@example.org' type='chat' id='d4'>
              <body>hi</body>
              <delay xmlns='urn:xmpp:delay' from='alice@example.org' stamp='2001-01-01T00:00:00Z'/>
            </message>
            """, source: .carbon(sent: false), now: now2025))
        #expect(m.timestamp == now2025)
    }

    @Test func aGroupDelayFromTheRoomIsKept() throws {
        #expect(try groupDelayed("<delay xmlns='urn:xmpp:delay' from='room@muc.example.org' stamp='2001-01-01T00:00:00Z'/>") == date("2001-01-01T00:00:00Z"))
    }

    @Test func aGroupDelayFromAnyoneElseIsIgnored() throws {
        #expect(try groupDelayed("<delay xmlns='urn:xmpp:delay' from='bob@example.org' stamp='2001-01-01T00:00:00Z'/>") == now2025)
        #expect(try groupDelayed("<delay xmlns='urn:xmpp:delay' from='example.org' stamp='2001-01-01T00:00:00Z'/>") == now2025)
        #expect(try groupDelayed("<delay xmlns='urn:xmpp:delay' stamp='2001-01-01T00:00:00Z'/>") == now2025)
    }

    @Test func theArchivesOwnTimestampIsNotClamped() throws {
        let ahead = now2025.addingTimeInterval(3600)
        #expect(try delayed("2001-01-01T00:00:00Z", from: nil, source: .archive(serverId: "s", timestamp: ahead)) == ahead)
    }

    @Test func anArchiveResultWithoutATimestampIgnoresAnUntrustedDelay() throws {
        #expect(try delayed("2001-01-01T00:00:00Z", from: nil, source: .archive(serverId: "s", timestamp: nil)) == now2025)
        #expect(try delayed("2099-01-01T00:00:00Z", from: "example.org", source: .archive(serverId: "s", timestamp: nil)) == now2025)
    }

    @Test func groupchatIsIgnoredForNow() {
        #expect(parse("<message from='room@muc.example.org/nick' type='groupchat'><body>x</body></message>") == nil)
    }
}

struct IngestTests {
    let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    private func ingest(_ xml: String, source: InboundMessage.Source = .live) throws -> IngestResult {
        try db.ingest(#require(parse(xml, source: source)))
    }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    @Test func liveThenArchiveIsStoredOnce() throws {
        let first = try ingest("<message from='alice@example.org/p' type='chat' id='m1'><body>hi</body><origin-id xmlns='urn:xmpp:sid:0' id='m1'/></message>")
        #expect(first.newMessage != nil)
        let second = try ingest(
            "<message from='alice@example.org/p' to='me@example.org' type='chat' id='m1'><body>hi</body><origin-id xmlns='urn:xmpp:sid:0' id='m1'/></message>",
            source: .archive(serverId: "s1", timestamp: nil),
        )
        #expect(second.newMessage == nil)
        #expect(try messages().count == 1)
        #expect(try messages().first?.serverId == "s1")
    }

    @Test func chatStateAloneDoesNotCreateConversation() throws {
        let result = try ingest("<message from='alice@example.org/p' type='chat'><composing xmlns='http://jabber.org/protocol/chatstates'/></message>")
        #expect(result.chatState == .composing)
        #expect(result.conversationId == nil)
        #expect(try db.chatList().isEmpty)
    }

    @Test func receiptsMarkersAndReactionsUpdateOutgoing() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "cake?", status: .sent, remoteId: "out1", originId: "out1"))

        try ingest("<message from='alice@example.org/p' type='chat'><received xmlns='urn:xmpp:receipts' id='out1'/></message>")
        #expect(try messages()[0].status == .delivered)

        try ingest("<message from='alice@example.org/p' type='chat'><displayed xmlns='urn:xmpp:chat-markers:0' id='out1'/></message>")
        #expect(try messages()[0].status == .displayed)

        try ingest("<message from='alice@example.org/p' type='chat' id='r'><reactions id='out1' xmlns='urn:xmpp:reactions:0'><reaction>🎂</reaction></reactions></message>")
        let reactions = try db.reader.read { try Reaction.fetchAll($0) }
        #expect(reactions.map(\.emoji) == ["🎂"])
        #expect(reactions.first?.sender == alice)
    }

    @Test func errorFailsOutgoingMessage() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "x", status: .sent, remoteId: "out1"))
        try ingest("<message from='alice@example.org' type='error' id='out1'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>")
        #expect(try messages()[0].status == .failed)
    }

    @Test func sentCarbonMarksConversationRead() throws {
        try ingest("<message from='alice@example.org/p' type='chat' id='m1'><body>hi</body></message>")
        #expect(try db.chatList()[0].unreadCount == 1)
        try ingest("<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='c1'><body>hey</body></message>", source: .carbon(sent: true))
        let list = try db.chatList()
        #expect(list[0].unreadCount == 0)
        #expect(list[0].lastMessage?.direction == .outgoing)
    }

    @Test func replyIsStoredWithFallback() throws {
        try ingest("""
            <message from='alice@example.org/p' type='chat' id='m2'><body>&gt; hi
            yes</body><reply id='m0' xmlns='urn:xmpp:reply:0'/><fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='5'/></fallback></message>
            """)
        let m = try messages()[0]
        #expect(m.body == "yes")
        #expect(m.replyToId == "m0")
        #expect(m.replyFallback == "hi")
    }
}

struct ErrorParsingTests {
    /// ejabberd puts the text first; the condition must still be found
    /// (fixed in our copy of Martin).
    @Test func conditionIsReadWhateverTheOrder() {
        let iq = Stanza.from(element: Element.from(string: """
            <iq type='error' id='1'><error type='cancel'><text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Node not found</text><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>
            """)!)
        #expect(iq.error == .item_not_found)
    }
}
