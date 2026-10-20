import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct UnreadCountsTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!, bob = JID("bob@example.org")!, carol = JID("carol@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func unread(_ count: Int, from peer: JID) throws -> Int64 {
        let id = try db.conversation(with: peer).id!
        for index in 0..<count {
            try db.insert(Message(conversationId: id, direction: .incoming, sender: peer, body: "m\(index)", timestamp: Date(timeIntervalSince1970: Double(index)), remoteId: "\(peer)-\(index)"))
        }
        return id
    }

    private func counts() async throws -> [JID: Int] {
        for try await value in db.observeUnreadCounts().values(in: db.reader, bufferingPolicy: .bufferingNewest(1)) { return value }
        return [:]
    }

    @Test func archivedAndDeletedChatsAreLeftOut() async throws {
        _ = try unread(2, from: alice)
        let archived = try unread(3, from: bob)
        let deleted = try unread(4, from: carol)
        try db.setArchived(true, conversationId: archived)
        _ = try db.deleteConversation(id: deleted)

        #expect(try await counts() == [alice: 2])
    }

    @Test func aChatComesBackWhenItIsNoLongerArchived() async throws {
        let id = try unread(3, from: bob)
        try db.setArchived(true, conversationId: id)
        #expect(try await counts().isEmpty)
        try db.setArchived(false, conversationId: id)
        #expect(try await counts() == [bob: 3])
    }

    @Test func aGroupThatNeverNotifiesCountsNone() async throws {
        let room = JID("cake@rooms.example.org")!
        let group = try db.joinGroupChat(room, nickname: "me")
        try db.insert(Message(conversationId: group.conversationId, direction: .incoming, sender: alice, body: "hi", remoteId: "g1"))
        #expect(try await counts()[room] == 1)
        try db.updateGroupChat(room) { $0.notify = .never }
        #expect(try await counts()[room] == 0)
    }

    private func mentionOnlyGroup() throws -> (room: JID, id: Int64) {
        let room = JID("cake@rooms.example.org")!
        let group = try db.joinGroupChat(room, nickname: "me")
        let id = group.conversationId
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: alice, body: "mine", isRead: true, serverId: "ours"))
        var flagged = Message(conversationId: id, direction: .incoming, sender: alice, body: "flagged", remoteId: "g1")
        flagged.mentionsMe = true
        try db.insert(flagged)
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "hey Me, look", remoteId: "g2"))
        var reply = Message(conversationId: id, direction: .incoming, sender: alice, body: "agreed", remoteId: "g3")
        reply.replyToId = "ours"
        try db.insert(reply)
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "something about home", remoteId: "g4"))
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "nothing", remoteId: "g5"))
        var otherReply = Message(conversationId: id, direction: .incoming, sender: alice, body: "to bob", remoteId: "g6")
        otherReply.replyToId = "theirs"
        try db.insert(otherReply)
        try db.updateGroupChat(room) { $0.notify = .onMention }
        return (room, id)
    }

    @Test func aMentionOnlyGroupCountsItsMentions() async throws {
        let (room, _) = try mentionOnlyGroup()
        #expect(try db.unreadCount() == 3)
        #expect(try await counts()[room] == 3)
    }

    @Test func aMentionOnlyGroupCountsAllOnceItAlwaysNotifies() async throws {
        let (room, _) = try mentionOnlyGroup()
        try db.updateGroupChat(room) { $0.notify = .always }
        #expect(try db.unreadCount() == 6)
        #expect(try await counts()[room] == 6)
    }

    @Test func theBadgeSumsMentionsAndOtherChats() async throws {
        let (room, _) = try mentionOnlyGroup()
        _ = try unread(2, from: bob)
        #expect(try db.unreadCount() == 5)
        #expect(try await counts() == [room: 3, bob: 2])
    }

    private func item(_ peer: JID, archived: Bool = false) throws -> ChatListItem {
        try #require(try db.chatList(archived: archived).first { $0.conversation.peer == peer })
    }

    @Test func theChatListCountsWhatNotifiesBesideWhatIsUnread() throws {
        _ = try unread(2, from: alice)
        #expect(try item(alice).notifyingUnreadCount == 2)
        #expect(try item(alice).unreadCount == 2)

        let (room, _) = try mentionOnlyGroup()
        #expect(try item(room).notifyingUnreadCount == 3)
        #expect(try item(room).unreadCount == 6)

        try db.updateGroupChat(room) { $0.notify = .always }
        #expect(try item(room).notifyingUnreadCount == 6)

        try db.updateGroupChat(room) { $0.notify = .never }
        #expect(try item(room).notifyingUnreadCount == 0)
        #expect(try item(room).unreadCount == 6)
    }

    @Test func anArchivedGroupInTheArchivedListCountsTheSameWay() throws {
        let (room, id) = try mentionOnlyGroup()
        try db.setArchived(true, conversationId: id)
        #expect(try db.chatList().isEmpty)
        #expect(try item(room, archived: true).notifyingUnreadCount == 3)
        #expect(try item(room, archived: true).unreadCount == 6)
    }

    @Test func theBadgeStillLeavesOutArchivedChats() async throws {
        let (room, id) = try mentionOnlyGroup()
        try db.setArchived(true, conversationId: id)
        #expect(try await counts()[room] == nil)
        #expect(try db.unreadCount() == 0)
    }
}
