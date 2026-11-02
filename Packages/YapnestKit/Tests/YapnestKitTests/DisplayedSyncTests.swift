import Foundation
import GRDB
@testable import Martin
import Testing
@testable import YapnestKit

/// XEP-0490 message displayed synchronization.
struct DisplayedSyncTests {
    let db: AppDatabase
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @Test func itemRoundTrips() throws {
        let state = DisplayedState(peer: alice, stanzaId: "s1", by: me)
        let xml = state.element.stringValue
        #expect(xml.contains("urn:xmpp:mds:displayed:0"))
        #expect(xml.contains("urn:xmpp:sid:0"))
        #expect(DisplayedState(id: alice.description, payload: Element.from(string: xml)) == state)
        #expect(DisplayedState(id: alice.description, payload: Element.from(string: "<displayed xmlns='urn:xmpp:mds:displayed:0'/>")) == nil)
    }

    @Test func readStateOnlyMovesForward() throws {
        let conversation = try db.conversation(with: alice)
        for (index, serverId) in ["s1", "s2", "s3"].enumerated() {
            try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "m\(index)",
                                  timestamp: Date(timeIntervalSince1970: Double(index)), serverId: serverId))
        }
        func unread() throws -> [String] {
            try db.reader.read { try Message.filter(Column("isRead") == false).order(Column("timestamp")).fetchAll($0).map(\.body) }
        }
        #expect(try db.applyDisplayed(peer: alice, stanzaId: "s2"))
        #expect(try unread() == ["m2"])
        // An older state doesn't make anything unread again.
        #expect(try db.applyDisplayed(peer: alice, stanzaId: "s1"))
        #expect(try unread() == ["m2"])
        // A message we don't have yet is ignored.
        #expect(try !db.applyDisplayed(peer: alice, stanzaId: "unknown"))
        #expect(try unread() == ["m2"])
        #expect(try !db.applyDisplayed(peer: YapnestKit.JID("nobody@example.org")!, stanzaId: "s3"))
    }

    @Test func manyChatsAreAppliedInOneCall() throws {
        let carol = YapnestKit.JID("carol@example.org")!
        for (peer, serverId) in [(alice, "a1"), (carol, "c1")] {
            let conversation = try db.conversation(with: peer)
            for (index, suffix) in ["", "-later"].enumerated() {
                try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: peer, body: "m",
                                      timestamp: Date(timeIntervalSince1970: Double(index)), serverId: serverId + suffix))
            }
        }
        let nobody = YapnestKit.JID("nobody@example.org")!
        let applied = try db.applyDisplayed([(alice, "a1-later"), (carol, "c1"), (nobody, "x"), (alice, "unknown")])
        #expect(applied == [alice, carol])
        // Alice's chat is read through its second message, carol's through its first.
        #expect(try db.unreadMessageCount(peer: alice) == 0)
        #expect(try db.unreadMessageCount(peer: carol) == 1)
        // Forward only, as with one chat.
        _ = try db.applyDisplayed([(alice, "a1"), (carol, "c1")])
        #expect(try db.unreadMessageCount(peer: alice) == 0)
        #expect(try db.unreadMessageCount(peer: carol) == 1)
        #expect(try db.applyDisplayed([]).isEmpty)
    }

    @Test func fetchedStatesAlreadyKnownAreNotApplied() throws {
        let session = try makeSession(me, database: db)
        let conversation = try db.conversation(with: alice)
        try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "m", timestamp: Date(), serverId: "s1"))
        let state = DisplayedState(peer: alice, stanzaId: "s1", by: me)
        // Recorded as known, so it isn't written again.
        session.lock.withLock { $0.publishedDisplayed[alice] = "s1" }
        session.applyFetchedDisplayed([state])
        #expect(try db.unreadMessageCount(peer: alice) == 1)
        session.lock.withLock { $0.publishedDisplayed[alice] = nil }
        session.applyFetchedDisplayed([state])
        #expect(try db.unreadMessageCount(peer: alice) == 0)
        #expect(session.lock.withLock { $0.publishedDisplayed[alice] } == "s1")
        // A message not stored yet is remembered, for a room's catch-up to apply.
        session.applyFetchedDisplayed([DisplayedState(peer: alice, stanzaId: "s2", by: me)])
        #expect(session.lock.withLock { $0.publishedDisplayed[alice] } == "s2")
    }
}

