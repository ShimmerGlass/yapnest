import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

/// XEP-0372 mentions.
struct MentionTests {
    @Test func findsNicknamesAsWordsInCodePoints() {
        let found = Mentions.find(["anna", "anna-lou", "bob"], in: "🎂 Anna-Lou and anna, not bobby, @bob!")
        #expect(found.map(\.nick) == ["anna-lou", "anna", "bob"])
        // The cake is one code point: "Anna-Lou" starts at 2.
        #expect(found.map(\.begin) == [2, 15, 33])
        #expect(found.map(\.end) == [10, 19, 36])
    }

    @Test func referencesCountTheQuoteToo() throws {
        let quote = OutboundStanza.QuotedMessage(id: "r1", author: "\(room)/anna", text: "cake?")
        let mention = OutboundStanza.Mention(uri: "xmpp:\(room)/anna", begin: 4, end: 8)
        let out = OutboundStanza.text("yes anna", to: .room(room, status: nil), id: "m1", replyingTo: quote, mentions: [mention])
        let reference = try #require(out.firstChild(name: "reference", xmlns: "urn:xmpp:reference:0"))
        let body = Array(try #require(out.body).unicodeScalars)
        let begin = try #require(reference.getAttribute("begin").flatMap(Int.init))
        let end = try #require(reference.getAttribute("end").flatMap(Int.init))
        #expect(String(String.UnicodeScalarView(body[begin..<end])) == "anna")
        #expect(reference.getAttribute("type") == "mention")
    }

    @Test func groupMessageMentioningUs() throws {
        let context = RoomContext(jid: room, nickname: "me")
        func parse(_ uri: String) throws -> InboundMessage {
            try #require(InboundMessage(groupchat: stanza("""
                <message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>hey you</body>\
                <reference xmlns='urn:xmpp:reference:0' type='mention' begin='4' end='7' uri='\(uri)'/></message>
                """), room: context, account: me, source: .live))
        }
        #expect(try parse("xmpp:me@example.org").mentionsMe)
        #expect(try parse("xmpp:cake@rooms.example.org/me").mentionsMe)
        #expect(try parse("xmpp:cake@rooms.example.org/bob").mentionsMe == false)
    }

    @Test func mentionsNotifyWhenOnlyMentionsShould() throws {
        let db = try AppDatabase.inMemory()
        let group = try db.joinGroupChat(room, nickname: "me")
        try db.updateGroupChat(room) { $0.notify = .onMention }
        _ = try db.claimNotifications()
        let context = RoomContext(jid: room, nickname: "me")
        // Names us by our address only: no nickname in the text.
        try db.ingest(try #require(InboundMessage(groupchat: stanza("""
            <message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>look at this, boss</body>\
            <reference xmlns='urn:xmpp:reference:0' type='mention' begin='14' end='18' uri='xmpp:me@example.org'/></message>
            """), room: context, account: me, source: .live)))
        try db.ingest(try #require(InboundMessage(groupchat: stanza("""
            <message from='cake@rooms.example.org/anna' type='groupchat' id='m2'><body>unrelated</body></message>
            """), room: context, account: me, source: .live)))
        let notified = try db.claimNotifications()
        #expect(notified.map(\.body) == ["look at this, boss", "unrelated"])
        #expect(notified.map(\.isQuiet) == [false, true])
        #expect(notified.first?.peer == group.jid)
        // The quiet one still says where it's from.
        #expect(notified.last?.subtitle == "anna")
    }

    @Test func groupsThatNeverNotifyStillClaimQuietly() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.joinGroupChat(room, nickname: "me")
        try db.updateGroupChat(room) { $0.notify = .never }
        _ = try db.claimNotifications()
        let context = RoomContext(jid: room, nickname: "me")
        try db.ingest(try #require(InboundMessage(groupchat: stanza("""
            <message from='cake@rooms.example.org/anna' type='groupchat' id='m1'><body>hi me</body></message>
            """), room: context, account: me, source: .live)))
        let notified = try db.claimNotifications()
        #expect(notified.map(\.isQuiet) == [true])
        #expect(notified.first?.isGroup == true)
        #expect(notified.first?.subtitle == "anna")
        #expect(try db.claimNotifications().isEmpty)

        try db.updateGroupChat(room) { $0.notify = .always }
        try db.ingest(try #require(InboundMessage(groupchat: stanza("""
            <message from='cake@rooms.example.org/anna' type='groupchat' id='m2'><body>loud</body></message>
            """), room: context, account: me, source: .live)))
        #expect(try db.claimNotifications().map(\.isQuiet) == [false])
    }
}
