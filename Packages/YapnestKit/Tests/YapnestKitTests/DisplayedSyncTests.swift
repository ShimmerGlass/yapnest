import Foundation
import GRDB
import Martin
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
