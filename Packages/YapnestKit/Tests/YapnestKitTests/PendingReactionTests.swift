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

    private func pendingId() throws -> String? {
        try database.reader.read { try OwnReaction.fetchOne($0)?.pendingId }
    }

    private func record() throws -> OwnReaction? {
        try database.reader.read { try OwnReaction.fetchOne($0) }
    }

    private func isPending() throws -> Bool {
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        return items.contains { $0.ownReactions == .pending }
    }

    private func reactionStanzas() -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }
    }

    @Test func aToggledReactionIsPendingUntilItsStanzaIsAcknowledged() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)

        let stanza = try #require(reactionStanzas().first)
        let id = try #require(stanza.id)
        #expect(try pendingId() == id)
        #expect(try isPending())

        session.acknowledged(stanza)
        #expect(try pendingId() == nil)
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

        try carbonFromOtherDevice(id: try #require(try pendingId()), emojis: ["👍", "❤️"])

        #expect(try rows().count == 2)
        #expect(try record() == nil)
        #expect(!(try isPending()))
    }

    @Test func onlyOurOwnPendingReactionsShowAsSending() throws {
        session.enableAcknowledgementsForTesting()
        try database.setReactions(["👀"], from: Author(jid: alice), conversationId: message.conversationId, messageRef: "1")
        try session.toggleReaction("👍", on: message, peer: alice)
        #expect(try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }.first?.showsReactionsPending == true)
        // Taking ours back leaves only theirs, which aren't waiting on us.
        try session.toggleReaction("👍", on: message, peer: alice)
        let item = try #require(try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }.first)
        #expect(item.ownReactions == .pending)
        #expect(!item.showsReactionsPending)
    }

    @Test func aNewSessionSendsAPendingReactionAgainWithTheSameIdOnce() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        let id = try #require(reactionStanzas().first?.id)

        // A resumed stream is left to Martin: it's still written.
        session.sendUnclaimedPending()
        #expect(reactionStanzas().count == 1)

        // A new one starts over, having lost what was unacknowledged.
        session.lock.withLock { $0.pendingStanzas.reset() }
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
        session.lock.withLock { $0.pendingStanzas.reset() }
        session.sendUnclaimedPending()

        #expect(reactionStanzas().count == 1)
        #expect(!(try isPending()))
    }

    private let room = YapnestKit.JID("cake@rooms.example.org")!

    private func roomMessage(_ direction: YapnestKit.Message.Direction, remoteId: String, serverId: String?) throws -> YapnestKit.Message {
        try database.joinGroupChat(room, nickname: "me")
        session.reloadKnownRooms()
        let id = try #require(try database.conversation(with: room).id)
        return try database.insert(YapnestKit.Message(
            conversationId: id, direction: direction, sender: direction == .incoming ? room : me, body: "hi", remoteId: remoteId, serverId: serverId,
        ))
    }

    @Test func aPendingReactionInARoomWeLeftIsDroppedNotQueuedEverySession() throws {
        let message = try roomMessage(.incoming, remoteId: "g1", serverId: "s1")
        session.updateRoom(room) {
            var status = RoomStatus(phase: .joined, nickname: "me")
            status.isSyncing = true
            $0 = status
        }
        try database.setReactions(["👍"], from: Author(jid: me, nick: "me"), conversationId: message.conversationId, messageRef: "s1", pendingId: "r1")
        #expect(try isPending(in: room))

        session.leaveRoom(room)
        session.sendUnclaimedPending()
        #expect(reactionStanzas().isEmpty)
        #expect(!(try isPending(in: room)))
        #expect(try record()?.error == nil)
    }

    private func isPending(in peer: YapnestKit.JID) throws -> Bool {
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: peer, me: me) }
        return items.contains { $0.ownReactions == .pending }
    }

    @Test func reactingToAGroupMessageTheRoomHasntEchoedYetThrows() throws {
        _ = try roomMessage(.incoming, remoteId: "g0", serverId: "s0")
        let mine = try roomMessage(.outgoing, remoteId: "g1", serverId: nil)
        #expect(throws: XMPPSession.MessageActionError.notYetConfirmed) { try session.toggleReaction("👍", on: mine, peer: room) }
        #expect(try rows().isEmpty)
    }

    @Test func reactingInARoomThatGivesNoStanzaIdsThrowsAnotherError() throws {
        let message = try roomMessage(.incoming, remoteId: "g1", serverId: nil)
        #expect(throws: XMPPSession.MessageActionError.cannotReact) { try session.toggleReaction("👍", on: message, peer: room) }
        #expect(try rows().isEmpty)
    }

    private func joinedRoomMessage() throws -> YapnestKit.Message {
        let message = try roomMessage(.incoming, remoteId: "g1", serverId: "s1")
        session.updateRoom(room) {
            var status = RoomStatus(phase: .joined, nickname: "me")
            status.isSyncing = true
            $0 = status
        }
        return message
    }

    /// A message carrying our `emojis` for the message `target`, as the server
    /// delivers it. `to` is left out of a room's.
    private func reactionStanza(from: String, to: String? = nil, type: String, id: String, target: String, emojis: [String]) throws -> Martin.Message {
        let xml = "<message from='\(from)'\(to.map { " to='\($0)'" } ?? "") type='\(type)' id='\(id)'><reactions id='\(target)' xmlns='urn:xmpp:reactions:0'>"
            + emojis.map { "<reaction>\($0)</reaction>" }.joined() + "</reactions></message>"
        let element = try #require(Element.from(string: xml))
        return try #require(Stanza.from(element: element) as? Martin.Message)
    }

    private func echo(id: String, emojis: [String]) throws {
        let stanza = try reactionStanza(from: "cake@rooms.example.org/me", type: "groupchat", id: id, target: "s1", emojis: emojis)
        let context = RoomContext(jid: room, nickname: "me")
        let inbound = try #require(InboundMessage(groupchat: stanza, room: context, account: me, source: .live))
        try database.ingest(inbound)
    }

    @Test func theEchoOfAnEarlierReactionStanzaLeavesANewerPendingSetAlone() throws {
        let message = try joinedRoomMessage()
        try session.toggleReaction("👍", on: message, peer: room)
        let first = try #require(try pendingId())
        try session.toggleReaction("❤️", on: message, peer: room)
        let second = try #require(try pendingId())
        #expect(first != second)

        try echo(id: first, emojis: ["👍"])

        #expect(Set(try rows().map(\.emoji)) == ["👍", "❤️"])
        #expect(try pendingId() == second)
        #expect(try isPending(in: room))

        try echo(id: second, emojis: ["👍", "❤️"])
        #expect(try pendingId() == nil)
    }

    @Test func reactingInARoomWeLeftThrowsAndLeavesNothingPending() throws {
        let message = try joinedRoomMessage()
        try database.setReactions(["👍"], from: Author(jid: me, nick: "me"), conversationId: message.conversationId, messageRef: "s1")
        session.leaveRoom(room)
        #expect(throws: XMPPSession.MessageActionError.leftGroup) { try session.toggleReaction("❤️", on: message, peer: room) }
        #expect(Set(try rows().map(\.emoji)) == ["👍"])
        #expect(!(try isPending(in: room)))
    }

    private func ingestOneToOne(from: String, id: String, emojis: [String], source: InboundMessage.Source) throws -> InboundMessage {
        let stanza = try reactionStanza(from: from, to: "alice@example.org", type: "chat", id: id, target: "1", emojis: emojis)
        let inbound = try #require(InboundMessage(stanza, account: me, source: source, now: Date()))
        try database.ingest(inbound)
        return inbound
    }

    private func carbonFromOtherDevice(id: String, emojis: [String]) throws {
        _ = try ingestOneToOne(from: "me@example.org/laptop", id: id, emojis: emojis, source: .carbon(sent: true))
    }

    // MARK: Taking the last reaction back

    @Test func takingBackTheLastReactionOfflineIsStoredAndSentOnceConnected() throws {
        let offline = try makeSession(me, database: database)
        try database.setReactions(["👍"], from: Author(jid: me), conversationId: message.conversationId, messageRef: "1")
        try offline.toggleReaction("👍", on: message, peer: alice)

        #expect(try rows().isEmpty)
        let id = try #require(try pendingId())
        #expect(try isOwnPending())

        let wire = FakeWire()
        offline.connectForTesting(wire)
        offline.sendUnclaimedPending()
        let stanza = try #require(wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }.first)
        #expect(stanza.id == id)
        #expect(stanza.firstChild(name: "reactions", xmlns: NS.reactions)?.children.isEmpty == true)

        offline.enableAcknowledgementsForTesting()
        offline.acknowledged(stanza)
        #expect(try record() == nil)
    }

    @Test func aPassingBounceOfTheEmptySetMakesItPendingAgain() throws {
        session.enableAcknowledgementsForTesting()
        try database.setReactions(["👍"], from: Author(jid: me), conversationId: message.conversationId, messageRef: "1")
        try session.toggleReaction("👍", on: message, peer: alice)
        let stanza = try #require(reactionStanzas().first)
        let id = try #require(stanza.id)
        session.acknowledged(stanza)
        #expect(try record() == nil)

        try database.repend(.reactions(messageId: message.id!), id: id, ifNotSupersededBy: id)

        #expect(try pendingId() == id)
        #expect(try isOwnPending())
    }

    @Test func aFinalErrorOfTheEmptySetShowsAsFailedWithNoRows() throws {
        session.enableAcknowledgementsForTesting()
        try database.setReactions(["👍"], from: Author(jid: me), conversationId: message.conversationId, messageRef: "1")
        try session.toggleReaction("👍", on: message, peer: alice)
        let id = try #require(try pendingId())

        try database.clearPending(.reaction, id: id, error: "Nope")

        #expect(try rows().isEmpty)
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items.first?.ownReactions == .failed("Nope"))
        #expect(try record()?.pendingId == nil)
    }

    private func isOwnPending() throws -> Bool {
        let items = try database.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        return items.contains { $0.ownReactions == .pending }
    }

    // MARK: Another of our devices

    @Test func aCarbonOfAnotherDevicesSetWhileOursIsPendingIsIgnoredAndOursStillGoesOut() throws {
        let offline = try makeSession(me, database: database)
        try offline.toggleReaction("👍", on: message, peer: alice)
        let id = try #require(try pendingId())

        try carbonFromOtherDevice(id: "other-device", emojis: ["❤️"])

        #expect(Set(try rows().map(\.emoji)) == ["👍"])
        #expect(try pendingId() == id)
        let wire = FakeWire()
        offline.connectForTesting(wire)
        offline.sendUnclaimedPending()
        let sent = reactionStanzas(in: wire)
        #expect(sent.map(\.id) == [id])

        offline.enableAcknowledgementsForTesting()
        offline.acknowledged(try #require(sent.first))
        #expect(try record() == nil)
    }

    @Test func theEchoOfOursSettlesItAndALaterCarbonOfAnotherDevicesSetIsApplied() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        try carbonFromOtherDevice(id: try #require(try pendingId()), emojis: ["👍"])
        #expect(try record() == nil)

        try carbonFromOtherDevice(id: "other-device", emojis: ["❤️"])

        #expect(Set(try rows().map(\.emoji)) == ["❤️"])
    }

    @Test func aCarbonOfAnotherDevicesSetAfterTheAcknowledgementIsApplied() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        session.acknowledged(try #require(reactionStanzas().first))
        #expect(try record() == nil)

        try carbonFromOtherDevice(id: "other-device", emojis: ["❤️"])

        #expect(Set(try rows().map(\.emoji)) == ["❤️"])
    }

    private func reactionStanzas(in wire: FakeWire) -> [Martin.Message] {
        wire.messages.filter { $0.firstChild(name: "reactions", xmlns: NS.reactions) != nil }
    }

    @Test func aLateRoomEchoOfAnAcknowledgedEarlierStanzaAfterANewToggleIsIgnored() throws {
        let message = try joinedRoomMessage()
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: room)
        let first = try #require(try pendingId())
        try database.clearPending(.reaction, id: first)
        #expect(try record() == nil)
        try session.toggleReaction("👍", on: message, peer: room)
        let second = try #require(try pendingId())

        try echo(id: first, emojis: ["👍"])
        #expect(try rows().isEmpty)
        #expect(try pendingId() == second)

        try echo(id: second, emojis: [])
        #expect(try record() == nil)
    }

    private func archivedFromUs(id: String, emojis: [String]) throws {
        let inbound = try ingestOneToOne(from: "me@example.org", id: id, emojis: emojis, source: .archive(serverId: "a-\(id)", timestamp: Date(timeIntervalSince1970: 100)))
        #expect(inbound.isOutgoing)
    }

    @Test func anArchivedReplayOfAnOlderSetLeavesOursPendingAlone() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        let first = try #require(reactionStanzas().first)
        session.acknowledged(first)
        #expect(try record() == nil)
        try session.toggleReaction("👍", on: message, peer: alice)
        let second = try #require(try pendingId())
        #expect(try rows().isEmpty)

        try archivedFromUs(id: try #require(first.id), emojis: ["👍"])

        #expect(try rows().isEmpty)
        #expect(try pendingId() == second)
        #expect(try database.pendingReactions().map(\.id) == [second])
    }

    @Test func aReplayOfTheLatestPendingIdStillCountsAsItsEcho() throws {
        session.enableAcknowledgementsForTesting()
        try session.toggleReaction("👍", on: message, peer: alice)
        let id = try #require(try pendingId())

        try archivedFromUs(id: id, emojis: ["❤️"])

        #expect(Set(try rows().map(\.emoji)) == ["❤️"])
        #expect(try record() == nil)
    }
}
