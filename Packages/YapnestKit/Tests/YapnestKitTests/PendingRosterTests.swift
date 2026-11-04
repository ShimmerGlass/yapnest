import Foundation
import GRDB
import os
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

/// Roster changes and answers to contact requests made offline are kept until
/// the server confirms them.
struct PendingRosterTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let alice = YapnestKit.JID("alice@example.org")!
    let stranger = YapnestKit.JID("stranger@example.net")!

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(YapnestKit.JID("me@example.org")!, database: db)
        session.lock.withLock { $0.retryBackoff = 0 }
        try db.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false, groups: ["Friends"])
        try db.recordContactRequest(from: stranger, nickname: "Stranger")
    }

    private func isRosterIq(_ iq: Iq) -> Bool { iq.firstChild(name: "query", xmlns: "jabber:iq:roster") != nil }

    private var rosterSets: [Element] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.type == .set }
            .compactMap { $0.firstChild(name: "query", xmlns: "jabber:iq:roster")?.firstChild(name: "item") }
    }

    private func presences(_ type: StanzaType) -> [Presence] { wire.written.compactMap { $0 as? Presence }.filter { $0.type == type } }

    private var queued: [PendingRosterChange] { (try? db.pendingRosterChanges()) ?? [] }

    private func connect(answering answer: @escaping @Sendable (Iq) -> Iq = { FakeWire.result(to: $0) }) {
        wire.answer { iq in self.isRosterIq(iq) && iq.type == .set ? answer(iq) : FakeWire.result(to: iq) }
        session.connectForTesting(wire)
    }

    private func contact(_ jid: YapnestKit.JID) throws -> Contact { try #require(try db.contact(jid)) }

    // MARK: Queued while offline

    @Test func anAcceptMadeOfflineWaitsOnTheListAndIsSentOnConnect() async throws {
        try await session.acceptContactRequest(from: stranger)
        #expect(queued.map(\.kind) == [.accept])
        let waiting = try contact(stranger)
        #expect(waiting.hasContactRequest)
        #expect(waiting.pendingRoster == .accept)
        #expect(try await db.reader.read(AppDatabase.contactRequests).map(\.jid) == [stranger])
        #expect(wire.written.isEmpty)

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        let done = try contact(stranger)
        #expect(!done.hasContactRequest)
        #expect(done.pendingRoster == nil)
        #expect(done.isAddedByUser)
        #expect(rosterSets.map { $0.attribute("jid") } == ["stranger@example.net"])
        #expect(presences(.subscribe).count == 1)
    }

    @Test func aDeclineMadeOfflineWaitsAndIsSentOnConnect() async throws {
        try session.declineContactRequest(from: stranger)
        #expect(try contact(stranger).pendingRoster == .decline)
        #expect(try contact(stranger).hasContactRequest)

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(try !contact(stranger).hasContactRequest)
        #expect(presences(.unsubscribed).count == 1)
    }

    @Test func aRemovalMadeOfflineKeepsTheContactUntilSent() async throws {
        try await session.removeContact(alice)
        #expect(try contact(alice).isInRoster)
        #expect(try contact(alice).pendingRoster == .remove)

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(try !contact(alice).isInRoster)
        #expect(try contact(alice).pendingRoster == nil)
        #expect(wire.written.compactMap { $0 as? Iq }.contains { $0.firstChild(name: "query", xmlns: "jabber:iq:roster")?.firstChild(name: "item")?.attribute("subscription") == "remove" })
    }

    @Test func aRenameMadeOfflineShowsTheNameAtOnceAndSendsItWithTheGroups() async throws {
        try await session.setContactName(alice, name: "  Ally  ")
        let waiting = try contact(alice)
        #expect(waiting.displayName == "Ally")
        #expect(waiting.name == "Alice")
        #expect(waiting.pendingRename)

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.first?.attribute("name") == "Ally")
        #expect(rosterSets.first?.filterChildren(name: "group", xmlns: nil).compactMap(\.value) == ["Friends"])
        #expect(try !contact(alice).pendingRename)
    }

    @Test func aRenameBackToTheirOwnNameShowsTheNameTheyPublish() async throws {
        try await db.writer.write { db in try AppDatabase.updateContact(db, alice) { $0.nickname = "Alice L." ; $0.isAddedByUser = true } }
        try await session.setContactName(alice, name: " ")
        #expect(try contact(alice).displayName == "Alice L.")
    }

    @Test func aRenameOfSomeoneNotInTheRosterIsRefusedAtOnce() async throws {
        await #expect(throws: XMPPSession.ContactError.self) { try await session.setContactName(stranger, name: "Nope") }
        #expect(queued.isEmpty)
    }

    @Test func changesAreSentInTheOrderTheyWereMade() async throws {
        let bob = YapnestKit.JID("bob@example.org")!
        try db.updateRosterItem(jid: bob, name: nil, subscription: .both, isPending: false)
        try await session.removeContact(bob)
        try await session.setContactName(alice, name: "Ally")
        try await session.acceptContactRequest(from: stranger)
        #expect(queued.map(\.kind) == [.remove, .rename, .accept])
        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.map { $0.attribute("jid") } == ["bob@example.org", "alice@example.org", "stranger@example.net"])
    }

    @Test func aChangeMadeOnlineIsSentAtOnce() async throws {
        connect()
        try await session.setContactName(alice, name: "Ally")
        #expect(await eventually { queued.isEmpty && rosterSets.count == 1 })
    }

    // MARK: Replacement

    @Test func aLaterRenameReplacesAQueuedOne() async throws {
        try await session.setContactName(alice, name: "Ally")
        try await session.setContactName(alice, name: "Al")
        #expect(queued.map(\.name) == ["Al"])
        #expect(try contact(alice).displayName == "Al")
    }

    @Test func aRemovalDropsQueuedRenamesOfThem() async throws {
        try await session.setContactName(alice, name: "Ally")
        try await session.removeContact(alice)
        #expect(queued.map(\.kind) == [.remove])
        #expect(try !contact(alice).pendingRename)
        #expect(try contact(alice).displayName == "Alice")
    }

    @Test func aLaterAnswerReplacesAQueuedOne() async throws {
        try await session.acceptContactRequest(from: stranger)
        try session.declineContactRequest(from: stranger)
        #expect(queued.map(\.kind) == [.decline])
        #expect(try contact(stranger).pendingRoster == .decline)
    }

    @Test func aChangeBeingSentIsNotReplaced() async throws {
        try await session.setContactName(alice, name: "Ally")
        let once = OSAllocatedUnfairLock(initialState: false)
        session.afterRosterChangeChosenForTesting = { [session, alice] in
            guard once.withLock({ defer { $0 = true }; return !$0 }) else { return }
            // Between the sender's choice and its marking: the queue's lock holds this back.
            Task { try? await session.setContactName(alice, name: "Al") }
        }
        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty && rosterSets.count == 2 })
        #expect(rosterSets.map { $0.attribute("name") } == ["Ally", "Al"])
    }

    @Test func anAcceptQueuedWhileTheDeclineIsBeingSentIsStillSent() async throws {
        try session.declineContactRequest(from: stranger)
        let declining = try #require(queued.first?.id)
        let once = OSAllocatedUnfairLock(initialState: false)
        // Queued after the decline was chosen and before it is sent, as the queue's lock allows.
        session.afterRosterChangeChosenForTesting = { [db, stranger] in
            guard once.withLock({ defer { $0 = true }; return !$0 }) else { return }
            try? db.queueRosterChange(stranger, kind: .accept, inFlight: declining)
        }
        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty && rosterSets.map { $0.attribute("jid") } == ["stranger@example.net"] })
        #expect(presences(.unsubscribed).count == 1)
        #expect(try !contact(stranger).hasContactRequest)
    }

    @Test func aRenameQueuedWhileAnotherIsOnItsWayFollowsIt() async throws {
        try await session.setContactName(alice, name: "Ally")
        let first = try #require(queued.first?.id)
        session.lock.withLock { $0.rosterInFlight = first }
        try await session.setContactName(alice, name: "Al")
        #expect(queued.map(\.name) == ["Ally", "Al"])
        try await session.setContactName(alice, name: "A")
        #expect(queued.map(\.name) == ["Ally", "A"])
        try await session.removeContact(alice)
        #expect(queued.map(\.kind) == [.rename, .remove])
    }

    // MARK: Errors

    @Test func aRefusalForGoodPutsItBackAsItWasAndOffersRetry() async throws {
        try await session.acceptContactRequest(from: stranger)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        let back = try contact(stranger)
        #expect(back.hasContactRequest)
        #expect(back.pendingRoster == nil)
        #expect(presences(.subscribe).isEmpty)
        let warning = try #require(session.warnings.current.first)
        #expect(warning.key == "roster/stranger@example.net")
        #expect(warning.detail.contains("forbidden"))

        wire.answer { FakeWire.result(to: $0) }
        #expect(await session.warnings.retry(warning.key))
        #expect(await eventually { (try? contact(stranger).hasContactRequest) == false })
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aRetryWaitsForTheServerAndThrowsItsRefusal() async throws {
        try await session.acceptContactRequest(from: stranger)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        let retry = try #require(session.warnings.current.first?.retry)

        // Still refused: the Retry itself reports it, not a new warning later.
        let error = await #expect(throws: (any Error).self) { try await retry() }
        #expect(ServerError.userMessage(for: try #require(error), friendly: "").contains("forbidden"))
        #expect(queued.isEmpty)
        #expect(try contact(stranger).hasContactRequest)

        wire.answer { FakeWire.result(to: $0) }
        try await retry()
        // Done when it returns, not some time after.
        #expect(queued.isEmpty)
        #expect(try !contact(stranger).hasContactRequest)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aRetryOfflineReturnsAndKeepsTheChangeQueuedUntilConnected() async throws {
        try await session.acceptContactRequest(from: stranger)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        let retry = try #require(session.warnings.current.first?.retry)

        // Never refused for being offline: the change waits, stored, for a connection.
        session.client.update(state: .disconnected())
        try await retry()
        #expect(queued.map(\.kind) == [.accept])
        #expect(try contact(stranger).pendingRoster == .accept)

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty && session.warnings.current.isEmpty })
        #expect(try !contact(stranger).hasContactRequest)
    }

    @Test func aStaleConnectionsRosterReadDoesNotReleaseTheQueue() async throws {
        connect()
        // The session reads the roster itself on connecting; let that finish.
        #expect(await eventually { !session.lock.withLock { $0.awaitsRoster } })
        session.lock.withLock { $0.awaitsRoster = true }
        try await session.removeContact(alice)
        let current = session.lock.withLock { $0.attempt }

        try await session.requestRoster(attempt: current - 1)
        _ = await eventually(timeout: 0.3) { false }
        #expect(session.lock.withLock { $0.awaitsRoster })
        #expect(rosterSets.isEmpty)

        try await session.requestRoster(attempt: current)
        #expect(await eventually { queued.isEmpty })
        #expect(!session.lock.withLock { $0.awaitsRoster })
    }

    @Test func anAcceptWhoseAnswerCouldNotBeSentIsNotCountedDone() async throws {
        try await session.acceptContactRequest(from: stranger)
        // The connection goes away after the server took the roster item.
        connect { [wire] iq in
            wire.failsWrites = true
            return FakeWire.result(to: iq)
        }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try contact(stranger).hasContactRequest)
        #expect(session.warnings.current.first?.title == "Couldn't accept the request")
    }

    @Test func aRefusedRenameShowsTheOldNameAgain() async throws {
        try await session.setContactName(alice, name: "Ally")
        connect { FakeWire.error(to: $0, condition: "not-allowed", type: "cancel") }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try contact(alice).displayName == "Alice")
        #expect(session.warnings.current.first?.title == "Couldn't save the nickname")
        #expect(session.warnings.current.first?.retry != nil)
    }

    @Test func aRefusedRemovalKeepsTheContact() async throws {
        try await session.removeContact(alice)
        connect { FakeWire.error(to: $0, condition: "not-allowed", type: "cancel") }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try contact(alice).isInRoster)
        #expect(try contact(alice).pendingRoster == nil)
    }

    @Test func aPassingErrorLeavesItQueuedForTheNextConnect() async throws {
        try await session.removeContact(alice)
        connect { FakeWire.error(to: $0, condition: "resource-constraint", type: "wait") }
        session.sendPendingRosterChanges()
        #expect(await eventually { rosterSets.count == ServerRetry.attempts })
        _ = await eventually(timeout: 0.3) { false }
        #expect(queued.count == 1)
        #expect(session.warnings.current.isEmpty)
        #expect(try contact(alice).pendingRoster == .remove)

        wire.answer { FakeWire.result(to: $0) }
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(try !contact(alice).isInRoster)
    }

    @Test func aRenameOfSomeoneRemovedMeanwhileIsDroppedWithAWarning() async throws {
        try await session.setContactName(alice, name: "Ally")
        try db.removeRosterItem(jid: alice)
        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(session.warnings.current.first?.retry == nil)
        #expect(rosterSets.isEmpty)
    }

    @Test func aRequestAnsweredElsewhereSendsNothing() async throws {
        try await session.acceptContactRequest(from: stranger)
        try db.clearContactRequest(from: stranger)
        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.isEmpty)
        #expect(presences(.subscribe).isEmpty)
    }

    // MARK: Sessions

    @Test func nothingIsSentWhileANewSessionsRosterIsStillBeingRead() async throws {
        try await session.setContactName(alice, name: "Ally")
        wire.answer { iq in
            self.isRosterIq(iq) && iq.type == .get ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : FakeWire.result(to: iq)
        }
        session.lock.withLock { $0.retryBackoff = 0.2 }
        session.connectForTesting(wire)
        session.sendPendingRosterChanges()
        _ = await eventually(timeout: 0.1) { false }
        #expect(rosterSets.isEmpty)
        #expect(queued.count == 1)
    }

    @Test func aRosterThatCantBeReadForGoodDoesntHoldBackTheQueue() async throws {
        try await session.setContactName(alice, name: "Ally")
        wire.answer { iq in
            self.isRosterIq(iq) && iq.type == .get ? FakeWire.error(to: iq, condition: "forbidden", type: "auth") : FakeWire.result(to: iq)
        }
        session.connectForTesting(wire)
        #expect(await eventually { session.warnings.current.contains { $0.key == "roster" } })
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.count == 1)
    }

    @Test func theQueueSurvivesANewSessionOnTheSameDatabase() async throws {
        try await session.setContactName(alice, name: "Ally")
        try await session.acceptContactRequest(from: stranger)

        let later = try makeSession(YapnestKit.JID("me@example.org")!, database: db)
        later.lock.withLock { $0.retryBackoff = 0 }
        wire.answer { FakeWire.result(to: $0) }
        later.connectForTesting(wire)
        later.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.count == 2)
    }

    @Test func aShareExtensionSessionDoesNotSend() async throws {
        let extensionSession = try makeSession(YapnestKit.JID("me@example.org")!, database: db, mode: .share)
        try await extensionSession.setContactName(alice, name: "Ally")
        wire.answer { FakeWire.result(to: $0) }
        extensionSession.connectForTesting(wire)
        extensionSession.sendPendingRosterChanges()
        _ = await eventually(timeout: 0.3) { false }
        #expect(rosterSets.isEmpty)
        #expect(queued.count == 1)
    }

    // MARK: Befriending

    @Test func befriendingWaitsForTheAcceptItDoes() async throws {
        connect()
        await session.befriendForNewChat(stranger)
        #expect(try !contact(stranger).hasContactRequest)
        #expect(queued.isEmpty)
    }

    @Test func befriendingLeavesAnAcceptTheUserQueuedToTheQueue() async throws {
        try await session.acceptContactRequest(from: stranger)
        // The roster can't be read, so the queue sends the accept; befriending must leave it be.
        wire.answer { iq in
            self.isRosterIq(iq) && iq.type == .get ? FakeWire.error(to: iq, condition: "forbidden", type: "auth") : FakeWire.result(to: iq)
        }
        session.connectForTesting(wire)
        await session.befriendForNewChat(stranger)
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.count == 1)
        #expect(presences(.subscribe).count == 1)
    }

    // MARK: Adding a contact

    private var subscribes: [Presence] { presences(.subscribe) }

    @Test func anAddMadeOfflineWaitsAndIsSentWithItsNameAndTokenOnConnect() async throws {
        try await session.addContactAndWait(stranger, name: "Stray", preauth: "tok")
        #expect(queued.map(\.kind) == [.add])
        #expect(queued.first?.name == "Stray")
        #expect(queued.first?.preauth == "tok")
        #expect(try contact(stranger).pendingRoster == .add)
        #expect(try !db.hasConsented(stranger))
        #expect(wire.written.isEmpty)

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.map { $0.attribute("jid") } == ["stranger@example.net"])
        #expect(rosterSets.first?.attribute("name") == "Stray")
        #expect(subscribes.count == 1)
        #expect(subscribes.first?.firstChild(name: "preauth", xmlns: "urn:xmpp:pars:0")?.attribute("token") == "tok")
        let done = try contact(stranger)
        #expect(done.pendingRoster == nil)
        #expect(done.isAddedByUser)
    }

    @Test func aQueuedAddForSomeoneWhoAskedAnswersTheirRequest() async throws {
        #expect(try contact(stranger).hasContactRequest)
        try await session.addContactAndWait(stranger)
        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(try !contact(stranger).hasContactRequest, "approved by the add, so off the list")
    }

    @Test func anAddMadeOnlineForSomeoneWhoAskedAnswersTheirRequest() async throws {
        connect()
        try await session.addContactAndWait(stranger)
        #expect(queued.isEmpty)
        #expect(try !contact(stranger).hasContactRequest)
    }

    @Test func anAddThatHitAPassingErrorIsQueuedInsteadOfFailing() async throws {
        connect { FakeWire.error(to: $0, condition: "resource-constraint", type: "wait") }
        try await session.addContactAndWait(stranger)
        #expect(queued.map(\.kind) == [.add])
        #expect(try contact(stranger).pendingRoster == .add)
        #expect(try !db.hasConsented(stranger))
    }

    @Test func anAddTheServerRefusesWhileWaitingStillThrows() async throws {
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        await #expect(throws: (any Error).self) { try await session.addContactAndWait(stranger) }
        #expect(queued.isEmpty)
    }

    @Test func aQueuedAddTheServerRefusesForGoodIsDroppedWithAWarning() async throws {
        try await session.addContactAndWait(stranger)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingRosterChanges()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try contact(stranger).pendingRoster == nil)
        #expect(try !db.hasConsented(stranger))
        #expect(subscribes.isEmpty)
    }

    @Test func aRemovalCancelsAnAddThatWasNotSent() async throws {
        try await session.addContactAndWait(stranger)
        try await session.removeContact(stranger)
        #expect(queued.map(\.kind) == [.remove])

        connect()
        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.isEmpty)
        #expect(subscribes.isEmpty)
    }

    @Test func anAddReplacesARemovalThatWasNotSent() async throws {
        try await session.removeContact(alice)
        try await session.addContactAndWait(alice)
        #expect(queued.map(\.kind) == [.add])
        #expect(try contact(alice).pendingRoster == .add)
    }

    @Test func anAddWhileARemovalIsStillQueuedGoesThroughTheQueue() async throws {
        try await session.removeContact(alice)
        connect()
        try await session.addContactAndWait(alice)
        #expect(queued.map(\.kind) == [.add], "sent directly, the removal still queued would undo it")
        #expect(rosterSets.isEmpty)

        session.sendPendingRosterChanges()
        #expect(await eventually { queued.isEmpty })
        #expect(rosterSets.map { $0.attribute("jid") } == ["alice@example.org"])
        #expect(rosterSets.first?.attribute("subscription") != "remove")
    }

    @Test func aLaterAddReplacesAnEarlierOne() async throws {
        try await session.addContactAndWait(stranger, name: "One", preauth: "a")
        try await session.addContactAndWait(stranger, name: "Two", preauth: "b")
        #expect(queued.map(\.name) == ["Two"])
        #expect(queued.map(\.preauth) == ["b"])
    }

    @Test func anAddBeingSentIsNotReplacedByARemoval() async throws {
        try await session.addContactAndWait(stranger)
        let id = try #require(queued.first?.id)
        try db.queueRosterChange(stranger, kind: .remove, inFlight: id)
        #expect(queued.map(\.kind) == [.add, .remove])
    }

    // MARK: Storage

    @Test func theTableAndColumnsAreAddedToADatabaseFromBefore() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v53-bookmark-owed")
        try queue.write { try $0.execute(sql: "INSERT INTO contact (jid, subscription, isSubscriptionPending, isInRoster, isAddedByUser, isBlocked, rosterGroups) VALUES ('a@example.org', 'none', 0, 0, 0, 0, '[]')") }
        try AppDatabase.migrator.migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pendingRosterChange") } == 0)
        let contact = try queue.read { try Contact.fetchOne($0, key: YapnestKit.JID("a@example.org")!) }
        #expect(contact?.pendingRoster == nil)
        #expect(contact?.pendingRename == false)
    }

    @Test func thePreauthColumnIsAddedToAQueueFromBefore() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v60-message-written-at")
        try queue.write { try $0.execute(sql: "INSERT INTO pendingRosterChange (jid, kind, createdAt) VALUES ('a@example.org', 'remove', '2026-01-01 00:00:00')") }
        try AppDatabase.migrator.migrate(queue)
        let change = try queue.read { try PendingRosterChange.fetchOne($0) }
        #expect(change?.kind == .remove)
        #expect(change?.preauth == nil)
    }
}
