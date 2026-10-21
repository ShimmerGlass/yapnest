import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func parse(_ xml: String, source: InboundMessage.Source = .live) throws -> InboundMessage {
    let stanza = Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
    return try #require(InboundMessage(stanza, account: me, source: source))
}

private let body = "<message from='alice@example.org/phone' type='chat' id='m'><body>hi</body></message>"
private let bodyWithState = "<message from='alice@example.org/phone' type='chat' id='m'><body>hi</body><active xmlns='http://jabber.org/protocol/chatstates'/></message>"
private let stateOnly = "<message from='alice@example.org/phone' type='chat'><composing xmlns='http://jabber.org/protocol/chatstates'/></message>"
private let receipt = "<message from='alice@example.org/phone' type='chat' id='r'><received xmlns='urn:xmpp:receipts' id='x'/></message>"

/// What the session learns about a contact's use of chat states, which needs
/// no connection.
struct ChatStateSessionTests {
    let database: AppDatabase
    let session: XMPPSession

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
    }

    private func addAliceToRoster() throws {
        try database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
    }

    private func tracker() -> ChatStateTracker? {
        session.lock.withLock { $0.chatStates[alice] }
    }

    @Test func messagesWithAStateShowSupport() throws {
        session.noteChatStates(of: try parse(bodyWithState), source: .live)
        #expect(tracker()?.supported == true)
        session.noteChatStates(of: try parse(stateOnly), source: .live)
        #expect(tracker()?.supported == true)
    }

    @Test func messagesWithoutOneShowNone() throws {
        session.noteChatStates(of: try parse(body), source: .live)
        #expect(tracker()?.supported == false)
        // Until they use one.
        session.noteChatStates(of: try parse(bodyWithState), source: .live)
        #expect(tracker()?.supported == true)
    }

    @Test func receiptsSayNothing() throws {
        session.noteChatStates(of: try parse(receipt), source: .live)
        #expect(tracker() == nil)
    }

    @Test func onlyWhatTheyJustSentCounts() throws {
        session.noteChatStates(of: try parse(body, source: .archive(serverId: "s", timestamp: nil)), source: .archive(serverId: "s", timestamp: nil))
        #expect(tracker() == nil)
        session.noteChatStates(of: try parse(body), source: .carbon(sent: true))
        #expect(tracker() == nil)
        // A received carbon is from one of their devices, just now.
        let carbon = "<message from='alice@example.org/phone' to='me@example.org/laptop' type='chat' id='m'><body>hi</body></message>"
        session.noteChatStates(of: try parse(carbon, source: .carbon(sent: false)), source: .carbon(sent: false))
        #expect(tracker()?.supported == false)
    }

    @Test func correctionsSayNothing() throws {
        let correction = "<message from='alice@example.org/phone' type='chat' id='c'><body>fixed</body><replace xmlns='urn:xmpp:message-correct:0' id='m'/></message>"
        session.noteChatStates(of: try parse(correction), source: .live)
        #expect(tracker() == nil)
    }

    @Test func ourOwnMessagesSayNothing() throws {
        let sent = "<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='o'><body>hi</body></message>"
        session.noteChatStates(of: try parse(sent, source: .carbon(sent: true)), source: .carbon(sent: true))
        #expect(tracker() == nil)
    }

    @Test func activeIsIncludedUntilTheyShowTheyDontUseStates() throws {
        try addAliceToRoster()
        #expect(session.includesActiveState(to: alice))
        #expect(tracker()?.sent == .active)
        session.noteChatStates(of: try parse(body), source: .live)
        #expect(!session.includesActiveState(to: alice))
        session.noteChatStates(of: try parse(bodyWithState), source: .live)
        #expect(session.includesActiveState(to: alice))
    }

    @Test func activeIsLeftOutWhenTheUserTurnedStatesOff() throws {
        try addAliceToRoster()
        try session.setSendsChatStates(false)
        #expect(!session.includesActiveState(to: alice))
        #expect(tracker() == nil)
        try session.setSendsChatStates(true)
        #expect(session.includesActiveState(to: alice))
    }

    @Test func activeIsLeftOutForSomeoneNotInTheRoster() throws {
        let stranger = YapnestKit.JID("mallory@example.org")!
        #expect(!session.includesActiveState(to: stranger))
        #expect(session.lock.withLock { $0.chatStates[stranger] } == nil)
    }

    @Test func activeIsLeftOutFromASessionThatSendsNoStates() throws {
        try addAliceToRoster()
        let share = try XMPPSession(credentials: .init(jid: me, password: "x"), resource: "share", database: database, mode: .share)
        #expect(!share.includesActiveState(to: alice))
    }

    @Test func sendingNothingWhileDisconnected() throws {
        session.noteChatStates(of: try parse(bodyWithState), source: .live)
        session.sendChatState(.composing, to: alice)
        // Not connected, so nothing went out and nothing is recorded as sent.
        #expect(tracker()?.sent == nil)
    }

    // MARK: What would be sent

    private func befriendAndLearnSupport() throws {
        try addAliceToRoster()
        session.noteChatStates(of: try parse(bodyWithState), source: .live)
    }

    @Test func pausedIsOnlySentAfterComposing() throws {
        try befriendAndLearnSupport()
        #expect(session.claimChatState(.paused, to: alice) == nil)
        #expect(session.claimChatState(.composing, to: alice) != nil)
        #expect(session.claimChatState(.paused, to: alice) != nil)
        #expect(tracker()?.sent == .paused)
    }

    @Test func theSameStateIsNotSentTwice() throws {
        try befriendAndLearnSupport()
        #expect(session.claimChatState(.composing, to: alice) != nil)
        #expect(session.claimChatState(.composing, to: alice) == nil)
        #expect(session.claimChatState(.active, to: alice) != nil)
        #expect(session.claimChatState(.composing, to: alice) != nil)
    }

    @Test func nothingGoesToAContactWhoDoesntUseStates() throws {
        try addAliceToRoster()
        #expect(session.claimChatState(.composing, to: alice) == nil)
        session.noteChatStates(of: try parse(body), source: .live)
        #expect(session.claimChatState(.composing, to: alice) == nil)
    }

    @Test func nothingGoesToAContactOutsideTheRoster() throws {
        session.noteChatStates(of: try parse(bodyWithState), source: .live)
        #expect(session.claimChatState(.composing, to: alice) == nil)
        try addAliceToRoster()
        #expect(session.claimChatState(.composing, to: alice) != nil)
    }

    @Test func nothingGoesToAGroup() throws {
        let room = YapnestKit.JID("room@conference.example.org")!
        try database.updateRosterItem(jid: room, name: nil, subscription: .both, isPending: false)
        session.lock.withLock {
            $0.knownRooms.insert(room)
            $0.chatStates[room] = ChatStateTracker(supported: true)
        }
        #expect(session.claimChatState(.composing, to: room) == nil)
    }

    @Test func turningStatesOffStopsThem() throws {
        try befriendAndLearnSupport()
        try session.setSendsChatStates(false)
        #expect(session.claimChatState(.composing, to: alice) == nil)
        try session.setSendsChatStates(true)
        #expect(session.claimChatState(.composing, to: alice) != nil)
    }

    // MARK: Gone

    @Test func goneFollowsTheLatestInactiveNotAnEarlierOne() async throws {
        try befriendAndLearnSupport()
        let first = try #require(session.claimChatState(.inactive, to: alice))
        #expect(session.claimChatState(.active, to: alice) != nil)
        let second = try #require(session.claimChatState(.inactive, to: alice))
        #expect(second != first)

        // The first timer fires while the second inactive is the one that counts.
        session.scheduleGone(to: alice, generation: first, after: 0.05)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tracker()?.sent == .inactive)

        session.scheduleGone(to: alice, generation: second, after: 0.05)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tracker()?.sent == .gone)
    }

    @Test func goneIsNotSentToAChatWeCameBackTo() async throws {
        try befriendAndLearnSupport()
        let generation = try #require(session.claimChatState(.inactive, to: alice))
        #expect(session.claimChatState(.active, to: alice) != nil)
        session.scheduleGone(to: alice, generation: generation, after: 0.05)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tracker()?.sent == .active)
    }

    // MARK: Read markers

    private func ingestMarkable(_ id: String) throws -> Int64 {
        let xml = "<message from='alice@example.org/phone' type='chat' id='\(id)'><body>hi</body><markable xmlns='urn:xmpp:chat-markers:0'/></message>"
        try database.ingest(try parse(xml))
        return try #require(try database.reader.read { try Conversation.fetchOne($0) }?.id)
    }

    @Test func aMessageIsMarkedDisplayedOnce() throws {
        try addAliceToRoster()
        let id = try ingestMarkable("m1")
        #expect(session.claimDisplayed(conversationId: id, to: alice, through: .distantFuture) == "m1")
        #expect(session.claimDisplayed(conversationId: id, to: alice, through: .distantFuture) == nil)
        _ = try ingestMarkable("m2")
        #expect(session.claimDisplayed(conversationId: id, to: alice, through: .distantFuture) == "m2")
    }

    @Test func markersGoOnlyToTheRosterAndWhenOn() throws {
        let id = try ingestMarkable("m1")
        #expect(session.claimDisplayed(conversationId: id, to: alice, through: .distantFuture) == nil)
        try addAliceToRoster()
        try session.setSendsReadMarkers(false)
        #expect(session.claimDisplayed(conversationId: id, to: alice, through: .distantFuture) == nil)
        try session.setSendsReadMarkers(true)
        #expect(session.claimDisplayed(conversationId: id, to: alice, through: .distantFuture) == "m1")
    }
}
