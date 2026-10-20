import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// A reaction of ours stays marked as sending until the server acknowledges
/// the stanza that carries it.
struct PendingReactionTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let message: YapnestKit.Message

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        let id = try #require(try database.conversation(with: alice).id)
        message = try database.insert(YapnestKit.Message(conversationId: id, direction: .incoming, sender: alice, body: "hi", remoteId: "1"))
    }

    private func rows() throws -> [Reaction] {
        try database.reader.read { try Reaction.fetchAll($0) }
    }

    private func isPending() throws -> Bool {
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        return items.flatMap(\.reactions).contains { $0.isPending }
    }

    private func reactionStanzas() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }
    }

    @Test func aToggledReactionIsPendingUntilItsStanzaIsAcknowledged() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)

        let stanza = try #require(reactionStanzas().first)
        let id = try #require(stanza.id)
        #expect(try rows().map(\.pendingId) == [id])
        #expect(try isPending())

        session.acknowledged(stanza)
        #expect(try rows().map(\.pendingId) == [nil])
        #expect(!(try isPending()))
    }

    @Test func anAcknowledgementOfAnotherStanzaLeavesItPending() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        let other = OutboundStanza.reactions(["👍"], to: .direct(alice), target: "1", id: "other")
        session.acknowledged(other)

        #expect(try isPending())
    }

    @Test func aReactionIsNotLeftPendingWithoutStreamManagement() throws {
        try session.toggleReaction("👍", on: message, peer: alice)

        #expect(reactionStanzas().count == 1)
        #expect(try rows().count == 1)
        #expect(!(try isPending()))
    }

    @Test func anEchoOfOurReactionReplacesPendingRows() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        #expect(try isPending())

        // From our other device's carbon, or a room's echo.
        try database.setReactions(["👍", "❤️"], from: me, conversationId: message.conversationId, messageRef: "1")

        #expect(try rows().count == 2)
        #expect(try rows().allSatisfy { $0.pendingId == nil })
        #expect(!(try isPending()))
    }

    @Test func onlyOurOwnPendingReactionsMarkTheGroup() throws {
        try database.setReactions(["👍"], from: Author(jid: alice), conversationId: message.conversationId, messageRef: "1", pendingId: "x")
        #expect(!(try isPending()))
    }

    @Test func aNewSessionSendsAPendingReactionAgainWithTheSameIdOnce() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        let id = try #require(reactionStanzas().first?.id)

        // A resumed stream is left to Martin: it's still written.
        session.sendUnclaimedPending()
        #expect(reactionStanzas().count == 1)

        // A new one starts over, having lost what was unacknowledged.
        session.lock.withLock { $0.writtenReactions = [] }
        session.sendUnclaimedPending()
        session.sendUnclaimedPending()
        let sent = reactionStanzas()
        #expect(sent.count == 2)
        #expect(sent.last?.id == id)
        let emojis = sent.last?.firstChild(name: "reactions", xmlns: NS.reactions)?.filterChildren(name: "reaction", xmlns: nil).compactMap(\.value)
        #expect(emojis == ["👍"])
        #expect(try isPending())
    }

    @Test func aReactionOnAMessageThatIsGoneIsNoLongerPending() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE message SET remoteId = NULL, originId = NULL WHERE id = ?", arguments: [message.id])
        }
        session.lock.withLock { $0.writtenReactions = [] }
        session.sendUnclaimedPending()

        #expect(reactionStanzas().count == 1)
        #expect(!(try isPending()))
    }
}