/// What the server may hold while we're inactive, and who refetches it.
struct HeldNotificationsTests {
    typealias Refresh = HeldNotifications.Refresh
    let t0 = Date(timeIntervalSince1970: 1000)
    private let box = Box()

    private final class Box {
        var held = HeldNotifications()
    }

    private func send(_ active: Bool, at seconds: TimeInterval) -> Refresh? {
        box.held.sent(active: active, now: t0.addingTimeInterval(seconds))
    }

    private func staleTake(at seconds: TimeInterval) -> Bool {
        !box.held.takeSlow(generation: 0, now: t0.addingTimeInterval(seconds)).isEmpty
    }

    private func takeSlow(at seconds: TimeInterval) -> Bool {
        !box.held.takeSlow(generation: box.held.generation, now: t0.addingTimeInterval(seconds)).isEmpty
    }

    @Test func nothingIsOwedUntilInactiveIsSent() {
        #expect(send(true, at: 0) == nil)
        #expect(!box.held.isHolding)
    }

    @Test func aReturnReadsEverythingOnce() {
        #expect(send(false, at: 0) == nil)
        // Reported again while inactive: the hold began at the first.
        #expect(send(false, at: 10) == nil)
        #expect(send(true, at: 30) == Refresh(generation: 0, readStates: true, slow: .now(.slow)))
        // The resume that follows finds nothing owed.
        #expect(send(true, at: 31) == nil)
    }

    @Test func aQuickSecondReturnWaitsOutTheWindowForTheSlowNodes() {
        _ = send(false, at: 0)
        _ = send(true, at: 5)
        _ = send(false, at: 10)
        // Read states at once; bookmarks and settings when the 60s from the first are up.
        #expect(send(true, at: 20) == Refresh(generation: 0, readStates: true, slow: .after(45)))
        #expect(!takeSlow(at: 50))
        #expect(takeSlow(at: 65))
        #expect(!takeSlow(at: 66))
    }

    @Test func aWaitedForRefetchIsNotRepeatedByTheNextReturn() {
        _ = send(false, at: 0)
        _ = send(true, at: 5)
        _ = send(false, at: 10)
        _ = send(true, at: 20)
        #expect(takeSlow(at: 65))
        #expect(send(true, at: 66) == nil)
    }

    @Test func aFailureIsOwedAgainAtOnce() {
        _ = send(false, at: 0)
        _ = send(true, at: 5)
        box.held.failed(.all, generation: 0)
        // A resume right after the failed return tries again, window or not.
        #expect(send(true, at: 6) == Refresh(generation: 0, readStates: true, slow: .now(.slow)))
    }

    @Test func aFailureOfOnlyTheSlowPartLeavesReadStatesDone() {
        _ = send(false, at: 0)
        _ = send(true, at: 5)
        box.held.failed(.slow, generation: 0)
        #expect(send(true, at: 6) == Refresh(generation: 0, readStates: false, slow: .now(.slow)))
    }

    @Test func onlyTheReadThatFailedIsOwedAgain() {
        _ = send(false, at: 0)
        _ = send(true, at: 5)
        box.held.failed(.settings, generation: 0)
        #expect(send(true, at: 6) == Refresh(generation: 0, readStates: false, slow: .now(.settings)))
        box.held.failed(.bookmarks, generation: 0)
        #expect(send(true, at: 7) == Refresh(generation: 0, readStates: false, slow: .now(.bookmarks)))
        box.held.failed(.readStates, generation: 0)
        #expect(send(true, at: 8) == Refresh(generation: 0, readStates: true, slow: .none))
    }

