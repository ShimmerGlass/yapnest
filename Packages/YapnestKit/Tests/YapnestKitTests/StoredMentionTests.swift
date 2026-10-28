import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// Whether a group message is for us is decided when it is stored, so the
/// badge and the chat list never read bodies to count a mention-only group.
struct StoredMentionTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let room = JID("cake@rooms.example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func mentionOnlyRoom(nickname: String = "me") throws -> Int64 {
        let id = try db.joinGroupChat(room, nickname: nickname).conversationId
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: alice, body: "mine", isRead: true, serverId: "ours"))
        try db.updateGroupChat(room) { $0.notify = .onMention }
        return id
    }

    @discardableResult
    private func incoming(_ body: String, in id: Int64, _ remoteId: String, replyTo: String? = nil, mentionsMe: Bool = false) throws -> Message {
        var message = Message(conversationId: id, direction: .incoming, sender: alice, body: body, remoteId: remoteId)
        message.replyToId = replyTo
        message.mentionsMe = mentionsMe
        return try db.insert(message)
    }

    private func stored(_ remoteId: String) throws -> Bool {
        try db.reader.read { try Message.filter(Column("remoteId") == remoteId).fetchOne($0) }?.addressesMe ?? false
    }

    private func notifying() throws -> Int {
        try #require(try db.chatList().first { $0.conversation.peer == room }).notifyingUnreadCount
    }

    @Test func aMessageIsDecidedWhenItIsStored() throws {
        let id = try mentionOnlyRoom()
        try incoming("flagged", in: id, "flag", mentionsMe: true)
        try incoming("hey Me, look", in: id, "nick")
        try incoming("agreed", in: id, "reply", replyTo: "ours")
        try incoming("something about home", in: id, "inside")
        try incoming("nothing", in: id, "none")
        try incoming("to bob", in: id, "other", replyTo: "theirs")
        #expect(try ["flag", "nick", "reply", "inside", "none", "other"].map(stored) == [true, true, true, false, false, false])
    }

    @Test func aCorrectionDecidesAgain() throws {
        let id = try mentionOnlyRoom()
        let message = try incoming("nothing", in: id, "m1")
        #expect(try !stored("m1"))
        _ = try db.writer.write { db in
            var message = message
            return try Self.edit(db, &message, "nothing, me")
        }
        #expect(try stored("m1"))
    }

    private static func edit(_ db: Database, _ message: inout Message, _ body: String) throws -> Message? {
        try AppDatabase.applyCorrection(
            db, to: &message, body: body, at: Date().addingTimeInterval(5), mentionsMe: false,
            quickResponses: nil, omemoDevice: nil, omemoTrust: nil, outgoing: false,
        )
    }

    @Test func anEmptyNicknameMentionsNobody() throws {
        let id = try mentionOnlyRoom(nickname: "")
        try incoming("hello", in: id, "m1")
        try incoming("", in: id, "m2")
        try incoming("flagged", in: id, "m3", mentionsMe: true)
        #expect(try [stored("m1"), stored("m2"), stored("m3")] == [false, false, true])
        #expect(try db.unreadCount() == 1)
    }

    @Test func aNicknameChangeDecidesUnreadMessagesAgain() throws {
        let id = try mentionOnlyRoom()
        try incoming("hi me", in: id, "old")
        try incoming("hi bobby", in: id, "new")
        #expect(try notifying() == 1)

        try db.updateGroupChat(room) { $0.nickname = "bobby" }
        #expect(try [stored("old"), stored("new")] == [false, true])
        #expect(try notifying() == 1)
        #expect(try db.unreadCount() == 1)

        try db.joinGroupChat(room, nickname: "me")
        #expect(try [stored("old"), stored("new")] == [true, false])
    }

    @Test func readMessagesKeepTheirDecisionThroughANicknameChange() throws {
        let id = try mentionOnlyRoom()
        try incoming("hi me", in: id, "old")
        try db.markRead(conversationId: id)
        try db.updateGroupChat(room) { $0.nickname = "bobby" }
        #expect(try stored("old"))
    }

    @Test func countsComeFromTheStoredDecision() async throws {
        let id = try mentionOnlyRoom()
        try incoming("hi me", in: id, "yes")
        try incoming("nothing", in: id, "no")
        #expect(try notifying() == 1)
        #expect(try db.unreadCount() == 1)

        // Rewritten behind the model's back: a count that read the bodies
        // would follow, one that reads the decision does not.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE message SET body = CASE remoteId WHEN 'yes' THEN 'nothing' ELSE 'hi me' END")
        }
        #expect(try notifying() == 1)
        #expect(try db.unreadCount() == 1)
        var counted: Int?
        for try await value in db.observeUnreadBadge().values(in: db.reader, bufferingPolicy: .bufferingNewest(1)) {
            counted = value.counts[room]
            break
        }
        #expect(counted == 1)
    }

    @Test func theMigrationDecidesUnreadMessagesAlreadyStored() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v42-invitation-notified")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (id, peer, kind, lastActivityAt) VALUES (1, 'cake@rooms.example.org', 'groupchat', 0)")
            try db.execute(sql: "INSERT INTO groupChat (conversationId, jid, nickname) VALUES (1, 'cake@rooms.example.org', 'me')")
            for (index, body) in ["hey me", "nothing"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, remoteId)
                    VALUES (1, 'incoming', 'alice@example.org', ?, 0, 'received', 0, 'none', ?)
                    """, arguments: [body, "m\(index)"])
            }
        }
        try AppDatabase.migrator.migrate(queue)
        let flags = try queue.read { try Bool.fetchAll($0, sql: "SELECT addressesMe FROM message ORDER BY id") }
        #expect(flags == [true, false])
    }

    /// The migration reads and writes the columns it needs and nothing of `Message`, so a column a later
    /// migration adds to it can't stop an old database from opening. Here `encryption`, which `Message`
    /// decodes and the migration has no use for, is gone from the table: decoding a `Message` fails.
    @Test func theMigrationNeedsNothingOfMessageButTheColumnsItUses() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v46-signed-prekey-date")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (id, peer, kind, lastActivityAt) VALUES (1, 'cake@rooms.example.org', 'groupchat', 0)")
            try db.execute(sql: "INSERT INTO groupChat (conversationId, jid, nickname) VALUES (1, 'cake@rooms.example.org', 'me')")
            let rows: [(String, String, String, String?, Bool)] = [
                ("word", "hey me, look", "incoming", nil, false),
                ("inside", "something about home", "incoming", nil, false),
                ("reply", "agreed", "incoming", "ours", false),
                ("stranger", "agreed", "incoming", "theirs", false),
                ("flag", "nothing", "incoming", nil, true),
                ("mine", "my own", "outgoing", nil, false),
            ]
            for (id, body, direction, replyTo, mentions) in rows {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, remoteId, serverId, replyToId, mentionsMe)
                    VALUES (1, ?, 'alice@example.org', ?, 0, 'received', ?, 'none', ?, ?, ?, ?)
                    """, arguments: [direction, body, direction == "outgoing", id, id == "mine" ? "ours" : nil, replyTo, mentions])
            }
            try db.execute(sql: "ALTER TABLE message DROP COLUMN encryption")
            #expect(throws: (any Error).self) { try Message.fetchAll(db) }
        }
        // The altered table would make the migrator, which erases a database whose schema changed, start over.
        var migrator = AppDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue, upTo: "v47-addresses-me")
        let flags = try queue.read { try Row.fetchAll($0, sql: "SELECT remoteId, addressesMe FROM message ORDER BY id") }
        #expect(flags.map { $0["remoteId"] as String } == ["word", "inside", "reply", "stranger", "flag", "mine"])
        #expect(flags.map { $0["addressesMe"] as Bool } == [true, false, true, false, true, false])
    }
}
