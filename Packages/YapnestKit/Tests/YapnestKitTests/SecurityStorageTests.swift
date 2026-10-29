import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let bob = YapnestKit.JID("bob@example.org")!

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

private func inbound(
    _ xml: String,
    source: InboundMessage.Source = .live,
    encryption: YapnestKit.Message.Encryption = .none,
    device: Int32? = nil,
    trust: OMEMODevice.Trust? = nil,
    at date: Date = Date(timeIntervalSince1970: 100),
) throws -> InboundMessage {
    var parsed = try #require(InboundMessage(stanza(xml), account: me, source: source, encryption: encryption, now: date))
    parsed.omemoDevice = device
    parsed.omemoTrust = trust
    return parsed
}

private func messages(_ db: AppDatabase) throws -> [YapnestKit.Message] {
    try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
}

/// Corrections must not change how a message was protected.
struct EncryptedCorrectionTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func correction(_ text: String, id: String = "c1") -> String {
        "<message from='alice@example.org/phone' type='chat' id='\(id)'><body>\(text)</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>"
    }

    private func original(encryption: YapnestKit.Message.Encryption) throws {
        try db.ingest(inbound("<message from='alice@example.org/phone' type='chat' id='m1'><body>original</body></message>",
                              encryption: encryption, device: encryption == .omemo ? 1 : nil, trust: encryption == .omemo ? .trusted : nil))
    }

    @Test func plainCorrectionOfAnEncryptedMessageIsIgnored() throws {
        try original(encryption: .omemo)
        let result = try db.ingest(inbound(correction("forged"), at: Date(timeIntervalSince1970: 200)))
        #expect(result.newMessage == nil)
        let stored = try messages(db)
        #expect(stored.count == 1)
        #expect(stored[0].body == "original")
        #expect(stored[0].editedAt == nil)
        #expect(stored[0].encryption == .omemo)
    }

    @Test func encryptedCorrectionTakesTheCorrectingDevice() throws {
        try original(encryption: .omemo)
        try db.ingest(inbound(correction("fixed"), encryption: .omemo, device: 7, trust: .undecided, at: Date(timeIntervalSince1970: 200)))
        let stored = try messages(db)
        #expect(stored.count == 1)
        #expect(stored[0].body == "fixed")
        #expect(stored[0].editedAt == Date(timeIntervalSince1970: 200))
        #expect(stored[0].encryption == .omemo)
        #expect(stored[0].omemoDevice == 7)
        #expect(stored[0].omemoTrust == .undecided)
    }

    @Test func plainCorrectionOfAPlainMessageStillApplies() throws {
        try original(encryption: .none)
        try db.ingest(inbound(correction("fixed"), at: Date(timeIntervalSince1970: 200)))
        let stored = try messages(db)
        #expect(stored.count == 1)
        #expect(stored[0].body == "fixed")
        #expect(stored[0].omemoDevice == nil)
    }

    @Test func encryptedCorrectionOfAPlainMessageIsIgnored() throws {
        try original(encryption: .none)
        try db.ingest(inbound(correction("sneaky"), encryption: .omemo, device: 7, trust: .trusted, at: Date(timeIntervalSince1970: 200)))
        #expect(try messages(db)[0].body == "original")
    }
}