    @Test func aFailureFromAnEarlierSessionIsIgnored() {
        _ = send(false, at: 0)
        _ = send(true, at: 5)
        box.held.reset()
        box.held.failed(.all, generation: 0)
        #expect(send(true, at: 6) == nil)
        #expect(!staleTake(at: 100))
    }

    @Test func aNewSessionReadsEverythingAnyway() {
        _ = send(false, at: 0)
        box.held.reset()
        #expect(send(true, at: 500) == nil)
    }

    @Test func theMacPolicyNeverReportsInactive() {
        #if targetEnvironment(macCatalyst)
        #expect(!XMPPSession.Policy.app.reportsInactive)
        #else
        #expect(XMPPSession.Policy.app.reportsInactive)
        #endif
    }
}

/// A chat read while offline owes its state to our other devices until the
/// server takes it.
struct OwedReadStateTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!
    var conversation: Conversation

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(me, database: db)
        conversation = try db.conversation(with: alice)
        for (index, serverId) in ["s1", "s2", "s3"].enumerated() {
            try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "m\(index)",
                                  timestamp: Date(timeIntervalSince1970: Double(index)), serverId: serverId))
        }
    }

    private var owed: Bool {
        (try? db.reader.read { try Conversation.fetchOne($0, key: conversation.id!)?.readStateOwed }) ?? false
    }

    private func publishes() -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "pubsub")?.firstChild(name: "publish") != nil }
    }

    private func publishedStanzaIds() -> [String] {
        publishes().compactMap { $0.firstChild(name: "pubsub")?.firstChild(name: "publish")?.firstChild(name: "item")?.firstChild(name: "displayed")?.firstChild(name: "stanza-id")?.attribute("id") }
    }

    /// A server whose read-state node holds `states`, taking publishes as `publish` says.
    private func serve(holding states: [DisplayedState] = [], publish: @escaping @Sendable (Iq) -> Iq = { FakeWire.result(to: $0) }) {
        wire.answer { iq in
            guard let pubsub = iq.firstChild(name: "pubsub") else { return nil }
            if pubsub.firstChild(name: "publish") != nil { return publish(iq) }
            guard let items = pubsub.firstChild(name: "items") else { return nil }
            let result = Element(name: "items", attributes: ["node": items.attribute("node") ?? ""])
            for state in states {
                let item = Element(name: "item", attributes: ["id": state.peer.description])
                item.addChild(state.element)
                result.addChild(item)
            }
            return FakeWire.result(to: iq, Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [result]))
        }
    }

    private func readOffline() throws {
        try session.markRead(conversation)
        #expect(owed)
        #expect(wire.written.isEmpty)
    }

    @Test func aChatReadOfflineIsPublishedAtTheNextCatchUp() async throws {
        try readOffline()
        serve()
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { publishedStanzaIds() == ["s3"] && !owed })
    }

    @Test func aReadWhileOnlineIsOwedUntilTheServerTakesIt() async throws {
        serve { FakeWire.error(to: $0, condition: "resource-constraint", type: "wait") }
        session.connectForTesting(wire)
        try session.markRead(conversation)
        #expect(await eventually { publishes().count == 1 })
        #expect(owed)
        #expect(session.warnings.current.isEmpty)
    }

    private func fetches() -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "pubsub")?.firstChild(name: "items") != nil }
    }

    @Test func readingTwiceQuicklyPublishesOnce() async throws {
        serve()
        session.connectForTesting(wire)
        try session.markRead(conversation)
        try session.markRead(conversation)
        session.publishOwedReadStates()
        #expect(await eventually { publishedStanzaIds() == ["s3"] && !owed })
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishedStanzaIds() == ["s3"])
    }

    @Test func aReadOnALiveConnectionPublishesWithoutAFetch() async throws {
        serve()
        session.connectForTesting(wire)
        try session.markRead(conversation)
        #expect(await eventually { publishedStanzaIds() == ["s3"] && !owed })
        #expect(fetches().isEmpty)
    }

    @Test func aReadWhileTheCatchUpGoesWaitsForTheFetch() async throws {
        serve(holding: [DisplayedState(peer: alice, stanzaId: "s3", by: me)])
        session.connectForTesting(wire, syncing: true)
        try session.markRead(conversation)
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishes().isEmpty)
        #expect(owed)
        // The fetch tells that another device read as far, so nothing is published.
        session.lock.withLock { $0.isSyncing = false }
        session.fetchDisplayed()
        #expect(await eventually { !owed })
        #expect(publishes().isEmpty)
    }

    @Test func aReadOfflineIsPublishedAfterTheConnect() async throws {
        try readOffline()
        serve()
        session.connectForTesting(wire, syncing: true)
        session.lock.withLock { $0.isSyncing = false }
        session.fetchDisplayed()
        #expect(await eventually { publishedStanzaIds() == ["s3"] && !owed })
    }

    @Test func aNotificationCoveringWhatWasOwedClearsItWithoutPublishing() async throws {
        serve()
        session.connectForTesting(wire, syncing: true)
        try session.markRead(conversation)
        #expect(owed)
        session.displayedChanged(DisplayedState(peer: alice, stanzaId: "s3", by: me))
        #expect(await eventually { !owed })
        session.lock.withLock { $0.isSyncing = false }
        session.publishOwedReadStates()
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishes().isEmpty)
    }

    @Test func aStateTheServerTakesClearsWhatWasOwed() async throws {
        serve()
        session.connectForTesting(wire)
        try session.markRead(conversation)
        #expect(await eventually { !owed })
    }

    @Test func anotherDevicesNewerStateWinsAndOursIsNotPublishedOverIt() async throws {
        try db.markRead(conversationId: conversation.id!, through: Date(timeIntervalSince1970: 1), owingReadState: true)
        #expect(owed)
        serve(holding: [DisplayedState(peer: alice, stanzaId: "s3", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { !owed })
        #expect(publishes().isEmpty)
        #expect(try db.unreadMessageCount(peer: alice) == 0)
    }

    @Test func aStateOlderThanOursIsReplacedByOurs() async throws {
        try readOffline()
        serve(holding: [DisplayedState(peer: alice, stanzaId: "s1", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { publishedStanzaIds() == ["s3"] && !owed })
    }

    @Test func aStateForAMessageWeDontHaveIsNotPublishedOver() async throws {
        try readOffline()
        serve(holding: [DisplayedState(peer: alice, stanzaId: "unknown", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishes().isEmpty)
        #expect(owed)
    }

    @Test func aStateForAMessageThatArrivesLaterIsDecidedWithoutAnotherConnect() async throws {
        try readOffline()
        serve(holding: [DisplayedState(peer: alice, stanzaId: "unknown", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishes().isEmpty)
        let newer: Martin.Message = parseStanza("<message from='alice@example.org/phone' type='chat' id='new'><body>new</body><stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='unknown'/></message>")
        session.handle(newer, source: .live)
        #expect(await eventually { !owed })
        #expect(publishes().isEmpty)
    }

    @Test func aMessageThatIsNotTheOneAStateNamesDoesNotStartAnotherRound() async throws {
        try readOffline()
        serve(holding: [DisplayedState(peer: alice, stanzaId: "unknown", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        _ = await eventually(timeout: 0.5) { false }
        #expect(owed)
        // Stored without ingest, which would start the round that finds it.
        try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "reply",
                              timestamp: Date(timeIntervalSince1970: 10), serverId: "unknown"))
        let other: Martin.Message = parseStanza("<message from='alice@example.org/phone' type='chat' id='other'><body>hi</body><stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='other'/></message>")
        session.handle(other, source: .live)
        _ = await eventually(timeout: 0.5) { false }
        #expect(owed)
        #expect(publishes().isEmpty)
    }

    @Test func aMessageThatGainsTheStanzaIdAStateNamesStartsAnotherRound() async throws {
        try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "reply",
                              timestamp: Date(timeIntervalSince1970: 10), status: .sent, remoteId: "r1"))
        try readOffline()
        serve(holding: [DisplayedState(peer: alice, stanzaId: "unknown", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        _ = await eventually(timeout: 0.5) { false }
        #expect(owed)
        // Our own message, as the archive has it, which only gives the stored one its stanza-id.
        let copy: Martin.Message = parseStanza("<message from='me@example.org/phone' to='alice@example.org' type='chat' id='r1'><body>reply</body></message>")
        session.handle(copy, source: .archive(serverId: "unknown", timestamp: Date(timeIntervalSince1970: 10)))
        session.flushArchive()
        #expect(await eventually { !owed })
        #expect(publishes().isEmpty)
    }

    @Test func aNewerMessageOfOursNamedByAnotherDeviceIsNotPublishedOver() async throws {
        try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "reply",
                              timestamp: Date(timeIntervalSince1970: 10), serverId: "mine"))
        try readOffline()
        serve(holding: [DisplayedState(peer: alice, stanzaId: "mine", by: me)])
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { !owed })
        #expect(publishes().isEmpty)
    }

    @Test func aPushedStateOfANewerMessageClearsWhatWasOwed() async throws {
        try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "reply",
                              timestamp: Date(timeIntervalSince1970: 10), serverId: "mine"))
        try readOffline()
        session.displayedChanged(DisplayedState(peer: alice, stanzaId: "mine", by: me))
        #expect(!owed)
    }

    @Test func aPushedStateOlderThanOursLeavesItOwed() async throws {
        try readOffline()
        session.displayedChanged(DisplayedState(peer: alice, stanzaId: "s1", by: me))
        #expect(owed)
    }

    @Test func aServerWithoutReadStateSyncLetsGoOfWhatWasOwed() async throws {
        try readOffline()
        wire.answer { iq in
            iq.firstChild(name: "pubsub") != nil ? FakeWire.error(to: iq, condition: "service-unavailable") : nil
        }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { !owed })
        #expect(publishes().isEmpty)
    }

    @Test func aFailedReadKeepsWhatWasOwed() async throws {
        try readOffline()
        wire.answer { iq in
            iq.firstChild(name: "pubsub") != nil ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : nil
        }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        _ = await eventually(timeout: 0.5) { false }
        #expect(owed)
    }

    @Test func aRefusalForGoodDropsWhatWasOwedAndIsShown() async throws {
        try readOffline()
        serve { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { session.warnings.current.map(\.key) == ["readState:\(alice)"] && !owed })
    }

    @Test func aPassingErrorKeepsItOwedForTheNextConnect() async throws {
        try readOffline()
        serve { FakeWire.error(to: $0, condition: "resource-constraint", type: "wait") }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { publishes().count == 1 })
        _ = await eventually(timeout: 0.3) { false }
        #expect(owed)
        #expect(session.warnings.current.isEmpty)
        // The next connect, with the server taking it now.
        serve()
        session.fetchDisplayed()
        #expect(await eventually { !owed })
    }

    /// `count` more chats, each with a message read offline.
    private func readMoreChatsOffline(_ count: Int) throws -> [Conversation] {
        try (0..<count).map { index in
            let peer = YapnestKit.JID("friend\(index)@example.org")!
            let chat = try db.conversation(with: peer)
            try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: peer, body: "m", timestamp: Date(), serverId: "f\(index)"))
            try session.markRead(chat)
            return chat
        }
    }

    private func isOwed(_ chat: Conversation) -> Bool {
        (try? db.reader.read { try Conversation.fetchOne($0, key: chat.id!)?.readStateOwed }) ?? false
    }

    @Test func manyOwedChatsArePublishedTogetherFourAtATime() async throws {
        try readOffline()
        let chats = try readMoreChatsOffline(9)
        wire.holdReplies { $0.firstChild(name: "pubsub")?.firstChild(name: "publish") != nil }
        serve()
        session.connectForTesting(wire)
        session.fetchDisplayed()
        // Four in flight while the server holds its answers, and no fifth.
        #expect(await eventually { publishes().count == 4 })
        _ = await eventually(timeout: 0.3) { false }
        #expect(publishes().count == 4)
        wire.releasePings()
        // As answers come, the rest follow; none is ever the fifth in flight.
        for _ in 0..<5 {
            _ = await eventually(timeout: 0.2) { false }
            #expect(wire.heldPings <= 4)
            wire.releasePings()
        }
        #expect(await eventually { publishes().count == 10 && !owed && chats.allSatisfy { !isOwed($0) } })
        #expect(Set(publishedStanzaIds()) == Set(["s3"] + (0..<9).map { "f\($0)" }))
    }

    @Test func publishesTheNodeRefusesTogetherReconfigureItOnce() async throws {
        try readOffline()
        _ = try readMoreChatsOffline(3)
        @Sendable func withOptions(_ iq: Iq) -> Bool {
            iq.firstChild(name: "pubsub")?.firstChild(name: "publish-options") != nil
        }
        // All four are in flight before any is refused, as the node was made with other options.
        wire.holdReplies { iq in
            iq.firstChild(name: "pubsub")?.firstChild(name: "publish") != nil && withOptions(iq)
        }
        wire.answer { iq in
            guard let pubsub = iq.firstChild(name: "pubsub") else { return nil }
            if pubsub.firstChild(name: "publish") != nil, withOptions(iq) { return FakeWire.error(to: iq, condition: "conflict") }
            if pubsub.firstChild(name: "items") != nil {
                return FakeWire.result(to: iq, Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [Element(name: "items", attributes: ["node": NS.mds])]))
            }
            return FakeWire.result(to: iq)
        }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { publishes().count == 4 })
        wire.releasePings()
        #expect(await eventually { publishes().count == 8 && !owed })
        _ = await eventually(timeout: 0.3) { false }
        let configures = wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "pubsub")?.firstChild(name: "configure") != nil }
        #expect(configures.count == 1)
    }

    /// A configuration sent on a stream that ended goes unanswered, so one
    /// asked for on the next stream is sent again rather than waiting on it,
    /// and the old one ending later leaves the new one shared.
    @Test func aNewStreamConfiguresTheNodeAgain() async throws {
        let configures: @Sendable () -> Int = { [wire] in
            wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "pubsub")?.firstChild(name: "configure") != nil }.count
        }
        wire.answer { FakeWire.result(to: $0) }
        wire.holdReplies { $0.firstChild(name: "pubsub")?.firstChild(name: "configure") != nil }
        session.connectForTesting(wire)
        let fields = ["pubsub#access_model": ["whitelist"]]
        let first = Task { [session] in try await session.configurePEPNode(NS.mds, fields: fields) }
        #expect(await eventually { configures() == 1 })
        session.client.update(state: .disconnected())
        session.client.update(state: .connected(resumed: false))
        #expect(await eventually("the new session") { session.lock.withLock { $0.isSyncing } })
        let second = Task { [session] in try await session.configurePEPNode(NS.mds, fields: fields) }
        #expect(await eventually { configures() == 2 })
        wire.releaseOldestHeld()
        _ = await first.result
        let third = Task { [session] in try await session.configurePEPNode(NS.mds, fields: fields) }
        _ = await eventually(timeout: 0.3) { false }
        #expect(configures() == 2)
        wire.releasePings()
        _ = await second.result
        _ = await third.result
    }

    @Test func aChatAnotherDeviceReadWhileTheEarlierPublishesWereInFlightIsNotPublishedOver() async throws {
        try readOffline()
        let chats = try readMoreChatsOffline(4)
        wire.holdReplies { $0.firstChild(name: "pubsub")?.firstChild(name: "publish") != nil }
        serve()
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { publishes().count == 4 })
        // The fifth chat was decided with the rest, and is read through its newest message elsewhere.
        for (index, chat) in chats.enumerated() {
            session.displayedChanged(DisplayedState(peer: chat.peer, stanzaId: "f\(index)", by: me))
        }
        session.displayedChanged(DisplayedState(peer: alice, stanzaId: "s3", by: me))
        wire.releasePings()
        #expect(await eventually { !owed && chats.allSatisfy { !isOwed($0) } })
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishes().count == 4)
    }

    @Test func oneChatsSuccessKeepsAnotherChatsRefusalShown() async throws {
        try readOffline()
        _ = try readMoreChatsOffline(1)
        @Sendable func stanzaId(_ iq: Iq) -> String? {
            iq.firstChild(name: "pubsub")?.firstChild(name: "publish")?.firstChild(name: "item")?.firstChild(name: "displayed")?.firstChild(name: "stanza-id")?.attribute("id")
        }
        // The success comes after the refusal.
        wire.holdReplies { stanzaId($0) == "f0" }
        serve { iq in stanzaId(iq) == "s3" ? FakeWire.error(to: iq, condition: "forbidden", type: "auth") : FakeWire.result(to: iq) }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { session.warnings.current.map(\.key) == ["readState:\(alice)"] })
        #expect(await eventually { wire.heldPings == 1 })
        wire.releasePings()
        #expect(await eventually { !isOwed(try! db.conversation(with: YapnestKit.JID("friend0@example.org")!)) })
        #expect(session.warnings.current.map(\.key) == ["readState:\(alice)"])
    }

    @Test func aChatTheServerRefusesDoesNotStopTheOthers() async throws {
        try readOffline()
        let chats = try readMoreChatsOffline(5)
        serve { iq in
            let id = iq.firstChild(name: "pubsub")?.firstChild(name: "publish")?.firstChild(name: "item")?.firstChild(name: "displayed")?.firstChild(name: "stanza-id")?.attribute("id")
            return id == "f1" ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : FakeWire.result(to: iq)
        }
        session.connectForTesting(wire)
        session.fetchDisplayed()
        #expect(await eventually { publishes().count == 6 && !owed })
        #expect(await eventually { chats.enumerated().allSatisfy { $0.offset == 1 ? isOwed($0.element) : !isOwed($0.element) } })
    }

    @Test func anExtensionLeavesItToTheApp() async throws {
        let quiet = try makeSession(me, database: db, mode: .notificationService)
        try db.markRead(conversationId: conversation.id!, owingReadState: true)
        serve()
        quiet.connectForTesting(wire)
        quiet.fetchDisplayed()
        _ = await eventually(timeout: 0.5) { false }
        #expect(publishes().isEmpty)
        #expect(owed)
    }

    @Test func readingNothingNewOwesNothing() throws {
        try db.markRead(conversationId: conversation.id!, owingReadState: true)
        try db.markRead(conversationId: conversation.id!)
        try db.clearReadStateOwed(conversationId: conversation.id!, ifNewest: nil)
        try db.markRead(conversationId: conversation.id!, owingReadState: true)
        #expect(!owed)
    }

    @Test func theColumnIsAddedToADatabaseFromBefore() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v50-query-indices")
        try queue.write { try $0.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt, isPinned, isArchived, isEncrypted, historyComplete) VALUES ('a@example.org', 'chat', 0, 0, 0, 1, 0)") }
        try AppDatabase.migrator.migrate(queue)
        #expect(try queue.read { try Bool.fetchOne($0, sql: "SELECT readStateOwed FROM conversation") } == false)
    }
}
