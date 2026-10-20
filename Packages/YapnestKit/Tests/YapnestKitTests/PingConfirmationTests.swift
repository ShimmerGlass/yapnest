import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// Without stream management nothing acknowledges a stanza, so a message is
/// sent, and a reaction no longer pending, once the server answers a ping
/// written after it.
struct PingConfirmationTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try session.setEncrypted(false, with: alice)
        wire.holdsPings = true
    }

    private func status(of message: YapnestKit.Message) throws -> YapnestKit.Message.Status? {
        try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.status }
    }

    private func reactionStanzas() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }
    }

    private func isReactionPending() throws -> Bool {
        try database.reader.read { try Reaction.fetchAll($0) }.contains { $0.pendingId != nil }
    }

    private func reactingToAMessage() throws -> YapnestKit.Message {
        let id = try #require(try database.conversation(with: alice).id)
        return try database.insert(YapnestKit.Message(conversationId: id, direction: .incoming, sender: alice, body: "hi", remoteId: "1"))
    }

    /// A new session loses what the server never acknowledged.
    private func startNewSession() {
        session.lock.withLock {
            $0.sends.reset()
            $0.writtenReactions = []
        }
    }

    @Test func aMessageIsPendingUntilThePingIsAnswered() throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)

        #expect(wire.messages.count == 1)
        #expect(wire.heldPings == 1)
        #expect(try status(of: message) == .pending)

        wire.releasePings()
        #expect(try status(of: message) == .sent)
    }

    @Test func anErrorAnswerShowsTheServerReadItToo() throws {
        wire.answer { FakeWire.error(to: $0, condition: "service-unavailable") }
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        wire.releasePings()

        #expect(try status(of: message) == .sent)
    }

    @Test func aStreamWithManagementPingsNothing() throws {
        session.enableAcknowledgementsForTesting()
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)

        #expect(wire.pings.isEmpty)
        #expect(try status(of: message) == .pending)
    }

    @Test func aMessageWithoutAnAnswerIsNotWrittenAgainThisSessionAndIsInTheNext() throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)

        // The ping timed out: the connection may still be up.
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(wire.messages.count == 1)
        #expect(try status(of: message) == .pending)

        startNewSession()
        wire.holdsPings = false
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(wire.messages.map(\.id) == [message.remoteId, message.remoteId])
        #expect(try status(of: message) == .sent)
    }

    @Test func aReactionIsPendingUntilThePingIsAnswered() throws {
        let message = try reactingToAMessage()
        try session.toggleReaction("👍", on: message, peer: alice)

        #expect(reactionStanzas().count == 1)
        #expect(try isReactionPending())
        wire.releasePings()
        #expect(!(try isReactionPending()))
    }

    @Test func aReactionWithoutAnAnswerIsNotWrittenAgainThisSessionAndIsInTheNext() throws {
        let message = try reactingToAMessage()
        try session.toggleReaction("👍", on: message, peer: alice)
        let id = try #require(reactionStanzas().first?.id)

        session.sendUnclaimedPending()
        #expect(reactionStanzas().count == 1)
        #expect(try isReactionPending())

        startNewSession()
        wire.holdsPings = false
        session.sendUnclaimedPending()
        session.sendUnclaimedPending()
        #expect(reactionStanzas().map(\.id) == [id, id])
        #expect(!(try isReactionPending()))
    }
}
