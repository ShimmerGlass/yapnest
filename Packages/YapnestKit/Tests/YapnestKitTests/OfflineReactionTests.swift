import Foundation
import Martin
import Testing
@testable import YapnestKit

/// A reaction made without a connection is stored as sending and goes out
/// when a session is back.
struct OfflineReactionTests {
    let bob = JID("bob@example.org")!

    private func setUp() throws -> (XMPPSession, YapnestKit.Message) {
        let session = try makeSession(JID("me@example.org")!)
        let id = try #require(try session.database.conversation(with: bob).id)
        let message = try session.database.insert(Message(conversationId: id, direction: .incoming, sender: bob, body: "hi", remoteId: "1"))
        return (session, message)
    }

    private func stanzas(_ wire: FakeWire) -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }
    }

    @Test func reactingOfflineStoresItPending() throws {
        let (session, message) = try setUp()
        try session.toggleReaction("👍", on: message, peer: bob)

        let rows = try session.database.reader.read { try Reaction.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].pendingId != nil)
    }

    @Test func aNewSessionSendsAReactionMadeOfflineOnce() throws {
        let (session, message) = try setUp()
        try session.toggleReaction("👍", on: message, peer: bob)
        let id = try #require(try session.database.reader.read { try Reaction.fetchOne($0)?.pendingId })

        let wire = FakeWire()
        session.connectForTesting(wire)
        session.sendUnclaimedPending()
        session.sendUnclaimedPending()

        #expect(stanzas(wire).map(\.id) == [id])
    }

    @Test func aResumedSessionSendsAReactionMadeOfflineOnce() throws {
        let (session, message) = try setUp()
        try session.toggleReaction("👍", on: message, peer: bob)
        let id = try #require(try session.database.reader.read { try Reaction.fetchOne($0)?.pendingId })

        let wire = FakeWire()
        session.connectForTesting(wire)
        session.resumeWork()
        session.resumeWork()

        #expect(stanzas(wire).map(\.id) == [id])
    }
}