/// XEP-0333 markers.
struct MarkerStorageTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func outgoing(_ id: String, at time: TimeInterval, status: YapnestKit.Message.Status, in conversation: Conversation) throws {
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: id,
                                         timestamp: Date(timeIntervalSince1970: time), status: status, remoteId: id, originId: id))
    }

    @Test func markableIsStoredForIncomingOneToOneMessages() throws {
        try db.ingest(inbound("<message from='alice@example.org/phone' type='chat' id='m1'><body>a</body><markable xmlns='urn:xmpp:chat-markers:0'/></message>"))
        try db.ingest(inbound("<message from='alice@example.org/phone' type='chat' id='m2'><body>b</body></message>"))
        let stored = try messages(db)
        #expect(stored.first { $0.remoteId == "m1" }?.isMarkable == true)
        #expect(stored.first { $0.remoteId == "m2" }?.isMarkable == false)
    }

    @Test func ourOwnMessagesAreNeverMarkable() throws {
        let carbon = try inbound("<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='o1'><body>hi</body><markable xmlns='urn:xmpp:chat-markers:0'/></message>",
                                 source: .carbon(sent: true))
        try db.ingest(carbon)
        #expect(try messages(db).first?.isMarkable == false)
    }

    @Test func groupMessagesAreNeverMarkable() throws {
        let room = YapnestKit.JID("cake@rooms.example.org")!
        try db.joinGroupChat(room, nickname: "me")
        var parsed = try #require(InboundMessage(
            groupchat: stanza("<message from='cake@rooms.example.org/anna' type='groupchat' id='g1'><body>hi</body><markable xmlns='urn:xmpp:chat-markers:0'/></message>"),
            room: RoomContext(jid: room, nickname: "me"), account: me, source: .live))
        // Whatever the parser made of it, storage doesn't keep it for rooms.
        parsed.isMarkable = true
        try db.ingest(parsed)
        #expect(try messages(db).first?.isMarkable == false)
    }

    @Test func displayedMarkerCoversEarlierSentMessagesButNotPendingOnes() throws {
        let conversation = try db.conversation(with: alice)
        try outgoing("o1", at: 10, status: .pending, in: conversation)
        try outgoing("o2", at: 20, status: .sent, in: conversation)
        try outgoing("o3", at: 30, status: .delivered, in: conversation)
        try outgoing("o4", at: 40, status: .sent, in: conversation)
        try outgoing("o5", at: 50, status: .sent, in: conversation)

        try db.ingest(inbound("<message from='alice@example.org/phone' type='chat' id='d1'><displayed xmlns='urn:xmpp:chat-markers:0' id='o4'/></message>"))
        let status = Dictionary(uniqueKeysWithValues: try messages(db).map { ($0.remoteId!, $0.status) })
        #expect(status == ["o1": .pending, "o2": .displayed, "o3": .displayed, "o4": .displayed, "o5": .sent])
    }

    @Test func displayedMarkerOfAnIncomingMessageChangesNothing() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "theirs", timestamp: Date(timeIntervalSince1970: 50), remoteId: "i1"))
        try outgoing("o1", at: 10, status: .sent, in: conversation)
        try db.ingest(inbound("<message from='alice@example.org/phone' type='chat' id='d1'><displayed xmlns='urn:xmpp:chat-markers:0' id='i1'/></message>"))
        #expect(try messages(db).first { $0.remoteId == "o1" }?.status == .sent)
    }

    @Test func lastIncomingSkipsMessagesThatAreNotMarkable() throws {
        let conversation = try db.conversation(with: alice)
        func incoming(_ id: String, at time: TimeInterval, markable: Bool) throws {
            var message = YapnestKit.Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: id, timestamp: Date(timeIntervalSince1970: time), remoteId: id)
            message.isMarkable = markable
            try db.insert(message)
        }
        try incoming("i1", at: 10, markable: true)
        try incoming("i2", at: 20, markable: false)
        #expect(try db.lastIncoming(conversationId: conversation.id!)?.remoteId == "i2")
        #expect(try db.lastIncoming(conversationId: conversation.id!, markable: true)?.remoteId == "i1")

        let other = try db.conversation(with: bob)
        #expect(try db.lastIncoming(conversationId: other.id!, markable: true) == nil)
    }
}

struct BatchIngestTests {
    @Test func storesSeveralMessagesAndReportsEach() throws {
        let db = try AppDatabase.inMemory()
        let batch = try [
            inbound("<message from='alice@example.org/phone' type='chat' id='m1'><body>one</body></message>", source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 1))),
            inbound("<message from='alice@example.org/phone' type='chat' id='m2'><body>two</body></message>", source: .archive(serverId: "s2", timestamp: Date(timeIntervalSince1970: 2))),
            inbound("<message from='bob@example.org/phone' type='chat' id='m3'><body>three</body></message>", source: .archive(serverId: "s3", timestamp: Date(timeIntervalSince1970: 3))),
            // The same message again.
            inbound("<message from='alice@example.org/phone' type='chat' id='m1'><body>one</body></message>", source: .archive(serverId: "s1", timestamp: Date(timeIntervalSince1970: 1))),
        ]
        let results = try db.ingest(batch)
        #expect(results.count == 4)
        #expect(results.map { $0.newMessage?.body } == ["one", "two", "three", nil])
        #expect(results[3].conversationId == results[0].conversationId)
        #expect(results[2].conversationId != results[0].conversationId)
        #expect(try messages(db).count == 3)
        #expect(try db.ingest([]).isEmpty)
    }
}

