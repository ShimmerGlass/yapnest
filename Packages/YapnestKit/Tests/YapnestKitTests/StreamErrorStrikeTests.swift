import Foundation
import GRDB
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let bob = YapnestKit.JID("bob@example.org")!

private func streamError(_ condition: String) -> XMPPClient.State.DisconnectionReason {
    let error = Element(name: "error", xmlns: "http://etherx.jabber.org/streams")
    error.addChild(Element(name: condition, xmlns: "urn:ietf:params:xml:ns:xmpp-streams"))
    return .streamError(error)
}

/// As ejabberd writes it: the explanation comes before the condition.
private func streamErrorWithText(_ condition: String) -> XMPPClient.State.DisconnectionReason {
    let error = Element(name: "error", xmlns: "http://etherx.jabber.org/streams")
    error.addChild(Element(name: "text", cdata: "not well-formed (invalid token)", xmlns: "urn:ietf:params:xml:ns:xmpp-streams"))
    error.addChild(Element(name: condition, xmlns: "urn:ietf:params:xml:ns:xmpp-streams"))
    return .streamError(error)
}

/// A server that closes the stream on a stanza it dislikes makes it the oldest one left
/// unacknowledged, and it is written first again on every reconnect, with everything behind it stuck.
/// After three such closes it is given up.
struct StreamErrorStrikeTests {
    let database: AppDatabase
    let session: XMPPSession
    var wire = FakeWire()
    let sm: StreamManagementModule

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        sm = session.client.module(.streamManagement)
        wire.countsWith(sm)
        session.connectForTesting(wire)
        session.enableAcknowledgementsForTesting()
        try session.setEncrypted(false, with: alice)
        try session.setEncrypted(false, with: bob)
    }

    /// A reconnect that the server's stream error ended before anything was acknowledged: a new
    /// session, so the queue starts over, and what is pending is written again.
    private func reconnect() {
        sm.reset()
        session.connectForTesting(wire)
        session.enableAcknowledgementsForTesting()
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        session.drainSendQueue(bob)
    }

    private func ack(_ count: UInt32) {
        let ack = Stanza(name: "a", xmlns: "urn:xmpp:sm:3")
        ack.setAttribute("h", value: String(count))
        sm.processAckAnswer(ack)
    }

    /// The release of held stanzas runs off Martin's queues.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func close(with reason: XMPPClient.State.DisconnectionReason) {
        session.client.update(state: .disconnected(reason))
    }

    private func stored(_ message: YapnestKit.Message) throws -> YapnestKit.Message {
        try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
    }

    private func strikes(_ id: String?) -> Int? {
        guard let id else { return nil }
        return session.lock.withLock { $0.streamErrorStrikes[id] }
    }

    private func written(_ id: String?) -> Int {
        wire.messages.filter { $0.id == id }.count
    }

    @Test func aMessageTheServerClosesTheStreamOnThreeTimesIsFailedAndTheNextOneIsWritten() throws {
        let poison = try session.send("poison", to: alice)
        let after = try session.send("after", to: alice)
        session.drainSendQueue(alice)
        close(with: streamError("policy-violation"))
        #expect(strikes(poison.remoteId) == 1)
        #expect(strikes(after.remoteId) == nil)

        reconnect()
        close(with: streamError("policy-violation"))
        #expect(strikes(poison.remoteId) == 2)
        #expect(try stored(poison).status == .pending)

        reconnect()
        close(with: streamError("policy-violation"))
        let failed = try stored(poison)
        #expect(failed.status == .failed)
        #expect(failed.error == "The server closed the connection each time this message was sent.")
        #expect(strikes(poison.remoteId) == nil)
        #expect(try stored(after).status == .pending)

        let poisonWrites = written(poison.remoteId)
        let afterWrites = written(after.remoteId)
        reconnect()
        #expect(written(poison.remoteId) == poisonWrites)
        #expect(written(after.remoteId) == afterWrites + 1)
    }

    @Test func aConditionAfterAnExplanationStrikes() throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        close(with: streamErrorWithText("not-well-formed"))
        #expect(strikes(message.remoteId) == 1)
    }

    @Test func twoStrikesDoNotFailAMessage() throws {
        let poison = try session.send("poison", to: alice)
        session.drainSendQueue(alice)
        close(with: streamError("policy-violation"))
        reconnect()
        close(with: streamError("not-well-formed"))
        reconnect()
        #expect(try stored(poison).status == .pending)
        #expect(strikes(poison.remoteId) == 2)
        #expect(written(poison.remoteId) == 3)
    }

    @Test func anAcknowledgementClearsTheStrikes() throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        close(with: streamError("policy-violation"))
        #expect(strikes(message.remoteId) == 1)

        reconnect()
        let ack = Stanza(name: "a", xmlns: "urn:xmpp:sm:3")
        ack.setAttribute("h", value: "1")
        sm.processAckAnswer(ack)
        #expect(strikes(message.remoteId) == nil)
        #expect(try stored(message).status == .sent)
    }

    @Test(arguments: ["system-shutdown", "conflict", "see-other-host", "reset", "connection-timeout", "undefined-condition", "internal-server-error"])
    func conditionsThatSayNothingAboutWhatWeSentNeverStrike(condition: String) throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        for _ in 0..<4 {
            close(with: streamError(condition))
            reconnect()
        }
        #expect(strikes(message.remoteId) == nil)
        #expect(try stored(message).status == .pending)
    }

    @Test func aDroppedNetworkNeverStrikes() throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        for reason in [XMPPClient.State.DisconnectionReason.timeout, .noRouteToServer, .none] {
            close(with: reason)
            reconnect()
        }
        #expect(strikes(message.remoteId) == nil)
    }

    @Test func aStanzaThatIsNotOursIsNotBlamed() throws {
        // Written at connect and not yet acknowledged when the server gave up on the stream.
        let presence = Presence()
        presence.id = "presence-1"
        wire.write(presence, writeCompleted: nil)
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        #expect(sm.oldestUnacknowledged?.id == "presence-1")
        close(with: streamError("policy-violation"))
        #expect(strikes(message.remoteId) == nil)
        #expect(strikes("presence-1") == nil)
    }

    @Test func aMessageAcknowledgedBeforeTheOneThatFailedIsNotBlamed() throws {
        let first = try session.send("first", to: alice)
        let second = try session.send("second", to: alice)
        session.drainSendQueue(alice)
        let ack = Stanza(name: "a", xmlns: "urn:xmpp:sm:3")
        ack.setAttribute("h", value: "1")
        sm.processAckAnswer(ack)
        close(with: streamError("policy-violation"))
        #expect(strikes(first.remoteId) == nil)
        #expect(strikes(second.remoteId) == 1)
    }

    @Test func nothingIsBlamedOnAStreamWithoutStreamManagement() throws {
        let other = try makeSession(me, database: database)
        let wire = FakeWire()
        other.connectForTesting(wire)
        try other.setEncrypted(false, with: alice)
        let message = try other.send("hello", to: alice)
        other.drainSendQueue(alice)
        other.client.update(state: .disconnected(streamError("policy-violation")))
        #expect(other.lock.withLock { $0.streamErrorStrikes.isEmpty })
        #expect(try stored(message).status != .failed)
    }

    @Test func anAcknowledgementIsRequestedBeforeTheFirstMessageIsWrittenAgain() throws {
        let message = try session.send("hello", to: alice)
        session.drainSendQueue(alice)
        close(with: streamError("policy-violation"))
        sm.reset()
        session.connectForTesting(wire)
        session.enableAcknowledgementsForTesting()
        let before = wire.written.count
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        let after = wire.written.dropFirst(before)
        let request = after.firstIndex { $0.name == "r" }
        let resend = after.firstIndex { $0.id == message.remoteId }
        #expect(request != nil && resend != nil && request! < resend!)
    }

    @Test func aCorrectionTheServerClosesTheStreamOnThreeTimesIsGivenUp() throws {
        let conversation = try #require(try database.conversation(with: alice).id)
        let original = try database.insert(YapnestKit.Message(
            conversationId: conversation, direction: .outgoing, sender: me, body: "hello", status: .sent, remoteId: "m1",
        ))
        try session.edit(original, to: "hello there")
        session.drainSendQueue(alice)
        let actionId = try #require(try stored(original).actionPendingId)
        for _ in 0..<2 {
            close(with: streamError("policy-violation"))
            #expect(try stored(original).actionPendingId == actionId)
            reconnect()
        }
        close(with: streamError("policy-violation"))
        #expect(try stored(original).actionPendingId == nil)
        let writes = written(actionId)
        reconnect()
        #expect(written(actionId) == writes)
    }

    @Test func reactionsTheServerClosesTheStreamOnThreeTimesAreGivenUp() throws {
        let conversation = try #require(try database.conversation(with: alice).id)
        let incoming = try database.insert(YapnestKit.Message(conversationId: conversation, direction: .incoming, sender: alice, body: "hi", remoteId: "1"))
        wire.failsWrites = true
        try session.toggleReaction("👍", on: incoming, peer: alice)
        wire.failsWrites = false
        let id = try #require(try database.reader.read { try Reaction.fetchOne($0)?.pendingId })
        reconnect()
        for _ in 0..<2 {
            close(with: streamError("policy-violation"))
            #expect(try database.reader.read { try Reaction.fetchOne($0)?.pendingId } == id)
            reconnect()
        }
        close(with: streamError("policy-violation"))
        #expect(try database.reader.read { try Reaction.fetchOne($0)?.pendingId } == nil)
        let writes = written(id)
        reconnect()
        #expect(written(id) == writes)
    }

    // MARK: Probation

    @Test func aStanzaStruckOnceIsSentAloneAndTheRestWaitsForItsAcknowledgement() async throws {
        let first = try session.send("first", to: alice)
        let second = try session.send("second", to: bob)
        session.drainSendQueue(alice); session.drainSendQueue(bob)
        close(with: streamError("policy-violation"))
        #expect(strikes(first.remoteId) == 1)

        reconnect()
        session.drainSendQueue(bob)
        #expect(written(first.remoteId) == 2)
        #expect(written(second.remoteId) == 1)
        let fresh = try session.send("fresh", to: alice)
        session.drainSendQueue(alice)
        #expect(written(fresh.remoteId) == 0)
        #expect(try stored(fresh).status == .pending)

        ack(1)
        #expect(await eventually { written(second.remoteId) == 2 && written(fresh.remoteId) == 1 })
        #expect(strikes(first.remoteId) == nil)
    }

    @Test func anInnocentMessageAheadOfThePoisonIsNotFailed() async throws {
        let innocent = try session.send("fine", to: alice)
        let poison = try session.send("poison", to: bob)
        session.drainSendQueue(alice); session.drainSendQueue(bob)
        close(with: streamError("policy-violation"))
        #expect(strikes(innocent.remoteId) == 1)

        // Alone, the innocent one is acknowledged, and the poison is written after it.
        reconnect()
        ack(1)
        #expect(await eventually { written(poison.remoteId) == 2 })
        #expect(try stored(innocent).status == .sent)
        close(with: streamError("policy-violation"))
        #expect(strikes(poison.remoteId) == 1)
        for _ in 0..<2 {
            reconnect()
            close(with: streamError("policy-violation"))
        }
        #expect(try stored(poison).status == .failed)
        #expect(try stored(innocent).status == .sent)
    }

    @Test func aCloseWithOtherMessagesUnacknowledgedIsNotAConfirmedStrike() throws {
        let first = try session.send("first", to: alice)
        session.drainSendQueue(alice)
        close(with: streamError("policy-violation"))
        reconnect()
        // Something else of ours got onto the stream behind it, as a rate limit would close it.
        let other = Message()
        other.id = "other"
        other.to = Martin.JID("bob@example.org")
        wire.write(other, writeCompleted: nil)
        close(with: streamError("policy-violation"))
        #expect(strikes(first.remoteId) == 1)
        #expect(try stored(first).status == .pending)
    }

    @Test func anUnrelatedCloseOnProbationGivesNoStrike() throws {
        let first = try session.send("first", to: alice)
        session.drainSendQueue(alice)
        close(with: streamError("policy-violation"))
        reconnect()
        close(with: streamError("system-shutdown"))
        #expect(strikes(first.remoteId) == 1)
        reconnect()
        close(with: .timeout)
        #expect(strikes(first.remoteId) == 1)
        #expect(session.lock.withLock { $0.probation } == nil)
    }

    @Test func theRestIsReleasedAfterTheBoundedWaitWithoutAnAcknowledgement() async throws {
        let first = try session.send("first", to: alice)
        let second = try session.send("second", to: bob)
        session.drainSendQueue(alice); session.drainSendQueue(bob)
        close(with: streamError("policy-violation"))
        session.lock.withLock { $0.probationTimeout = 0.2 }
        reconnect()
        #expect(written(second.remoteId) == 1)
        #expect(await eventually { written(second.remoteId) == 2 })
        #expect(strikes(first.remoteId) == 1)
    }

    @Test func aControlCharacterIsStrippedWhereTheTextIsStoredSoOffsetsMatch() throws {
        let conversation = try #require(try database.conversation(with: alice).id)
        let original = try database.insert(YapnestKit.Message(conversationId: conversation, direction: .incoming, sender: alice, body: "hi", remoteId: "in1"))
        let sent = try session.send("a\u{1B}b hello", to: alice, replyingTo: original)
        session.drainSendQueue(alice)
        #expect(sent.body == "ab hello")
        let wired = try #require(wire.messages.first { $0.id == sent.remoteId })
        #expect(wired.body?.hasSuffix("ab hello") == true)
        let range = wired.firstChild(name: "fallback", xmlns: NS.fallback)?.firstChild(name: "body")
        let end = Int(range?.attribute("end") ?? "") ?? -1
        #expect(String(wired.body!.unicodeScalars.dropFirst(end)) == "ab hello")
    }
}
