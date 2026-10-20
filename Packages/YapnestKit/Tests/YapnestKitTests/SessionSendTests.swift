import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// What the session writes when sending, driven through a stand-in for the
/// connection.
struct SessionSendTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        // Encryption would need the contact's devices, and wait for them.
        try session.setEncrypted(false, with: alice)
    }

    private func status(of message: YapnestKit.Message) throws -> YapnestKit.Message.Status? {
        try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!)?.status }
    }

    /// Sends a message on a stream that acknowledges, so it stays pending
    /// once written, as the server hasn't confirmed it.
    private func sentAndAwaitingAcknowledgement() throws -> YapnestKit.Message {
        session.enableAcknowledgementsForTesting()
        let message = try session.send("first", to: alice)
        session.drainSendQueue(alice)
        #expect(try status(of: message) == .pending)
        #expect(wire.messages.contains { $0.id == message.remoteId })
        return message
    }

    // MARK: Edits and retractions of a message that is on the wire

    @Test func editingAWrittenButUnacknowledgedMessageSendsACorrection() throws {
        let message = try sentAndAwaitingAcknowledgement()
        try session.edit(message, to: "fixed")
        session.drainSendQueue(alice)

        let correction = try #require(wire.messages.first { $0.firstChild(name: "replace", xmlns: NS.correction) != nil })
        #expect(correction.body == "fixed")
        #expect(correction.firstChild(name: "replace", xmlns: NS.correction)?.getAttribute("id") == message.remoteId)
        // Locally too, marked as edited.
        let stored = try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
        #expect(stored.body == "fixed")
        #expect(stored.editedAt != nil)
    }

    @Test func retractingAWrittenButUnacknowledgedMessageSendsARetraction() throws {
        let message = try sentAndAwaitingAcknowledgement()
        try session.retract(message)
        session.drainSendQueue(alice)

        let retraction = try #require(wire.messages.first { $0.firstChild(name: "retract", xmlns: NS.retraction) != nil })
        #expect(retraction.firstChild(name: "retract", xmlns: NS.retraction)?.getAttribute("id") == message.remoteId)
        let stored = try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
        #expect(stored.isRetracted)
    }

    @Test func editingAMessageTheQueueHasNotTakenUpOnlyChangesItHere() throws {
        // Staged but never put on a send queue: nothing is on the wire.
        let message = try session.outgoingMessages.stage([.text("first", reply: nil)], to: alice)[0]
        try session.edit(message, to: "fixed")

        #expect(wire.messages.isEmpty)
        let stored = try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
        #expect(stored.body == "fixed")
        #expect(stored.editedAt == nil)
    }

    // MARK: A write the connection drops

    @Test func aWriteTheConnectionDroppedGivesUpItsClaimSoItIsSentAgain() throws {
        session.enableAcknowledgementsForTesting()
        wire.failsWrites = true
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        let id = try #require(message.remoteId)

        #expect(wire.messages.contains { $0.id == id })
        #expect(!session.lock.withLock { $0.sends.isClaimed(id) })

        // Back on a live stream, what is still pending goes out again.
        wire.failsWrites = false
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(wire.messages.filter { $0.id == id }.count == 2)
    }

    @Test func aWriteThatWentThroughKeepsItsClaim() throws {
        session.enableAcknowledgementsForTesting()
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        let id = try #require(message.remoteId)

        #expect(session.lock.withLock { $0.sends.isClaimed(id) })
        // A claimed message is on its way: resending it would duplicate it.
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(wire.messages.filter { $0.id == id }.count == 1)
    }
}

/// An extension's session sends only what it wrote itself.
struct ResumeResendTests {
    private func pendingMessage(in session: XMPPSession) throws -> YapnestKit.Message {
        try session.outgoingMessages.stage([.text("left by the share extension", reply: nil)], to: alice)[0]
    }

    @Test func aResumedAppSessionSendsWhatIsStillPending() throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        try session.setEncrypted(false, with: alice)
        let message = try pendingMessage(in: session)

        session.resumeWork()
        session.drainSendQueue(alice)

        #expect(wire.messages.contains { $0.id == message.remoteId })
    }

    @Test func aResumedShareSessionLeavesPendingMessagesForTheApp() throws {
        let database = try AppDatabase.inMemory()
        let session = try XMPPSession(credentials: .init(jid: me, password: "x"), resource: "t", database: database, mode: .share)
        let wire = FakeWire()
        session.connectForTesting(wire)
        try session.setEncrypted(false, with: alice)
        let message = try pendingMessage(in: session)

        session.resumeWork()
        session.drainSendQueue(alice)

        #expect(!wire.messages.contains { $0.id == message.remoteId })
        let stored = try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
        #expect(stored.status == .pending)
    }
}
