import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

/// What the account's server calls do when a server refuses, times out or
/// drops: contacts, blocking, the profile and the roster.
struct AccountServerCallTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(me, database: db)
        session.lock.withLock { $0.retryBackoff = 0 }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    private func rosterQuery(_ iq: Iq) -> Element? { iq.firstChild(name: "query", xmlns: "jabber:iq:roster") }
    private func isRosterSet(_ iq: Iq) -> Bool { iq.type == .set && rosterQuery(iq) != nil }
    private func rosterSets() -> [Iq] { wire.written.compactMap { $0 as? Iq }.filter { isRosterSet($0) } }
    private func presences(_ type: StanzaType) -> [Presence] { wire.written.compactMap { $0 as? Presence }.filter { $0.type == type } }

    // MARK: Accepting and befriending

    @Test func acceptingKeepsTheRequestWhenTheRosterRefuses() async throws {
        try db.recordContactRequest(from: alice, nickname: nil)
        session.connectForTesting(wire)
        wire.answer { iq in self.isRosterSet(iq) ? FakeWire.error(to: iq, condition: "forbidden") : FakeWire.result(to: iq) }

        await #expect(throws: (any Error).self) { try await session.acceptContactRequest(from: alice) }

        #expect(try db.contact(alice)?.hasContactRequest == true)
        #expect(presences(.subscribe).isEmpty)
        #expect(presences(.subscribed).isEmpty)
    }

    @Test func acceptingTriesAgainWhenTheRosterAnswersWait() async throws {
        try db.recordContactRequest(from: alice, nickname: nil)
        session.connectForTesting(wire)
        let calls = Counter()
        wire.answer { iq in
            guard self.isRosterSet(iq) else { return FakeWire.result(to: iq) }
            return calls.next() == 1 ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : FakeWire.result(to: iq)
        }

        try await session.acceptContactRequest(from: alice)

        #expect(rosterSets().count == 2)
        #expect(try db.contact(alice)?.hasContactRequest == false)
        #expect(presences(.subscribed).count == 1)
    }

    @Test func befriendingWarnsWhenTheRosterRefuses() async throws {
        session.connectForTesting(wire)
        let refuses = Counter()
        wire.answer { iq in
            guard self.isRosterSet(iq) else { return FakeWire.result(to: iq) }
            return refuses.next() == 1 ? FakeWire.error(to: iq, condition: "forbidden") : FakeWire.result(to: iq)
        }

        await session.befriendForNewChat(alice)

        let warning = try #require(session.warnings.current.first { $0.key.hasPrefix("befriend:") })
        #expect(warning.detail.contains("forbidden"))
        #expect(presences(.subscribe).isEmpty)

        // Retry from the banner succeeds and the warning goes.
        #expect(await session.warnings.retry(warning.key))
        #expect(session.warnings.current.contains { $0.key == warning.key } == false)
        #expect(presences(.subscribe).count == 1)
    }

    // MARK: The roster

    @Test func aRosterThatAnswersWaitIsAskedForAgain() async throws {
        let gets = Counter()
        let item = Element(name: "item", attributes: ["jid": alice.description, "subscription": "both"])
        let query = Element(name: "query", xmlns: "jabber:iq:roster")
        query.addChild(item)
        wire.answer { iq in
            guard iq.type == .get, self.rosterQuery(iq) != nil else { return FakeWire.result(to: iq) }
            return gets.next() == 1 ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : FakeWire.result(to: iq, query)
        }
        session.connectForTesting(wire)

        await eventually("the roster") { (try? self.db.isInRoster(self.alice)) == true }
        #expect(session.warnings.current.contains { $0.key == "roster" } == false)
    }

    @Test func aRosterThatKeepsFailingIsAWarningWithARetry() async throws {
        let gets = Counter()
        wire.answer { iq in
            guard iq.type == .get, self.rosterQuery(iq) != nil else { return FakeWire.result(to: iq) }
            _ = gets.next()
            return FakeWire.error(to: iq, condition: "resource-constraint", type: "wait")
        }
        session.connectForTesting(wire)

        await eventually("the warning") { self.session.warnings.current.contains { $0.key == "roster" } }
        #expect(gets.next() == 4)
        #expect(session.warnings.current.first { $0.key == "roster" }?.retry != nil)
    }

    // MARK: Blocking

    private func offerBlocking() {
        session.connectForTesting(wire)
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
                result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
                return FakeWire.result(to: iq, result)
            }
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
                query.addChild(Element(name: "feature", attributes: ["var": "urn:xmpp:blocking"]))
                return FakeWire.result(to: iq, query)
            }
            return FakeWire.result(to: iq)
        }
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind()
        session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
    }

    @Test func blockingDeclinesTheRequestBeforeTheBlock() async throws {
        let spammer = JID("spam@example.net")!
        try db.recordContactRequest(from: spammer, nickname: nil)
        offerBlocking()
        await eventually("blocking") { self.session.canBlock }

        try await session.block(spammer)

        let written = wire.written
        let decline = try #require(written.firstIndex { ($0 as? Presence)?.type == .unsubscribed })
        let block = try #require(written.firstIndex { ($0 as? Iq)?.firstChild(name: "block", xmlns: "urn:xmpp:blocking") != nil })
        #expect(decline < block)
        #expect(try db.contact(spammer)?.hasContactRequest == false)
        #expect(try db.isBlocked(spammer))
    }

    // MARK: Profile

    @Test func publishingTriesAgainWhenTheServerAnswersWait() async throws {
        session.connectForTesting(wire)
        let calls = Counter()
        wire.answer { iq in
            guard iq.firstChild(name: "pubsub") != nil else { return FakeWire.result(to: iq) }
            return calls.next() == 1 ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : FakeWire.result(to: iq)
        }

        try await session.removeAvatar()

        #expect(wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "pubsub") != nil }.count == 2)
    }

    @Test func aRefusedPublishReachesTheScreenAsTheServersError() async throws {
        session.connectForTesting(wire)
        wire.answer { iq in iq.firstChild(name: "pubsub") != nil ? FakeWire.error(to: iq, condition: "forbidden") : FakeWire.result(to: iq) }

        do {
            try await session.setNickname("Ada")
            Issue.record("Expected the publish to fail")
        } catch {
            #expect(ServerError.isFromServer(error))
            #expect(ServerError.classify(error).isFinal)
        }
    }

    @Test func aPublishCutOffByADroppedConnectionIsOffline() async throws {
        session.connectForTesting(wire)
        wire.answer { iq in
            guard iq.firstChild(name: "pubsub") != nil else { return FakeWire.result(to: iq) }
            self.session.client.update(state: .disconnected(.timeout))
            return FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait")
        }

        do {
            try await session.setNickname("Ada")
            Issue.record("Expected the publish to fail")
        } catch let error as XMPPSession.ProfileError {
            if case .offline = error {} else { Issue.record("Expected offline, got \(error)") }
        } catch {
            Issue.record("Expected offline, got \(error)")
        }
    }

    @Test func clearingTheNicknameTakesBackEveryItem() async throws {
        try db.setSetting(.nickname, "Ada")
        session.connectForTesting(wire)
        wire.answer { iq in
            if let pubsub = iq.firstChild(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"), pubsub.firstChild(name: "items") != nil {
                let result = Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
                let items = Element(name: "items", attributes: ["node": NS.nick])
                for id in ["current", "other-client"] {
                    let item = Element(name: "item", attributes: ["id": id])
                    item.addChild(ProfileStanza.nick("Ada"))
                    items.addChild(item)
                }
                result.addChild(items)
                return FakeWire.result(to: iq, result)
            }
            return FakeWire.result(to: iq)
        }

        try await session.setNickname(nil)

        let retracted = wire.written.compactMap { $0 as? Iq }.compactMap {
            $0.firstChild(name: "pubsub")?.firstChild(name: "retract")?.firstChild(name: "item")?.attribute("id")
        }
        #expect(retracted == ["current", "other-client"])
        #expect(session.nickname == nil)
    }

    @Test func clearingTheNicknameOfAnEmptyNodeIsDone() async throws {
        try db.setSetting(.nickname, "Ada")
        session.connectForTesting(wire)
        wire.answer { iq in
            iq.firstChild(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.firstChild(name: "items") != nil
                ? FakeWire.error(to: iq, condition: "item-not-found") : FakeWire.result(to: iq)
        }

        try await session.setNickname(nil)

        #expect(session.nickname == nil)
    }
}
