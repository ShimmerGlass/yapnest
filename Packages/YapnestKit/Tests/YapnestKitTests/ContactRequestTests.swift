import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// Presence subscription requests from people we haven't added.
struct ContactRequestTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let stranger = JID("stranger@example.net")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func requests() throws -> [Contact] {
        try db.reader.read(AppDatabase.contactRequests)
    }

    @Test func repeatedRequestKeepsItsFirstDate() throws {
        let first = Date(timeIntervalSince1970: 1000)
        try db.recordContactRequest(from: stranger, nickname: "Stranger", at: first)
        try db.recordContactRequest(from: stranger, nickname: nil, at: first.addingTimeInterval(60))
        let contact = try #require(try db.contact(stranger))
        #expect(contact.subscriptionRequestedAt == first)
        #expect(contact.requestedNickname == "Stranger")
        #expect(contact.hasContactRequest)
        #expect(!contact.isInRoster)
        #expect(try requests().map(\.jid) == [stranger])
    }

    @Test func approvalOnAnotherDeviceAnswersIt() throws {
        try db.recordContactRequest(from: alice, nickname: nil)
        // Our own request, pending, doesn't answer theirs.
        try db.updateRosterItem(jid: alice, name: nil, subscription: .none, isPending: true)
        #expect(try db.contact(alice)?.hasContactRequest == true)
        try db.updateRosterItem(jid: alice, name: "Alice", subscription: .from, isPending: true)
        #expect(try db.contact(alice)?.hasContactRequest == false)
        #expect(try requests().isEmpty)
    }

    @Test func blockedRequestsAreHidden() throws {
        try db.recordContactRequest(from: stranger, nickname: nil)
        try db.setBlocklist([stranger])
        #expect(try requests().isEmpty)
        #expect(try db.contact(stranger)?.hasContactRequest == false)
    }

    @Test func requestsTheServerDidntRepeatAreDropped() throws {
        try db.recordContactRequest(from: stranger, nickname: "Stranger")
        try db.recordContactRequest(from: alice, nickname: nil)
        try db.clearContactRequests(except: [alice])
        #expect(try requests().map(\.jid) == [alice])
        #expect(try db.contact(stranger)?.requestedNickname == nil)
    }

    // MARK: Session

    @Test func answeringOrRemovingOffline() async throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        try db.recordContactRequest(from: stranger, nickname: nil)
        await #expect(throws: XMPPSession.ContactError.self) { try await session.removeContact(alice) }
        #expect(throws: XMPPSession.ContactError.self) { try session.acceptContactRequest(from: stranger) }
        #expect(throws: XMPPSession.ContactError.self) { try session.declineContactRequest(from: stranger) }
        // The request waits for the user to try again.
        #expect(try db.contact(stranger)?.hasContactRequest == true)
    }

    @Test func addingAndWaitingSendsTheRequestOnceTheRosterAnswers() async throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { FakeWire.result(to: $0) }
        try await session.addContactAndWait(alice, name: "Ally", preauth: "tok")
        let item = wire.written.compactMap { $0 as? Iq }
            .filter { $0.type == .set }
            .compactMap { $0.firstChild(name: "query", xmlns: "jabber:iq:roster")?.firstChild(name: "item") }
        #expect(item.map { $0.attribute("jid") } == ["alice@example.org"])
        #expect(item.first?.attribute("name") == "Ally")
        let presences = wire.written.compactMap { $0 as? Presence }
        #expect(presences.contains { $0.type == .subscribe && $0.to?.bareJid.description == "alice@example.org" })
        #expect(try db.contact(alice)?.isAddedByUser == true)
    }

    @Test func addingAndWaitingFailsWhenTheRosterRefuses() async throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { FakeWire.error(to: $0, condition: "forbidden") }
        await #expect(throws: (any Error).self) { try await session.addContactAndWait(alice) }
        #expect(!wire.written.contains { ($0 as? Presence)?.type == .subscribe })
        #expect(try !db.hasApprovedOrAdded(alice))
    }

    @Test func addingAndWaitingOfflineThrows() async throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        await #expect(throws: XMPPSession.ContactError.self) { try await session.addContactAndWait(alice) }
        #expect(try db.contact(alice) == nil)
    }

    @Test func befriendingOfflineChangesNothing() throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        try db.recordContactRequest(from: stranger, nickname: nil)
        session.befriendForNewChat(stranger)
        session.befriendForNewChat(alice)
        #expect(try db.contact(stranger)?.hasContactRequest == true)
        #expect(try db.contact(alice) == nil)
    }

    @Test func pruningKeepsOnlyRequestsTheServerRepeated() throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        try db.recordContactRequest(from: stranger, nickname: nil)
        try db.recordContactRequest(from: alice, nickname: nil)
        session.lock.withLock {
            $0.prunesContactRequests = true
            $0.repeatedContactRequests = [alice]
        }
        session.pruneContactRequests()
        #expect(try requests().map(\.jid) == [alice])
    }

    @Test func pruningWaitsForANewSessionAndRunsOnce() throws {
        let session = try makeSession(JID("me@example.org")!, database: db)
        try db.recordContactRequest(from: stranger, nickname: nil)
        // Not after a new session's presence: a request arriving later isn't pruned.
        session.pruneContactRequests()
        #expect(try requests().map(\.jid) == [stranger])
        session.lock.withLock { $0.prunesContactRequests = true }
        session.pruneContactRequests()
        #expect(try requests().isEmpty)
        try db.recordContactRequest(from: alice, nickname: nil)
        session.pruneContactRequests()
        #expect(try requests().map(\.jid) == [alice])
    }
}

