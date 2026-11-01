import Foundation
import GRDB
import os
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

/// XEP-0191 blocklists.
struct BlockingTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let bob = JID("bob@example.org")!
    let spammer = JID("spam@example.net")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @Test func blocklistReplacesWhatWeHad() throws {
        try db.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try db.setBlocklist([alice, spammer])
        #expect(try db.isBlocked(alice))
        #expect(try db.isBlocked(spammer))
        #expect(try !db.isBlocked(bob))
        // Blocking keeps what we know of them.
        #expect(try db.contact(alice)?.name == "Alice")

        try db.setBlocklist([spammer])
        #expect(try !db.isBlocked(alice))
        #expect(try db.isBlocked(spammer))
    }

    @Test func reportNamesTheirLatestMessages() throws {
        let conversation = try db.conversation(with: spammer)
        for index in 0..<3 {
            try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: spammer, body: "buy \(index)",
                                  timestamp: Date(timeIntervalSince1970: Double(index)), serverId: "s\(index)"))
        }
        try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: alice, body: "stop", serverId: "mine"))
        #expect(try db.lastServerIds(from: spammer, limit: 2) == ["s2", "s1"])
    }
}

/// A block or unblock made offline is kept until the server confirms it.
struct QueuedBlockTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let spammer = JID("spam@example.net")!

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(JID("me@example.org")!, database: db)
        session.lock.withLock { $0.retryBackoff = 0 }
    }

    private func isBlockingIq(_ iq: Iq) -> Bool {
        iq.firstChild(name: "block", xmlns: "urn:xmpp:blocking") != nil || iq.firstChild(name: "unblock", xmlns: "urn:xmpp:blocking") != nil
    }

    private var sent: [Iq] { wire.written.compactMap { $0 as? Iq }.filter(isBlockingIq) }

    private var queued: [PendingBlockChange] {
        (try? db.reader.read { try PendingBlockChange.fetchAll($0) }) ?? []
    }

    private func connect(answering answer: @escaping @Sendable (Iq) -> Iq = { FakeWire.result(to: $0) }) {
        wire.answer { iq in self.isBlockingIq(iq) ? answer(iq) : FakeWire.result(to: iq) }
        session.connectForTesting(wire)
    }

    @Test func aBlockMadeOfflineIsAppliedAtOnceAndSentOnConnect() async throws {
        try await session.block(spammer)
        #expect(try db.isBlocked(spammer))
        #expect(queued.map(\.blocked) == [true])
        #expect(wire.written.isEmpty)

        connect()
        session.sendPendingBlocks()
        #expect(await eventually { sent.count == 1 && queued.isEmpty })
        #expect(try db.isBlocked(spammer))
    }

    @Test func aBlockMadeOnlineGoesAtOnceAndIsClearedWhenTheServerTakesIt() async throws {
        connect()
        try await session.block(spammer)
        #expect(await eventually { sent.count == 1 && queued.isEmpty })
    }

    @Test func aBlockUndoneBeforeItWasSentSendsNothing() async throws {
        try await session.block(spammer)
        try await session.unblock(spammer)
        #expect(queued.isEmpty)
        #expect(try !db.isBlocked(spammer))
        connect()
        session.sendPendingBlocks()
        _ = await eventually(timeout: 0.3) { false }
        #expect(sent.isEmpty)
    }

    @Test func anUnblockOfSomeoneBlockedIsSentAndTheBlockOfThemAgainSendsOnlyTheLast() async throws {
        try db.setBlocklist([spammer])
        try await session.unblock(spammer)
        try await session.block(spammer)
        #expect(queued.isEmpty)
        try await session.unblock(spammer)
        try await session.block(spammer, reporting: .spam)
        try await session.unblock(spammer)
        #expect(queued.map(\.blocked) == [false])
        connect()
        session.sendPendingBlocks()
        #expect(await eventually { sent.count == 1 && queued.isEmpty })
        #expect(sent.first?.firstChild(name: "unblock") != nil)
        #expect(try !db.isBlocked(spammer))
    }

    @Test func aRefusalForGoodPutsThePersonBackAndShowsTheServersError() async throws {
        try await session.block(spammer)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingBlocks()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try !db.isBlocked(spammer))
        #expect(session.warnings.current.first?.title == "Couldn't block")
        #expect(session.warnings.current.first?.retry != nil)
        #expect(sent.count == 1)
    }

    @Test func aRetryWaitsForTheServerAndThrowsItsRefusal() async throws {
        try await session.block(spammer)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingBlocks()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        let retry = try #require(session.warnings.current.first?.retry)

        // Still refused: the Retry itself reports it, not a new warning later.
        let error = await #expect(throws: (any Error).self) { try await retry() }
        #expect(ServerError.userMessage(for: try #require(error), friendly: "").contains("forbidden"))
        #expect(queued.isEmpty)
        #expect(try !db.isBlocked(spammer))

        wire.answer { FakeWire.result(to: $0) }
        try await retry()
        // Done when it returns, not some time after.
        #expect(queued.isEmpty)
        #expect(try db.isBlocked(spammer))
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aRefusedChangeThatCantBeDroppedIsNotSentOverAndOver() async throws {
        try await session.block(spammer)
        try await db.writer.write {
            try $0.execute(sql: "CREATE TRIGGER failDelete BEFORE DELETE ON pendingBlockChange BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingBlocks()
        #expect(await eventually { sent.count >= 1 })
        _ = await eventually(timeout: 1) { false }
        #expect(sent.count == 1)
        #expect(queued.count == 1)
    }

    @Test func aRefusedUnblockKeepsThemBlocked() async throws {
        try db.setBlocklist([spammer])
        try await session.unblock(spammer)
        #expect(try !db.isBlocked(spammer))
        connect { FakeWire.error(to: $0, condition: "not-allowed", type: "cancel") }
        session.sendPendingBlocks()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try db.isBlocked(spammer))
    }

    @Test func aPassingErrorLeavesItQueuedForTheNextConnect() async throws {
        try await session.block(spammer)
        connect { FakeWire.error(to: $0, condition: "resource-constraint", type: "wait") }
        session.sendPendingBlocks()
        #expect(await eventually { sent.count == ServerRetry.attempts })
        _ = await eventually(timeout: 0.3) { false }
        #expect(queued.count == 1)
        #expect(session.warnings.current.isEmpty)
        #expect(try db.isBlocked(spammer))

        wire.answer { FakeWire.result(to: $0) }
        session.sendPendingBlocks()
        #expect(await eventually { queued.isEmpty })
    }

    @Test func aServerWithoutBlockingDropsTheChangeAndSaysSo() async throws {
        try await session.block(spammer)
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                return FakeWire.result(to: iq, Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind", children: [Element(name: "jid", cdata: "me@example.org/t")]))
            }
            guard iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil else { return FakeWire.result(to: iq) }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "feature", attributes: ["var": "urn:xmpp:ping"]))
            return FakeWire.result(to: iq, query)
        }
        session.connectForTesting(wire)
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind(completionHandler: nil)
        session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
        #expect(await eventually { !session.canBlock })
        session.sendPendingBlocks()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try !db.isBlocked(spammer))
        #expect(session.warnings.current.first?.detail.contains("doesn't support blocking") == true)
        #expect(session.warnings.current.first?.retry == nil)
        #expect(sent.isEmpty)
        await #expect(throws: XMPPSession.BlockingError.self) { try await session.block(spammer) }
    }

    @Test func theBlocklistTheServerHoldsDoesNotUndoAChangeNotSentYet() async throws {
        try await session.block(spammer)
        session.blocklistChanged([])
        #expect(try db.isBlocked(spammer))
        #expect(queued.count == 1)

        // The server already blocks them: nothing is left to send.
        session.blocklistChanged([Martin.JID(spammer.martin)])
        #expect(try db.isBlocked(spammer))
        #expect(queued.isEmpty)
    }

    @Test func theBlocklistTheServerHoldsDoesNotUndoAnUnblockNotSentYet() async throws {
        try db.setBlocklist([spammer])
        try await session.unblock(spammer)
        session.blocklistChanged([Martin.JID(spammer.martin)])
        #expect(try !db.isBlocked(spammer))
        #expect(queued.count == 1)
    }

    @Test func aBlockDeclinesTheirRequestFirstAndClearsItOnceTheServerTookIt() async throws {
        try db.recordContactRequest(from: spammer, nickname: nil)
        try await session.block(spammer)
        #expect(try db.contact(spammer)?.subscriptionRequestedAt != nil)
        connect()
        session.sendPendingBlocks()
        #expect(await eventually { sent.count == 1 && queued.isEmpty })
        #expect(await eventually { (try? db.contact(spammer))??.subscriptionRequestedAt == nil })
        let written = wire.written
        let decline = try #require(written.firstIndex { ($0 as? Presence)?.type == .unsubscribed })
        let block = try #require(written.firstIndex { ($0 as? Iq).map(isBlockingIq) == true })
        #expect(decline < block)
    }

    @Test func aBlockUndoneOfflineLeavesTheRequestToAnswer() async throws {
        try db.recordContactRequest(from: spammer, nickname: nil)
        try await session.block(spammer)
        try await session.unblock(spammer)
        #expect(queued.isEmpty)
        #expect(try db.contact(spammer)?.hasContactRequest == true)
    }

    @Test func aRefusedBlockLeavesTheRequestToAnswer() async throws {
        try db.recordContactRequest(from: spammer, nickname: nil)
        try await session.block(spammer)
        connect { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        session.sendPendingBlocks()
        #expect(await eventually { session.warnings.current.count == 1 && queued.isEmpty })
        #expect(try db.contact(spammer)?.hasContactRequest == true)
    }

    @Test func aChangeTheUserReplacedWhileItWasRefusedShowsNoWarning() throws {
        try db.setBlocklist([spammer])
        try db.queueBlockChange(spammer, blocked: false, reason: nil, declinesRequest: false, canCancel: true)
        let change = try #require(try db.nextPendingBlockChange())
        try db.queueBlockChange(spammer, blocked: true, reason: nil, declinesRequest: false, canCancel: false)
        #expect(try !db.dropPendingBlockChange(change, serverBlocked: nil))
        #expect(try db.isBlocked(spammer))
        #expect(queued.map(\.blocked) == [true])
    }

    @Test func aRefusalOfAChangeReplacedMeanwhileIsNotShown() async throws {
        try await session.block(spammer)
        let answered = OSAllocatedUnfairLock(initialState: false)
        connect { iq in
            // The user undoes the block while the server is deciding.
            if answered.withLock({ let was = $0; $0 = true; return was }) { return FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") }
            let undone = DispatchSemaphore(value: 0)
            Task {
                _ = try? await self.session.unblock(self.spammer)
                undone.signal()
            }
            _ = undone.wait(timeout: .now() + 10)
            return FakeWire.error(to: iq, condition: "forbidden", type: "auth")
        }
        session.sendPendingBlocks()
        #expect(await eventually { sent.count >= 1 })
        _ = await eventually(timeout: 0.5) { false }
        #expect(session.warnings.current.isEmpty)
    }

    @Test func anUndoNeverCancelsABlockTheSenderHasAlreadyChosen() async throws {
        try await session.block(spammer)
        let undone = OSAllocatedUnfairLock(initialState: false)
        session.afterBlockChangeChosenForTesting = {
            guard !undone.withLock({ let was = $0; $0 = true; return was }) else { return }
            // Made between choosing the change and marking it in flight, on its own thread as the UI would.
            Task { _ = try? await self.session.unblock(self.spammer) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        connect()
        session.sendPendingBlocks()
        #expect(await eventually { sent.count == 2 && queued.isEmpty })
        #expect(sent.first?.firstChild(name: "block") != nil)
        #expect(sent.last?.firstChild(name: "unblock") != nil)
        #expect(try !db.isBlocked(spammer))
    }

    @Test func offlineTheActionIsOfferedButNoReportIsUntilTheServerSaidItTakesOne() {
        #expect(session.canBlock)
        #expect(!session.canReport)
    }

    @Test func anExtensionLeavesItToTheApp() async throws {
        let quiet = try makeSession(JID("me@example.org")!, database: db, mode: .notificationService)
        try await quiet.block(spammer)
        connectQuiet(quiet)
        quiet.sendPendingBlocks()
        _ = await eventually(timeout: 0.3) { false }
        #expect(sent.isEmpty)
        #expect(queued.count == 1)
    }

    private func connectQuiet(_ quiet: XMPPSession) {
        wire.answer { FakeWire.result(to: $0) }
        quiet.connectForTesting(wire)
    }

    @Test func theTableIsAddedToADatabaseFromBefore() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v51-read-state-owed")
        try AppDatabase.migrator.migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pendingBlockChange") } == 0)
    }
}
