import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private let ns = "urn:xmpp:tmp:quick-response"

private func xml(_ children: String, body: String? = "Merge?", id: String = "m1", from: String = "alice@example.org/bot") -> String {
    "<message from='\(from)' type='chat' id='\(id)'>\(body.map { "<body>\($0)</body>" } ?? "")\(children)</message>"
}

private func parse(_ xml: String, encryption: YapnestKit.Message.Encryption = .none, source: InboundMessage.Source = .live) -> InboundMessage? {
    InboundMessage(parseStanza(xml) as Martin.Message, account: me, source: source, encryption: encryption)
}

struct QuickResponseParsingTests {
    @Test func responsesAndActionsAreRead() throws {
        let m = try #require(parse(xml("""
            <response xmlns='\(ns)' value='yes' label='Sure!' xml:lang='en'/>
            <response xmlns='\(ns)' value='no'/>
            <action xmlns='\(ns)' id='merge' label='Merge Now!'/>
            """)))
        let offer = try #require(m.quickResponses)
        #expect(offer.responses == [.init(value: "yes", label: "Sure!"), .init(value: "no", label: nil)])
        #expect(offer.responses.map(\.title) == ["Sure!", "no"])
        #expect(offer.actions == [.init(id: "merge", label: "Merge Now!")])
        #expect(offer.chosen.isEmpty)
    }

    @Test func noElementsMeansNoOffer() throws {
        #expect(try #require(parse(xml(""))).quickResponses == nil)
    }

    @Test func badEntriesAreDroppedAndGoodOnesKept() throws {
        let long = String(repeating: "a", count: 257)
        let longLabel = String(repeating: "b", count: 65)
        let m = try #require(parse(xml("""
            <response xmlns='\(ns)' value='yes' label='Yes'/>
            <response xmlns='\(ns)' value='yes' label='Again'/>
            <response xmlns='\(ns)' value='other' label='Yes'/>
            <response xmlns='\(ns)' value='  '/>
            <response xmlns='\(ns)'/>
            <response xmlns='\(ns)' value='\(long)'/>
            <response xmlns='\(ns)' value='long label' label='\(longLabel)'/>
            <response xmlns='\(ns)' value='ok&#x202E;gnirts' label='Bidi'/>
            <response xmlns='\(ns)' value='fine' label='Fi&#x202E;ne'/>
            <response xmlns='\(ns)' value='two&#10;lines'/>
            <response xmlns='\(ns)' value='last'/>
            <action xmlns='\(ns)' id='a' label='A'/>
            <action xmlns='\(ns)' id='a' label='Again'/>
            <action xmlns='\(ns)' id='b' label='A'/>
            <action xmlns='\(ns)' id='c'/>
            <action xmlns='\(ns)' label='No id'/>
            <action xmlns='\(ns)' id='d&#x2066;' label='D'/>
            <action xmlns='\(ns)' id='e' label=' '/>
            <action xmlns='\(ns)' id='f' label='F'/>
            """)))
        let offer = try #require(m.quickResponses)
        #expect(offer.responses.map(\.value) == ["yes", "last"])
        #expect(offer.actions.map(\.id) == ["a", "f"])
    }

    @Test func eachListIsCapped() throws {
        let responses = (0..<12).map { "<response xmlns='\(ns)' value='r\($0)'/>" }.joined()
        let actions = (0..<12).map { "<action xmlns='\(ns)' id='a\($0)' label='L\($0)'/>" }.joined()
        let offer = try #require(parse(xml(responses + actions))?.quickResponses)
        #expect(offer.responses.count == 8 && offer.responses.last?.value == "r7")
        #expect(offer.actions.count == 8 && offer.actions.last?.id == "a7")
    }

    @Test func anEncryptedMessageIgnoresThem() {
        // The elements sit outside the OMEMO payload, so a server could have written them.
        let m = parse(xml("<response xmlns='\(ns)' value='yes'/><action xmlns='\(ns)' id='x' label='X'/>"), encryption: .omemo)
        #expect(m?.quickResponses == nil)
    }

    @Test func aMessageWithoutABodyHasNone() {
        #expect(parse(xml("<response xmlns='\(ns)' value='yes'/>", body: nil))?.quickResponses == nil)
    }

    @Test func aRoomsMessageHasNone() throws {
        // Choosing an action would be sent to the whole room.
        let room = YapnestKit.JID("cake@rooms.example.org")!
        let stanza = "<message from='cake@rooms.example.org/bot' type='groupchat' id='g1'><body>Merge?</body><action xmlns='\(ns)' id='merge' label='Merge'/></message>"
        let m = try #require(InboundMessage(groupchat: parseStanza(stanza) as Martin.Message, room: RoomContext(jid: room, nickname: "me"), account: me, source: .live))
        #expect(m.body == "Merge?" && m.quickResponses == nil)
    }

    @Test func aPrivateMessageThroughARoomHasNone() {
        let pm = "<message from='cake@rooms.example.org/bot' type='chat' id='p1'><body>Merge?</body><x xmlns='http://jabber.org/protocol/muc#user'/><action xmlns='\(ns)' id='merge' label='Merge'/></message>"
        let m = parse(pm)
        #expect(m?.body == "Merge?" && m?.quickResponses == nil)
    }

    @Test func ourOwnMessageHasNone() {
        let sent = "<message from='me@example.org/phone' to='alice@example.org' type='chat' id='m1'><body>hi</body><response xmlns='\(ns)' value='yes'/></message>"
        #expect(parse(sent, source: .carbon(sent: true))?.quickResponses == nil)
    }
}

struct QuickResponseStorageTests {
    let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    private func messages() throws -> [YapnestKit.Message] {
        try db.reader.read { try YapnestKit.Message.order(Column("id")).fetchAll($0) }
    }

    @discardableResult
    private func ingest(_ xml: String) throws -> IngestResult {
        try db.ingest(#require(parse(xml)))
    }

    private let offer = "<response xmlns='\(ns)' value='yes' label='Sure!'/><action xmlns='\(ns)' id='merge' label='Merge'/>"

    @Test func itIsStoredOnIngest() throws {
        try ingest(xml(offer))
        let stored = try #require(try messages().first?.quickResponses)
        #expect(stored.responses == [.init(value: "yes", label: "Sure!")] && stored.actions == [.init(id: "merge", label: "Merge")])
    }

    @Test func aMessageWithoutOneStoresNone() throws {
        try ingest(xml(""))
        #expect(try messages().first?.quickResponses == nil)
    }

    @Test func aCorrectionReplacesItAndMayRemoveIt() throws {
        try ingest(xml(offer))
        try ingest(xml("<replace xmlns='urn:xmpp:message-correct:0' id='m1'/><action xmlns='\(ns)' id='other' label='Other'/>", body: "Merge again?", id: "m2"))
        #expect(try messages().count == 1)
        #expect(try messages()[0].quickResponses == QuickResponses(actions: [.init(id: "other", label: "Other")]))

        try ingest(xml("<replace xmlns='urn:xmpp:message-correct:0' id='m1'/>", body: "Never mind", id: "m3"))
        #expect(try messages()[0].body == "Never mind")
        #expect(try messages()[0].quickResponses == nil)
    }

    @Test func aCorrectionKeepsTheChoicesItStillOffers() throws {
        try ingest(xml("<action xmlns='\(ns)' id='merge' label='Merge'/><action xmlns='\(ns)' id='close' label='Close'/>"))
        let stored = try #require(try messages().first)
        try db.recordChosenAction("merge", on: stored.id!)
        try db.recordChosenAction("close", on: stored.id!)

        try ingest(xml("<replace xmlns='urn:xmpp:message-correct:0' id='m1'/><action xmlns='\(ns)' id='merge' label='Merge now'/><action xmlns='\(ns)' id='other' label='Other'/>", body: "Merge again?", id: "m2"))
        let offer = try #require(try messages()[0].quickResponses)
        #expect(offer.actions.map(\.id) == ["merge", "other"])
        #expect(offer.chosen == ["merge"], "close is no longer offered, and other was never chosen")
    }

    private func selected(_ id: String, source: InboundMessage.Source = .carbon(sent: true), encrypted: Bool = false) -> InboundMessage? {
        parse("<message from='me@example.org/phone' to='alice@example.org/bot' type='chat' id='s1'><action-selected xmlns='\(ns)' id='\(id)'/></message>",
              encryption: encrypted ? .omemo : .none, source: source)
    }

    private func chosen() throws -> [[String]?] { try messages().map { $0.quickResponses?.chosen } }

    @Test func anActionChosenOnAnotherDeviceMarksTheNewestOfferOfIt() throws {
        try ingest(xml(offer, id: "m1"))
        try ingest(xml("<action xmlns='\(ns)' id='close' label='Close'/>", id: "m2"))
        try ingest(xml(offer, id: "m3"))
        let before = try messages().count

        try db.ingest(#require(selected("merge")))

        #expect(try messages().count == before, "an action with no body makes no message")
        #expect(try chosen() == [[], [], ["merge"]])
    }

    @Test func aChoiceReplayedFromTheArchiveLeavesOlderOffersAlone() throws {
        try ingest(xml(offer, id: "m1"))
        try ingest(xml(offer, id: "m2"))
        try db.ingest(#require(selected("merge")))
        // This device made the choice itself, or already heard of it.
        try db.ingest(#require(selected("merge", source: .archive(serverId: "a1", timestamp: Date()))))
        #expect(try chosen() == [[], ["merge"]])
    }

    @Test func aChoiceDoesNotMarkAnOfferThatCameAfterIt() throws {
        try ingest(xml(offer, id: "m1"))
        var early = try #require(selected("merge"))
        early.timestamp = Date(timeIntervalSinceNow: -3600)
        try db.ingest(early)
        #expect(try chosen() == [[]])
    }

    @Test func aChoiceThatMatchesNothingDoesNothing() throws {
        try ingest(xml(offer))
        try db.ingest(#require(selected("unknown")))
        #expect(try chosen() == [[]])
    }

    @Test func aChoiceInAConversationWeNeverHadDoesNothing() throws {
        try db.ingest(#require(selected("merge")))
        #expect(try messages().isEmpty)
    }

    @Test func aContactsOrEncryptedActionSelectedIsIgnored() throws {
        try ingest(xml(offer))
        let theirs = "<message from='alice@example.org/bot' to='me@example.org' type='chat' id='s2'><action-selected xmlns='\(ns)' id='merge'/></message>"
        #expect(parse(theirs)?.actionSelected == nil)
        #expect(selected("merge", encrypted: true)?.actionSelected == nil)
        try db.ingest(#require(selected("merge", encrypted: true)))
        #expect(try chosen() == [[]])
    }

    @Test func aRetractionClearsIt() throws {
        try ingest(xml(offer))
        try ingest("<message from='alice@example.org/bot' type='chat' id='r'><retract id='m1' xmlns='urn:xmpp:message-retract:1'/></message>")
        let message = try messages()[0]
        #expect(message.isRetracted && message.quickResponses == nil)
    }

    @Test func choosingAnActionIsRecordedOnceAndBumpsTheRevision() throws {
        let stored = try #require(try ingest(xml(offer)).newMessage)
        func rev() throws -> Int? { try db.reader.read { try Int.fetchOne($0, sql: "SELECT rev FROM message") } }
        let before = try #require(try rev())

        try db.recordChosenAction("merge", on: stored.id!)
        try db.recordChosenAction("merge", on: stored.id!)
        try db.recordChosenAction("unknown", on: stored.id!)

        let after = try #require(try messages().first)
        #expect(after.quickResponses?.chosen == ["merge"])
        #expect(try rev() == before + 1)
    }
}

struct QuickResponseSendingTests {
    @Test func theActionStanzaHasNoBodyAndAStoreHint() throws {
        let out = OutboundStanza.actionSelected("merge", to: .direct(alice), id: "a1")
        #expect(out.body == nil)
        #expect(out.type == .chat)
        #expect(out.id == "a1")
        let selected = try #require(out.firstChild(name: "action-selected", xmlns: ns))
        #expect(selected.getAttribute("id") == "merge")
        #expect(out.firstChild(name: "store", xmlns: "urn:xmpp:hints") != nil)
    }

    @Test func aRoomGetsGroupchat() {
        let out = OutboundStanza.actionSelected("merge", to: .room(YapnestKit.JID("cake@rooms.example.org")!, status: nil), id: "a1")
        #expect(out.type == .groupchat)
        #expect(out.to?.description == "cake@rooms.example.org")
    }

    private func setUp() throws -> (XMPPSession, YapnestKit.Message) {
        let session = try makeSession(me)
        let id = try #require(try session.database.conversation(with: alice).id)
        var message = YapnestKit.Message(conversationId: id, direction: .incoming, sender: alice, body: "Merge?", remoteId: "1")
        message.quickResponses = QuickResponses(actions: [.init(id: "merge", label: "Merge")])
        return (session, try session.database.insert(message))
    }

    @Test func choosingWhileOfflineThrowsAndRecordsNothing() throws {
        let (session, message) = try setUp()
        #expect(throws: XMPPSession.MessageActionError.self) { try session.chooseAction("merge", on: message) }
        #expect(try session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.quickResponses?.chosen } == [])
    }

    @Test func aWriteTheConnectionRefusesIsTakenBack() throws {
        let (session, message) = try setUp()
        let wire = FakeWire()
        wire.failsWrites = true
        session.connectForTesting(wire)
        #expect(throws: XMPPSession.MessageActionError.self) { try session.chooseAction("merge", on: message) }
        #expect(try session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.quickResponses?.chosen } == [])

        // Once it can go out, the same action can be chosen again.
        wire.failsWrites = false
        try session.chooseAction("merge", on: message)
        #expect(try session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.quickResponses?.chosen } == ["merge"])
    }

    @Test func choosingSendsTheActionAndRecordsIt() throws {
        let (session, message) = try setUp()
        let wire = FakeWire()
        session.connectForTesting(wire)
        try session.chooseAction("merge", on: message)
        // An id the message never offered is not sent.
        try session.chooseAction("other", on: message)

        let sent = wire.messages.filter { $0.firstChild(name: "action-selected", xmlns: ns) != nil }
        #expect(sent.count == 1)
        #expect(sent[0].to?.description == "alice@example.org")
        #expect(try session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.quickResponses?.chosen } == ["merge"])
    }

    @Test func choosingTheSameActionTwiceSendsOnce() throws {
        let (session, message) = try setUp()
        let wire = FakeWire()
        session.connectForTesting(wire)
        try session.chooseAction("merge", on: message)
        // The caller still holds the message as it was before the first tap.
        try session.chooseAction("merge", on: message)

        #expect(wire.messages.filter { $0.firstChild(name: "action-selected", xmlns: ns) != nil }.count == 1)
    }

    @Test func recordingTheSameActionAgainSaysNo() throws {
        let (session, message) = try setUp()
        #expect(try session.database.recordChosenAction("merge", on: message.id!))
        #expect(try !session.database.recordChosenAction("merge", on: message.id!))
        #expect(try !session.database.recordChosenAction("other", on: message.id!))
    }
}
