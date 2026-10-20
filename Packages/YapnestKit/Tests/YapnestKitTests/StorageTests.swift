import Foundation
import Testing
@testable import YapnestKit

struct StorageTests {
    let db: AppDatabase
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func incoming(_ conversation: Conversation, body: String = "hi", remoteId: String? = nil, serverId: String? = nil, at date: Date = Date()) -> Message {
        Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: body, timestamp: date, remoteId: remoteId, originId: remoteId, serverId: serverId)
    }

    @Test func conversationIsCreatedOnce() throws {
        let a = try db.conversation(with: alice)
        let b = try db.conversation(with: JID("ALICE@example.org/laptop")!)
        #expect(a.id == b.id)
    }

    @Test func duplicateFromMAMIsMergedNotInserted() throws {
        let conversation = try db.conversation(with: alice)
        let live = try db.insert(incoming(conversation, remoteId: "m1"))
        let fromArchive = try db.insert(incoming(conversation, remoteId: "m1", serverId: "s1"))

        #expect(fromArchive.id == live.id)
        #expect(fromArchive.serverId == "s1")
        let count = try db.reader.read { try Message.fetchCount($0) }
        #expect(count == 1)

        // Same server id again (e.g. a second MAM page overlap) is also a duplicate.
        _ = try db.insert(incoming(conversation, remoteId: nil, serverId: "s1"))
        #expect(try db.reader.read { try Message.fetchCount($0) } == 1)
    }

    @Test func reactionsReplaceSendersSet() throws {
        let conversation = try db.conversation(with: alice)
        let message = try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "lunch?", remoteId: "out1", originId: "out1"))

        #expect(try db.setReactions(["👍", "😂"], from: alice, conversationId: conversation.id!, messageRef: "out1"))
        #expect(try db.setReactions(["❤️"], from: alice, conversationId: conversation.id!, messageRef: "out1"))
        let reactions = try db.reader.read { try message.request(for: Message.reactions).fetchAll($0) }
        #expect(reactions.map(\.emoji) == ["❤️"])

        #expect(try db.setReactions([], from: alice, conversationId: conversation.id!, messageRef: "out1"))
        #expect(try db.reader.read { try Reaction.fetchCount($0) } == 0)

        #expect(try !db.setReactions(["👍"], from: alice, conversationId: conversation.id!, messageRef: "unknown"))
    }

    @Test func statusOnlyMovesForward() throws {
        let conversation = try db.conversation(with: alice)
        let message = try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: me, body: "x", remoteId: "o1"))
        try db.updateStatus(.displayed, conversationId: conversation.id!, remoteId: "o1")
        try db.updateStatus(.delivered, conversationId: conversation.id!, remoteId: "o1")
        try db.updateStatus(.failed, conversationId: conversation.id!, remoteId: "o1")
        let stored = try db.reader.read { try Message.fetchOne($0, key: message.id) }
        #expect(stored?.status == .displayed)
    }

    @Test func aReadMarkerLeavesUnsentMessagesPending() throws {
        let conversation = try db.conversation(with: alice)
        let id = conversation.id!
        let t0 = Date(timeIntervalSince1970: 1_000)
        // An upload still under way, older than the caption the peer read.
        _ = try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "photo", timestamp: t0, remoteId: "o1"))
        _ = try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "caption", timestamp: t0 + 1, remoteId: "o2"))
        try db.updateStatus(.sent, conversationId: id, remoteId: "o2")

        try db.writer.write { try AppDatabase.markDisplayed($0, conversationId: id, through: t0 + 1) }

        let statuses: [Message.Status] = try db.reader.read { try Message.fetchAll($0).sorted { $0.timestamp < $1.timestamp }.map(\.status) }
        #expect(statuses == [.pending, .displayed])
    }

    @Test func chatListOrderUnreadAndLastMessage() throws {
        let bob = JID("bob@example.org")!
        let ca = try db.conversation(with: alice)
        let cb = try db.conversation(with: bob)
        try db.writer.write { try Contact(jid: alice, name: "Alice", isInRoster: true).insert($0) }

        let t0 = Date(timeIntervalSince1970: 1_000)
        try db.insert(incoming(ca, body: "old", remoteId: "a1", at: t0))
        try db.insert(incoming(ca, body: "newer", remoteId: "a2", at: t0 + 10))
        try db.insert(Message(conversationId: cb.id!, direction: .outgoing, sender: me, body: "yo", timestamp: t0 + 20, remoteId: "b1"))

        var list = try db.chatList()
        #expect(list.map(\.conversation.peer) == [bob, alice])
        #expect(list[1].title == "Alice")
        #expect(list[1].lastMessage?.body == "newer")
        #expect(list[1].unreadCount == 2)
        #expect(list[0].title == "bob")
        #expect(list[0].unreadCount == 0)

        try db.markRead(conversationId: ca.id!)
        list = try db.chatList()
        #expect(list[1].unreadCount == 0)
    }
}

struct ConversationItemTests {
    @Test func groupsReactionsAndResolvesQuotes() throws {
        let db = try AppDatabase.inMemory()
        let me = JID("me@example.org")!, alice = JID("alice@example.org")!, bob = JID("bob@example.org")!
        let conversation = try db.conversation(with: alice)
        let id = conversation.id!
        let t0 = Date(timeIntervalSince1970: 1_000)
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "cake?", timestamp: t0, remoteId: "m1"))
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "yes", timestamp: t0 + 1, remoteId: "m2", replyToId: "m1", replyToSender: me))
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "and?", timestamp: t0 + 2, remoteId: "m3", replyToId: "gone", replyToSender: alice, replyFallback: "old stuff"))
        try db.setReactions(["👍"], from: alice, conversationId: id, messageRef: "m1")
        try db.setReactions(["👍", "🎂"], from: me, conversationId: id, messageRef: "m1")
        try db.setReactions(["🎂"], from: bob, conversationId: id, messageRef: "m1")

        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items.map(\.message.body) == ["cake?", "yes", "and?"])
        #expect(items[0].reactions.map(\.emoji) == ["🎂", "👍"])
        #expect(items[0].reactions[0].senders.map(\.jid) == [bob, me])
        #expect(items[0].reactions.allSatisfy { $0.includesMe })
        #expect(items[1].quote?.text == "cake?")
        #expect(items[1].quote?.messageId == items[0].id)
        #expect(items[2].quote == .init(author: Author(jid: alice), text: "old stuff", messageId: nil))
    }

    @Test func quoteOfAnUndecryptableMessageSaysSo() throws {
        let db = try AppDatabase.inMemory()
        let me = JID("me@example.org")!, alice = JID("alice@example.org")!
        let id = try db.conversation(with: alice).id!
        let t0 = Date(timeIntervalSince1970: 1_000)
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "I sent you an OMEMO encrypted message", timestamp: t0, encryption: .omemoUndecryptable, remoteId: "m1"))
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "what?", timestamp: t0 + 1, remoteId: "m2", replyToId: "m1", replyToSender: alice))

        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items[1].quote?.text == String(localized: "Couldn't decrypt this message"))
        #expect(items[1].quote?.messageId == items[0].id)
    }
}