/// Whether a `subscribe` is answered by itself or waits for the user.
/// Being in the roster is no consent: Openfire puts a stranger there when
/// they send `subscribed` unasked.
struct SubscribeConsentTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let carol = YapnestKit.JID("carol@example.net")!

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(YapnestKit.JID("me@example.org")!, database: db)
        session.connectForTesting(wire)
    }

    /// The server delivers their request to the session's presence module.
    private func subscribe(from jid: YapnestKit.JID) throws {
        let presence = Presence()
        presence.from = Martin.JID(jid.martin)
        presence.type = .subscribe
        try session.client.module(.presence).process(stanza: presence)
    }

    private var approvals: [Presence] {
        wire.written.compactMap { $0 as? Presence }.filter { $0.type == .subscribed }
    }

    @Test func aRosterItemTheServerMadeIsNotConsent() throws {
        for subscription in [Contact.Subscription.to, .none] {
            try db.updateRosterItem(jid: carol, name: nil, subscription: subscription, isPending: false)
            try subscribe(from: carol)
            #expect(approvals.isEmpty)
            #expect(try db.contact(carol)?.hasContactRequest == true)
            try db.clearContactRequest(from: carol)
        }
    }

    @Test func someoneTheUserAddedIsApproved() throws {
        wire.answer { FakeWire.result(to: $0) }
        session.addContact(carol)
        let sentByAdding = approvals.count
        try db.updateRosterItem(jid: carol, name: nil, subscription: .to, isPending: false)
        try subscribe(from: carol)
        #expect(approvals.count == sentByAdding + 1)
        #expect(try db.contact(carol)?.hasContactRequest == false)
    }

    @Test func someoneAlreadyApprovedIsApproved() throws {
        for subscription in [Contact.Subscription.from, .both] {
            let before = approvals.count
            try db.updateRosterItem(jid: carol, name: nil, subscription: subscription, isPending: false)
            try subscribe(from: carol)
            #expect(approvals.count == before + 1)
            #expect(try db.contact(carol)?.hasContactRequest == false)
        }
    }

    @Test func aPendingRequestOfOursIsAnsweredByTheirs() throws {
        try db.updateRosterItem(jid: carol, name: nil, subscription: .none, isPending: true)
        try subscribe(from: carol)
        #expect(approvals.count == 1)
        #expect(try db.contact(carol)?.hasContactRequest == false)
    }

    @Test func subscriptionToWithoutAskOrFlagIsARequest() throws {
        try db.updateRosterItem(jid: carol, name: nil, subscription: .to, isPending: false)
        #expect(try db.contact(carol)?.isAddedByUser == false)
        try subscribe(from: carol)
        #expect(approvals.isEmpty)
        #expect(try db.contact(carol)?.hasContactRequest == true)
    }

    @Test func someoneNotInTheRosterIsARequest() throws {
        try subscribe(from: carol)
        #expect(approvals.isEmpty)
        #expect(try db.contact(carol)?.hasContactRequest == true)
    }

    @Test func removingAContactForgetsThatTheUserAddedThem() throws {
        try db.markAddedByUser(carol)
        #expect(try db.hasApprovedOrAdded(carol))
        try db.updateRosterItem(jid: carol, name: nil, subscription: .to, isPending: false)
        #expect(try db.hasApprovedOrAdded(carol))
        try db.removeRosterItem(jid: carol)
        #expect(try !db.hasApprovedOrAdded(carol))
        try subscribe(from: carol)
        #expect(approvals.isEmpty)
        #expect(try db.contact(carol)?.hasContactRequest == true)
    }

    @Test func theFlagStartsOffForContactsFromBeforeTheMigration() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v19-pending-reactions")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO contact (jid, subscription, isSubscriptionPending, isInRoster, isBlocked) VALUES ('carol@example.net', 'both', 0, 1, 0)")
        }
        try AppDatabase.migrator.migrate(queue)
        let contact = try #require(try queue.read { try Contact.fetchOne($0, key: carol) })
        #expect(!contact.isAddedByUser)
        #expect(contact.subscription == .both)
    }
}
