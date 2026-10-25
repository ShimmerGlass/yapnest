import Foundation
import GRDB
@testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
private typealias Message = YapnestKit.Message

/// A server answers a stanza it can't deliver with an error of the stanza's id,
/// long after stream management acknowledged it. A correction, a retraction and
/// reactions have ids of their own, so the error must find them, and the user
/// must be told when one never reached the other side.
struct ServerBounceTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let message: YapnestKit.Message

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        session.enableAcknowledgementsForTesting()
        // No wait between a passing bounce and the next try.
        session.lock.withLock { $0.bounceBackoff = 0 }
        try session.setEncrypted(false, with: alice)
        let id = try #require(try database.conversation(with: alice).id)
        message = try database.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "hello", status: .sent, remoteId: "m1"))
    }

    private func stored() throws -> Message {
        try #require(try database.reader.read { try Message.fetchOne($0, key: message.id!) })
    }

    private func item() throws -> ConversationItem {
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        return try #require(items.first { $0.id == message.id })
    }

    private func corrections() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "replace", xmlns: NS.correction) != nil }
    }

    private func retractions() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "retract", xmlns: NS.retraction) != nil }
    }

    private func reactionStanzas() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }
    }

    private func bounce(_ id: String, type: String = "cancel", condition: String = "forbidden", from: YapnestKit.JID = alice) {
        let stanza: Martin.Message = parseStanza("""
        <message type='error' from='\(from)' to='me@example.org/t' id='\(id)'>
        <error type='\(type)'><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
        <text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Nope</text></error></message>
        """)
        session.handle(stanza, source: .live)
    }

    private func sentCorrection() throws -> String {
        try session.edit(message, to: "hello there")
        session.drainSendQueue(alice)
        let stanza = try #require(corrections().first)
        session.acknowledged(stanza)
        #expect(try stored().actionPendingId == nil)
        return try #require(stanza.id)
    }

    private func incoming() throws -> Message {
        try database.insert(Message(conversationId: message.conversationId, direction: .incoming, sender: alice, body: "hi", remoteId: "i1"))
    }

    // MARK: Final

    @Test func aCorrectionTheServerRefusedAfterItWasAcknowledgedIsRecorded() throws {
        let id = try sentCorrection()
        bounce(id)

        let after = try stored()
        #expect(after.body == "hello there")
        #expect(after.actionError == "The edit couldn't be delivered: Nope (forbidden)")
        #expect(try item().message.actionError == after.actionError)
    }

    @Test func aRetractionTheServerRefusedAfterItWasAcknowledgedIsRecorded() throws {
        try session.retract(message)
        session.drainSendQueue(alice)
        let stanza = try #require(retractions().first)
        session.acknowledged(stanza)
        bounce(try #require(stanza.id), type: "modify", condition: "bad-request")

        let after = try stored()
        #expect(after.isRetracted)
        #expect(after.body == "")
        #expect(after.actionError == "The deletion couldn't be delivered: Nope (bad-request)")
    }

    @Test func reactionsTheServerRefusedAfterTheyWereAcknowledgedAreFailed() throws {
        try session.toggleReaction("👍", on: try incoming(), peer: alice)
        let stanza = try #require(reactionStanzas().first)
        session.acknowledged(stanza)
        bounce(try #require(stanza.id))

        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        let group = try #require(items.flatMap(\.reactions).first)
        #expect(group.error == "The reaction couldn't be delivered: Nope (forbidden)")
        #expect(!group.isPending)
    }

    @Test func anErrorFromSomeoneElseIsNotTaken() throws {
        let id = try sentCorrection()
        bounce(id, from: YapnestKit.JID("mallory@example.org")!)
        #expect(try stored().actionError == nil)
        bounce(id)
        #expect(try stored().actionError != nil)
    }

    @Test func aBounceOfAnOlderStanzaForTheSameMessageIsIgnored() throws {
        let first = try sentCorrection()
        try session.edit(try stored(), to: "hello again")
        session.drainSendQueue(alice)
        bounce(first)
        #expect(try stored().actionError == nil)
    }

    @Test func retryingAFailedEditSendsItAgainAndClearsTheError() throws {
        let id = try sentCorrection()
        bounce(id)
        #expect(try stored().actionError != nil)

        try session.retryAction(on: try stored())
        session.drainSendQueue(alice)
        #expect(try stored().actionError == nil)
        let resent = try #require(corrections().last)
        #expect(corrections().count == 2)
        #expect(resent.id != id)
        #expect(resent.body == "hello there")
        #expect(try stored().actionPendingId == resent.id)
    }

    @Test func retryingReactionsSendsThemAgainAndRemovingSendsTheEmptySet() throws {
        let incoming = try incoming()
        try session.toggleReaction("👍", on: incoming, peer: alice)
        let stanza = try #require(reactionStanzas().first)
        session.acknowledged(stanza)
        bounce(try #require(stanza.id))

        try session.retryReactions(on: incoming, peer: alice)
        #expect(reactionStanzas().count == 2)
        #expect(try database.reader.read { try Reaction.fetchOne($0)?.error } == nil)

        let second = try #require(reactionStanzas().last)
        session.acknowledged(second)
        bounce(try #require(second.id))
        try session.removeReactions(on: incoming, peer: alice)
        let emojis = reactionStanzas().last?.firstChild(name: "reactions", xmlns: NS.reactions)?.filterChildren(name: "reaction", xmlns: nil)
        #expect(emojis?.isEmpty == true)
        #expect(try database.reader.read { try Reaction.fetchCount($0) } == 0)
    }

    // MARK: Passing

    @Test func aPassingBounceOfACorrectionIsSentAgainAndTheThirdIsFinal() throws {
        let id = try sentCorrection()
        bounce(id, type: "wait", condition: "recipient-unavailable")
        session.drainSendQueue(alice)
        #expect(try stored().actionError == nil)
        #expect(corrections().map(\.id) == [id, id])

        bounce(id, type: "wait", condition: "resource-constraint")
        session.drainSendQueue(alice)
        #expect(try stored().actionError == nil)
        #expect(corrections().count == 3)

        bounce(id, type: "wait", condition: "recipient-unavailable")
        session.drainSendQueue(alice)
        #expect(corrections().count == 3)
        #expect(try stored().actionPendingId == nil)
        #expect(try stored().actionError == "The edit couldn't be delivered: Nope (recipient-unavailable)")
    }

    @Test func aPassingBounceOfReactionsPendsThemAgain() throws {
        try session.toggleReaction("👍", on: try incoming(), peer: alice)
        let stanza = try #require(reactionStanzas().first)
        let id = try #require(stanza.id)
        session.acknowledged(stanza)
        bounce(id, type: "wait", condition: "recipient-unavailable")

        #expect(reactionStanzas().map(\.id) == [id, id])
        #expect(try database.reader.read { try Reaction.fetchOne($0)?.pendingId } == id)
        #expect(try database.reader.read { try Reaction.fetchOne($0)?.error } == nil)
    }

    @Test func aPassingBounceOfAMessageSendsItAgainInsteadOfFailingIt() throws {
        let sent = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        let id = try #require(sent.remoteId)
        func texts() -> [Martin.Message] { wire.messages.filter { $0.id == id } }
        #expect(texts().count == 1)

        bounce(id, type: "wait", condition: "recipient-unavailable")
        session.drainSendQueue(alice)
        #expect(texts().count == 2)
        let after = try #require(try database.reader.read { try Message.fetchOne($0, key: sent.id!) })
        #expect(after.status != .failed)
        #expect(after.error == nil)
    }

    @Test func aFinalBounceOfAMessageFailsItWithTheServersWords() throws {
        let sent = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        let id = try #require(sent.remoteId)
        bounce(id, type: "cancel", condition: "service-unavailable")
        let after = try #require(try database.reader.read { try Message.fetchOne($0, key: sent.id!) })
        #expect(after.status == .failed)
        #expect(after.error == "The recipient's server refused the message: Nope (service-unavailable)")
    }

    @Test func aBounceOfAMessageNotInTheLedgerIsLeftToIngest() throws {
        bounce("m1", type: "cancel", condition: "service-unavailable")
        #expect(try stored().status == .failed)
    }

    // MARK: Router

    @Test func onlyThePeerItsServerAndOurAccountMayAnswer() {
        let error = ServerError(condition: "forbidden")
        let room = YapnestKit.JID("cake@rooms.example.org")!
        func accepted(_ from: YapnestKit.JID?, peer: YapnestKit.JID = alice) -> Bool {
            var router = BounceRouter()
            router.register("a", .init(key: .message("k"), peer: peer, handle: { _ in }))
            return router.route("a", from: from, account: me, error: error) != nil
        }
        #expect(accepted(alice))
        #expect(accepted(YapnestKit.JID("example.org")!))
        #expect(accepted(YapnestKit.JID("rooms.example.org")!, peer: room))
        #expect(accepted(me))
        #expect(accepted(nil))
        #expect(!accepted(YapnestKit.JID("evil.net")!))
        #expect(!accepted(YapnestKit.JID("mallory@evil.net")!))
        #expect(!accepted(YapnestKit.JID("rooms.evil.net")!, peer: room))
    }

    @Test func aForeignServerCannotFailOurStanza() throws {
        let id = try sentCorrection()
        bounce(id, from: YapnestKit.JID("evil.net")!)
        #expect(try stored().actionError == nil)
    }

    @Test func theLedgerSweepsOnlyWhenItHasDoubled() {
        var router = BounceRouter()
        let now = Date()
        for index in 0..<(BounceRouter.pruneThreshold * 2 + 10) {
            router.register("id\(index)", .init(key: .message("k\(index)"), peer: alice, handle: { _ in }), now: now)
        }
        #expect(router.pruneRuns == 2)
    }

    // MARK: Ordering

    /// A room can answer before the server acknowledges the stanza.
    @Test func anAcknowledgementAfterAPassingBounceKeepsACorrectionPending() throws {
        session.lock.withLock { $0.bounceBackoff = 3600 }
        try session.edit(message, to: "hello there")
        session.drainSendQueue(alice)
        let stanza = try #require(corrections().first)
        bounce(try #require(stanza.id), type: "wait", condition: "policy-violation")
        session.acknowledged(stanza)
        #expect(try stored().actionPendingId == stanza.id)
    }

    @Test func anAcknowledgementAfterAPassingBounceKeepsReactionsPending() throws {
        session.lock.withLock { $0.bounceBackoff = 3600 }
        try session.toggleReaction("👍", on: try incoming(), peer: alice)
        let stanza = try #require(reactionStanzas().first)
        bounce(try #require(stanza.id), type: "wait", condition: "policy-violation")
        session.acknowledged(stanza)
        #expect(try database.reader.read { try Reaction.fetchOne($0)?.pendingId } == stanza.id)
    }

    @Test func anAcknowledgementAfterAPassingBounceKeepsAMessagePending() throws {
        session.lock.withLock { $0.bounceBackoff = 3600 }
        let sent = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        let stanza = try #require(wire.messages.first { $0.id == sent.remoteId })
        bounce(try #require(stanza.id), type: "wait", condition: "policy-violation")
        session.acknowledged(stanza)
        let after = try #require(try database.reader.read { try Message.fetchOne($0, key: sent.id!) })
        #expect(after.status == .pending)
    }

    // MARK: Superseded

    @Test func aBounceOfAnOlderEditLeavesTheNewerOneBe() throws {
        let id = try sentCorrection()
        _ = try database.applyEdit("hello again", to: message.id!, actionId: "B")
        bounce(id)
        #expect(try stored().actionError == nil)
        #expect(try stored().actionPendingId == "B")

        bounce(id, type: "wait", condition: "recipient-unavailable")
        #expect(try stored().actionPendingId == "B")
    }

    @Test func aBounceOfOlderReactionsLeavesTheNewerOnesBe() throws {
        let incoming = try incoming()
        try session.toggleReaction("👍", on: incoming, peer: alice)
        let stanza = try #require(reactionStanzas().first)
        session.acknowledged(stanza)
        try database.setReactions(["👍", "❤️"], from: Author(jid: me), conversationId: incoming.conversationId, messageRef: "i1", pendingId: "B")
        bounce(try #require(stanza.id))
        let rows = try database.reader.read { try Reaction.fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.pendingId == "B" && $0.error == nil })
    }

    // MARK: Changes from elsewhere

    @Test func aRetractionFromAnotherDeviceClearsAFailedEdit() throws {
        let id = try sentCorrection()
        bounce(id)
        #expect(try stored().deliveryProblem == .editNotDelivered)

        let carbon = parseStanza("<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='r1'><retract id='m1' xmlns='urn:xmpp:message-retract:1'/></message>") as Martin.Message
        try database.ingest(try #require(InboundMessage(carbon, account: me, source: .live, now: Date())))
        let after = try stored()
        #expect(after.isRetracted)
        #expect(after.actionError == nil)
        #expect(after.deliveryProblem == nil)
    }

    @Test func aRetractionFromAnotherDeviceDropsAnEditStillPending() throws {
        _ = try database.applyEdit("hello again", to: message.id!, actionId: "B")
        let carbon = parseStanza("<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='r1'><retract id='m1' xmlns='urn:xmpp:message-retract:1'/></message>") as Martin.Message
        try database.ingest(try #require(InboundMessage(carbon, account: me, source: .live, now: Date())))
        #expect(try stored().actionPendingId == nil)
    }

    @Test func aCorrectionFromAnotherDeviceClearsAFailedEdit() throws {
        let id = try sentCorrection()
        bounce(id)
        let carbon = parseStanza("<message from='me@example.org/laptop' to='alice@example.org' type='chat' id='c1'><body>other</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>") as Martin.Message
        try database.ingest(try #require(InboundMessage(carbon, account: me, source: .live, now: Date().addingTimeInterval(60))))
        let after = try stored()
        #expect(after.body == "other")
        #expect(after.actionError == nil)
    }

    // MARK: Left rooms

    @Test func retryingInARoomWeLeftKeepsTheError() throws {
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        let conversation = try #require(try database.conversation(with: room).id)
        let mine = try database.insert(Message(
            conversationId: conversation, direction: .outgoing, sender: me, body: "hi", status: .sent, remoteId: "g1", serverId: "s1",
        ))
        _ = try database.applyEdit("hi all", to: mine.id!, actionId: "A")
        try database.clearPendingAction(id: "A", error: "nope")
        let incoming = try database.insert(Message(conversationId: conversation, direction: .incoming, sender: room, body: "x", remoteId: "g2", serverId: "s2"))
        session.leaveRoom(room)

        let failed = try #require(try database.reader.read { try Message.fetchOne($0, key: mine.id!) })
        #expect(throws: XMPPSession.MessageActionError.leftGroup) { try session.retryAction(on: failed) }
        #expect(try database.reader.read { try Message.fetchOne($0, key: mine.id!)?.actionError } == "nope")
        #expect(throws: XMPPSession.MessageActionError.leftGroup) { try session.retryReactions(on: incoming, peer: room) }
        #expect(throws: XMPPSession.MessageActionError.leftGroup) { try session.removeReactions(on: incoming, peer: room) }
    }

    @Test func theLedgerForgetsAStanzaAfterItsLifetime() {
        var router = BounceRouter()
        let start = Date()
        let error = ServerError(condition: "forbidden")
        router.register("a", .init(key: .message("k"), peer: alice, handle: { _ in }), now: start)
        #expect(router.route("a", from: alice, account: me, error: error, now: start.addingTimeInterval(BounceRouter.lifetime + 1)) == nil)
        router.register("a", .init(key: .message("k"), peer: alice, handle: { _ in }), now: start)
        #expect(router.route("a", from: alice, account: me, error: error, now: start.addingTimeInterval(60)) != nil)
    }
}
