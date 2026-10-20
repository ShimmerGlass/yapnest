import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

/// XEP-0308 corrections and XEP-0424 retractions.
struct CorrectionTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @discardableResult
    private func ingest(_ xml: String, source: InboundMessage.Source = .live, at date: Date = Date(timeIntervalSince1970: 100)) throws -> IngestResult {
        try db.ingest(try #require(InboundMessage(stanza(xml), account: me, source: source, now: date)))
    }

    @discardableResult
    private func ingestGroup(_ xml: String, occupants: [String: YapnestKit.JID] = [:], trustsOccupantIds: Bool = false, source: InboundMessage.Source = .live) throws -> IngestResult {
        let context = RoomContext(jid: room, nickname: "me", occupants: occupants, trustsOccupantIds: trustsOccupantIds)
        return try db.ingest(try #require(InboundMessage(groupchat: stanza(xml), room: context, account: me, source: source)))
    }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    // MARK: Corrections

    @Test func correctionReplacesTheText() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>see you at 5</body></message>")
        let result = try ingest("""
            <message from='alice@example.org/phone' type='chat' id='m2'><body>see you at 6 https://example.org</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>
            """, at: Date(timeIntervalSince1970: 200))
        #expect(result.newMessage == nil)
        #expect(result.editedMessage?.body == "see you at 6 https://example.org")
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(stored[0].body == "see you at 6 https://example.org")
        #expect(stored[0].editedAt == Date(timeIntervalSince1970: 200))
        #expect(stored[0].link == "https://example.org")

        // A second correction still names the original.
        try ingest("<message from='alice@example.org/phone' type='chat' id='m3'><body>at 7</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>", at: Date(timeIntervalSince1970: 300))
        #expect(try messages()[0].body == "at 7")
        // An archive replaying an older one changes nothing.
        try ingest("<message from='alice@example.org/phone' type='chat' id='m2'><body>at 6</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>",
                   source: .archive(serverId: "s2", timestamp: Date(timeIntervalSince1970: 200)))
        #expect(try messages()[0].body == "at 7")
    }

    @Test func onlyTheSenderMayCorrect() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "mine", status: .sent, remoteId: "o1", originId: "o1"))
        try ingest("<message from='alice@example.org/phone' type='chat' id='x'><body>hijacked</body><replace xmlns='urn:xmpp:message-correct:0' id='o1'/></message>")
        let stored = try messages()
        #expect(stored.first { $0.remoteId == "o1" }?.body == "mine")
        #expect(stored.first { $0.remoteId == "o1" }?.editedAt == nil)
    }

    @Test func ourCorrectionFromAnotherDevice() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "teh cake", status: .sent, remoteId: "o1", originId: "o1"))
        // The unwrapped carbon of our own correction, sent to alice.
        let carbon = stanza("<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='o2'><body>the cake</body><replace xmlns='urn:xmpp:message-correct:0' id='o1'/></message>")
        try db.ingest(try #require(InboundMessage(carbon, account: me, source: .carbon(sent: true))))
        #expect(try messages().first { $0.remoteId == "o1" }?.body == "the cake")
    }

    @Test func correctionOfSomethingWeNeverGotIsKept() throws {
        let result = try ingest("<message from='alice@example.org/phone' type='chat' id='m2'><body>fixed</body><replace xmlns='urn:xmpp:message-correct:0' id='gone'/></message>")
        #expect(result.newMessage?.body == "fixed")
        #expect(result.newMessage?.editedAt != nil)
    }

    @Test func someoneElsesCorrectionInARoomIsNotKeptAsAMessage() throws {
        try db.joinGroupChat(room, nickname: "me")
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='g1'><body>hi all</body></message>")
        let result = try ingestGroup("<message from='cake@rooms.example.org/mallory' type='groupchat' id='g2'><body>pwned</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/></message>")
        #expect(result.newMessage == nil)
        #expect(try messages().map(\.body) == ["hi all"])
    }

    @Test func replayedCorrectionDoesNotBringBackARetractedMessage() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>v1</body><stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='s1'/></message>")
        try ingest("<message from='alice@example.org/phone' type='chat' id='c1'><body>secret v2</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/><stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='s2'/></message>", at: Date(timeIntervalSince1970: 110))
        try ingest("<message from='alice@example.org/phone' type='chat' id='r1'><retract id='m1' xmlns='urn:xmpp:message-retract:1'/><stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='s3'/></message>", at: Date(timeIntervalSince1970: 120))
        // A catch-up replays all three.
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>v1</body></message>", source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 100)))
        try ingest("<message from='alice@example.org/phone' type='chat' id='c1'><body>secret v2</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>", source: .archive(serverId: "s2", timestamp: Date(timeIntervalSince1970: 110)))
        try ingest("<message from='alice@example.org/phone' type='chat' id='r1'><retract id='m1' xmlns='urn:xmpp:message-retract:1'/></message>", source: .archive(serverId: "s3", timestamp: Date(timeIntervalSince1970: 120)))
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(stored[0].isRetracted)
        #expect(stored[0].body.isEmpty)
    }

    @Test func replayedReactionDoesNotReattachToARetractedMessage() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>v1</body></message>")
        let reaction = "<message from='alice@example.org/phone' type='chat' id='x1'><reactions xmlns='urn:xmpp:reactions:0' id='m1'><reaction>👍</reaction></reactions></message>"
        try ingest(reaction)
        try ingest("<message from='alice@example.org/phone' type='chat' id='r1'><retract id='m1' xmlns='urn:xmpp:message-retract:1'/></message>")
        try ingest(reaction, source: .archive(serverId: "s9", timestamp: nil))
        #expect(try db.reader.read { try Reaction.fetchCount($0) } == 0)
    }

    @Test func groupCorrectionsNeedTheSameOccupant() throws {
        try db.joinGroupChat(room, nickname: "me")
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='g1'><body>hi all</body></message>")
        // Someone else, in an anonymous room: a different nickname.
        try ingestGroup("<message from='cake@rooms.example.org/mallory' type='groupchat' id='g2'><body>pwned</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/></message>")
        #expect(try messages().first { $0.remoteId == "g1" }?.body == "hi all")
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='g3'><body>hi everyone</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/></message>")
        #expect(try messages().first { $0.remoteId == "g1" }?.body == "hi everyone")
    }

    @Test func groupCorrectionsFollowTheOccupantId() throws {
        try db.joinGroupChat(room, nickname: "me")
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='g1'><body>hi</body><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-anna'/></message>", trustsOccupantIds: true)
        // Renamed, same occupant.
        try ingestGroup("<message from='cake@rooms.example.org/anne' type='groupchat' id='g2'><body>hello</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-anna'/></message>", trustsOccupantIds: true)
        #expect(try messages().first { $0.remoteId == "g1" }?.body == "hello")
        // Someone who took her old nickname.
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='g3'><body>pwned</body><replace xmlns='urn:xmpp:message-correct:0' id='g1'/><occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-mallory'/></message>", trustsOccupantIds: true)
        #expect(try messages().first { $0.remoteId == "g1" }?.body == "hello")
    }

    // MARK: Retractions

    @Test func retractionLeavesATombstone() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>oops https://example.org</body><stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='s1'/></message>")
        let original = try #require(try messages().first)
        try db.setReactions(["👍"], from: me, conversationId: original.conversationId, messageRef: "m1")
        try db.writer.write { try Attachment(messageId: original.id!, url: "https://example.org/f.jpg", name: "f.jpg", state: .remote).insert($0) }

        let result = try ingest("""
            <message from='alice@example.org/phone' type='chat' id='r1'>
              <retract id='m1' xmlns='urn:xmpp:message-retract:1'/>
              <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/>
              <body>/me retracted a previous message, but it's unsupported by your client.</body>
              <store xmlns='urn:xmpp:hints'/>
            </message>
            """)
        #expect(result.newMessage == nil)
        #expect(result.retractedAttachment?.name == "f.jpg")
        let stored = try messages()
        #expect(stored.count == 1)
        #expect(stored[0].isRetracted)
        #expect(stored[0].body == "")
        #expect(stored[0].link == nil)
        #expect(stored[0].isRead)
        #expect(try db.reader.read { try Reaction.fetchCount($0) } == 0)
        #expect(try db.reader.read { try Attachment.fetchCount($0) } == 0)

        // The archive bringing the original back doesn't undo it.
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>oops</body></message>", source: .archive(serverId: "s1", timestamp: nil))
        #expect(try messages().count == 1)
        #expect(try messages()[0].isRetracted)
    }

    @Test func onlyTheSenderMayRetract() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "mine", status: .sent, remoteId: "o1"))
        try ingest("<message from='alice@example.org/phone' type='chat' id='r'><retract id='o1' xmlns='urn:xmpp:message-retract:1'/></message>")
        #expect(try messages().first?.isRetracted == false)
    }

    @Test func retractionOfUnknownIsDropped() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='r'><retract id='nope' xmlns='urn:xmpp:message-retract:1'/><body>fallback</body></message>")
        #expect(try messages().isEmpty)
    }

    @Test func legacyRetraction() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>old school</body></message>")
        try ingest("""
            <message from='alice@example.org/phone' type='chat' id='r'>
              <apply-to id='m1' xmlns='urn:xmpp:fasten:0'><retract xmlns='urn:xmpp:message-retract:0'/></apply-to>
              <fallback xmlns='urn:xmpp:fallback:0'/><body>This person attempted to retract a previous message</body>
            </message>
            """)
        #expect(try messages().count == 1)
        #expect(try messages()[0].isRetracted)
    }

    @Test func archiveTombstone() throws {
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><body>secret</body></message>", source: .archive(serverId: "s1", timestamp: nil))
        try ingest("<message from='alice@example.org/phone' type='chat' id='m1'><retracted xmlns='urn:xmpp:message-retract:1' id='r1' stamp='2026-01-01T00:00:00Z'/></message>",
                   source: .archive(serverId: "s1", timestamp: nil))
        #expect(try messages().count == 1)
        #expect(try messages()[0].isRetracted)
    }

    @Test func groupRetractionByRoomId() throws {
        try db.joinGroupChat(room, nickname: "me")
        let alicePresent = ["anna": alice]
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='g1'><body>hi</body><stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='rs1'/></message>", occupants: alicePresent)
        try ingestGroup("<message from='cake@rooms.example.org/anna' type='groupchat' id='r'><retract id='rs1' xmlns='urn:xmpp:message-retract:1'/></message>", occupants: alicePresent)
        #expect(try messages()[0].isRetracted)
    }

    @Test func retractedMessagesAreNotResent() throws {
        let conversation = try db.conversation(with: alice)
        let pending = try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "never mind", timestamp: Date(), remoteId: "o1"))
        _ = try db.applyRetraction(of: pending.id!)
        #expect(try db.unconfirmedOutgoing(before: .distantFuture, since: .distantPast).isEmpty)
    }

    @Test func retractionStanza() throws {
        let out = OutboundStanza.retraction(of: "m1", to: .direct(alice), id: "r1")
        out.from = Martin.JID(me.martin)
        let parsed = try #require(InboundMessage(stanza(out.element.stringValue), account: alice, source: .live))
        #expect(parsed.retractionOf == "m1")
        #expect(parsed.body == nil)
        #expect(out.firstChild(name: "store", xmlns: "urn:xmpp:hints") != nil)
    }
}
