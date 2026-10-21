import Foundation
import GRDB
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// Paging back through the archive moves a cursor, which must never pass a
/// page that didn't make it into the database.
struct HistoryStoreFailureTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let otherQuery = OSAllocatedBool()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        // Something stored already, so there is an older page to ask for.
        try database.ingest(try #require(InboundMessage(
            parseStanza("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='new'><body>newer</body></message>") as Martin.Message,
            account: me, source: .archive(serverId: "s-new", timestamp: Date(timeIntervalSince1970: 1_000)),
        )))
        session.connectForTesting(wire)
        session.lock.withLock { $0.archiveVersion = .MAM2 }

        let session = self.session
        let otherQuery = self.otherQuery
        wire.answer { request in
            guard let query = request.firstChild(name: "query", xmlns: "urn:xmpp:mam:2") else { return nil }
            session.client.module(.mam).archivedMessagesPublisher.send(.init(
                messageId: "s-old", source: me.martin, query: .init(id: query.getAttribute("queryid") ?? "", version: .MAM2),
                timestamp: Date(timeIntervalSince1970: 100),
                message: parseStanza("<message from='alice@example.org/phone' to='me@example.org' type='chat' id='old'><body>older</body></message>"),
            ))
            if otherQuery.value {
                // Another query's result, delivered while this page is fetched.
                session.client.module(.mam).archivedMessagesPublisher.send(.init(
                    messageId: "s-bob", source: me.martin, query: .init(id: "other", version: .MAM2),
                    timestamp: Date(timeIntervalSince1970: 200),
                    message: parseStanza("<message from='bob@example.org/phone' to='me@example.org' type='chat' id='bob'><body>from bob</body></message>"),
                ))
            }
            let fin = Element(name: "fin", xmlns: "urn:xmpp:mam:2")
            fin.setAttribute("complete", value: "false")
            fin.addChild(Element(name: "set", xmlns: "http://jabber.org/protocol/rsm", children: [Element(name: "first", cdata: "s-old")]))
            return FakeWire.result(to: request, fin)
        }
    }

    private func bodies() throws -> [String] {
        try database.reader.read { try YapnestKit.Message.order(Column("timestamp")).fetchAll($0).map(\.body) }
    }

    @Test func aStoredPageMovesTheCursor() async throws {
        #expect(try await session.loadOlderHistory(for: alice) == true)

        #expect(try database.historyState(peer: alice).cursor == "s-old")
        #expect(try bodies() == ["older", "newer"])
    }

    @Test func aPageThatCouldNotBeStoredThrowsAndLeavesTheCursor() async throws {
        try failStoringMessages(database)

        await #expect(throws: HistoryError.notStored) { try await session.loadOlderHistory(for: alice) }
        let state = try database.historyState(peer: alice)
        #expect(state.cursor == nil)
        #expect(!state.isComplete)
        #expect(try bodies() == ["newer"])

        // The same page is asked for again once the database works.
        try allowStoringMessages(database)
        #expect(try await session.loadOlderHistory(for: alice) == true)
        #expect(try bodies() == ["older", "newer"])
    }

    @Test func aFailedPageDoesNotLoseAnotherQuerysResults() async throws {
        otherQuery.set()
        try failStoringMessages(database)
        await #expect(throws: HistoryError.notStored) { try await session.loadOlderHistory(for: alice) }
        try allowStoringMessages(database)

        // The other query's answer arrives later and moves its own cursor
        // if this says its page is stored, so it must be.
        let stored = session.flushArchive(query: "other")
        let bodies = try bodies()
        #expect(stored)
        #expect(bodies.contains("from bob"))
    }
}