struct DeliveryStateTests {
    let db: AppDatabase
    let conversation: Conversation

    init() throws {
        db = try AppDatabase.inMemory()
        conversation = try db.conversation(with: alice)
    }

    private func outgoing(_ id: String, status: YapnestKit.Message.Status, serverId: String? = nil, at time: TimeInterval = 100) throws {
        try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: id,
                                         timestamp: Date(timeIntervalSince1970: time), status: status, remoteId: id, originId: id, serverId: serverId))
    }

    @Test func onlyPendingMessagesAreUnconfirmed() throws {
        try outgoing("pending", status: .pending)
        try outgoing("sent", status: .sent)
        try outgoing("failed", status: .failed)
        try outgoing("delivered", status: .delivered, serverId: "s1")
        let found = try db.unconfirmedOutgoing()
        #expect(found.map(\.0.remoteId) == ["pending"])
        #expect(found.first?.1 == alice)
    }

    @Test func unconfirmedRespectsTheTimeWindow() throws {
        try outgoing("early", status: .pending, at: 10)
        try outgoing("inside", status: .pending, at: 50)
        try outgoing("late", status: .pending, at: 90)
        let found = try db.unconfirmedOutgoing(before: Date(timeIntervalSince1970: 90), since: Date(timeIntervalSince1970: 20))
        #expect(found.map(\.0.remoteId) == ["inside"])
    }

    @Test func markSentMovesPendingForwardOnly() throws {
        try outgoing("a", status: .pending)
        try outgoing("b", status: .delivered)
        try db.markSent(peer: alice, remoteId: "a")
        try db.markSent(peer: alice, remoteId: "b")
        let status = Dictionary(uniqueKeysWithValues: try messages(db).map { ($0.remoteId!, $0.status) })
        #expect(status == ["a": .sent, "b": .delivered])
        // An unknown peer or message is simply nothing to do.
        try db.markSent(peer: bob, remoteId: "a")
        try db.markSent(peer: alice, remoteId: "nope")
    }
}

struct ChatListLatestMessageTests {
    @Test func eachConversationShowsItsNewestMessage() throws {
        let db = try AppDatabase.inMemory()
        let a = try db.conversation(with: alice)
        let b = try db.conversation(with: bob)
        func add(_ conversation: Conversation, _ body: String, at time: TimeInterval) throws {
            try db.insert(YapnestKit.Message(conversationId: conversation.id!, direction: .incoming, sender: conversation.peer, body: body, timestamp: Date(timeIntervalSince1970: time), remoteId: body))
        }
        try add(a, "old", at: 10)
        try add(a, "new", at: 30)
        try add(a, "middle", at: 20)
        try add(b, "first", at: 50)
        // Same timestamp: the one stored later wins.
        try add(b, "second", at: 50)

        let list = try db.chatList()
        #expect(list.count == 2)
        #expect(list.first { $0.conversation.peer == alice }?.lastMessage?.body == "new")
        #expect(list.first { $0.conversation.peer == bob }?.lastMessage?.body == "second")
    }

    @Test func archivedConversationsAreListedApart() throws {
        let db = try AppDatabase.inMemory()
        let a = try db.conversation(with: alice)
        let b = try db.conversation(with: bob)
        try db.insert(YapnestKit.Message(conversationId: a.id!, direction: .incoming, sender: alice, body: "hi", timestamp: Date(timeIntervalSince1970: 10), remoteId: "a"))
        try db.insert(YapnestKit.Message(conversationId: b.id!, direction: .incoming, sender: bob, body: "yo", timestamp: Date(timeIntervalSince1970: 10), remoteId: "b"))
        try db.setArchived(true, conversationId: b.id!)

        let active = try db.chatList()
        #expect(active.map(\.conversation.peer) == [alice])
        #expect(active.first?.lastMessage?.body == "hi")
        let archived = try db.chatList(archived: true)
        #expect(archived.map(\.conversation.peer) == [bob])
        #expect(archived.first?.lastMessage?.body == "yo")
    }
}
