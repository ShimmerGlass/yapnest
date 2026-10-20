import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct MessageSearchTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let bob = JID("bob@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @discardableResult
    private func add(_ body: String, to peer: JID? = nil, at time: TimeInterval = 100, encryption: Message.Encryption = .none) throws -> Message {
        let conversation = try db.conversation(with: peer ?? alice)
        return try db.insert(Message(
            conversationId: conversation.id!, direction: .incoming, sender: peer ?? alice, body: body,
            timestamp: Date(timeIntervalSince1970: time), encryption: encryption,
        ))
    }

    private func found(_ query: String, in conversationId: Int64? = nil) throws -> [Int64] {
        try db.searchMessages(query, in: conversationId, limit: 50).map(\.messageId)
    }

    private func checkIndex() throws {
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('integrity-check')")
        }
    }

    @Test func ignoresAccentsAndCase() throws {
        let m = try add("Meet at the Café at five")
        #expect(try found("cafe") == [m.id!])
        #expect(try found("CAFÉ") == [m.id!])
        let n = try add("naive plan")
        #expect(try found("naïve") == [n.id!])
    }

    @Test func matchesPrefixes() throws {
        let m = try add("bonjour tout le monde")
        #expect(try found("bonj") == [m.id!])
        #expect(try found("jour").isEmpty)
    }

    @Test func requiresEveryWord() throws {
        let a = try add("lunch at noon")
        try add("lunch tomorrow")
        #expect(try found("lunch noo") == [a.id!])
        #expect(try found("noon dinner").isEmpty)
    }

    @Test func newestFirstAndLimited() throws {
        let old = try add("hello one", at: 10)
        let new = try add("hello two", at: 20)
        #expect(try found("hello") == [new.id!, old.id!])
        #expect(try db.searchMessages("hello", limit: 1).map(\.messageId) == [new.id!])
    }

    @Test func canBeLimitedToAConversation() throws {
        let a = try add("shared word", to: alice)
        let b = try add("shared word", to: bob)
        #expect(try found("shared", in: a.conversationId) == [a.id!])
        #expect(try found("shared", in: b.conversationId) == [b.id!])
        #expect(Set(try found("shared")) == [a.id!, b.id!])
    }

    @Test func snippetMarksMatches() throws {
        try add("see you at the Café later")
        let result = try #require(try db.searchMessages("cafe").first)
        #expect(result.snippet.contains("\u{E000}Café\u{E001}"))
        #expect(result.sender == alice)
    }

    @Test func leavesOutWhatShouldNotBeFound() throws {
        try add("secret words", encryption: .omemoUndecryptable)
        try add("geo:48.8566,2.3522;u=20")
        try add("aesgcm://example.org/up/abc/photo.jpg#0123456789abcdef")
        let conversation = try db.conversation(with: alice)
        let retracted = try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "taken back"))
        _ = try db.applyRetraction(of: retracted.id!)
        #expect(try found("secret").isEmpty)
        #expect(try found("geo").isEmpty)
        #expect(try found("48").isEmpty)
        #expect(try found("aesgcm").isEmpty)
        #expect(try found("0123456789abcdef").isEmpty)
        #expect(try found("taken").isEmpty)
        try checkIndex()

        // A geo link among text is ordinary text.
        let text = try add("meet at geo:48.85,2.35 ok")
        #expect(try found("meet") == [text.id!])
    }

    @Test func leavesOutAFileLinkOnceItsAttachmentIsStored() throws {
        // The way an incoming file arrives: message first, then its file.
        let m = try add("https://example.org/up/report.pdf")
        #expect(try found("report") == [m.id!])
        try db.writer.write { db in
            try Attachment(messageId: m.id!, url: "https://example.org/up/report.pdf", name: "report.pdf", state: .remote).insert(db)
        }
        #expect(try found("report").isEmpty)
        try checkIndex()

        // Removing the file brings the text back, once.
        try db.writer.write { db in try Attachment.deleteAll(db) }
        #expect(try found("report") == [m.id!])
        try checkIndex()

        // Deleting a message with a file doesn't unindex what was never indexed.
        let f = try add("https://example.org/up/other.pdf")
        try db.writer.write { db in
            try Attachment(messageId: f.id!, url: "https://example.org/up/other.pdf", name: "other.pdf", state: .remote).insert(db)
            try Message.deleteOne(db, key: f.id!)
        }
        try checkIndex()
        #expect(try found("other").isEmpty)
    }

    @Test func correctionUpdatesTheIndex() throws {
        var m = try add("see you at 5")
        m.setBody("see you at the station")
        try db.writer.write { db in try m.update(db) }
        #expect(try found("station") == [m.id!])
        #expect(try found("5").isEmpty)
        try checkIndex()
    }

    @Test func retractionAndUndecryptableRemoveFromTheIndex() throws {
        let a = try add("first thing")
        let b = try add("second thing")
        _ = try db.applyRetraction(of: a.id!)
        try db.writer.write { db in
            var m = try #require(try Message.fetchOne(db, key: b.id!))
            m.encryption = .omemoUndecryptable
            m.body = ""
            try m.update(db)
        }
        #expect(try found("thing").isEmpty)
        try checkIndex()
    }

    @Test func deletingRemovesFromTheIndex() throws {
        let a = try add("keep this")
        let b = try add("drop this", to: bob)
        try db.writer.write { db in try Message.deleteOne(db, key: b.id!) }
        #expect(try found("this") == [a.id!])
        // A whole conversation going takes its messages with it.
        try db.writer.write { db in try Conversation.deleteOne(db, key: a.conversationId) }
        #expect(try found("this").isEmpty)
        try checkIndex()
    }

    @Test func searchSyntaxIsJustText() throws {
        let m = try add("this or that - (really) \"quoted\" *")
        for query in ["\"", "*", "-", "OR", "(", "\"unbalanced", "a OR", "NEAR(a b)", "col:val", "^x", "AND", "NOT", ")("] {
            _ = try db.searchMessages(query, limit: 10)
        }
        #expect(try found("or") == [m.id!])
        #expect(try found("\"quoted\"") == [m.id!])
        #expect(try found("").isEmpty)
        #expect(try found("  ---  ").isEmpty)
    }

    @Test func migrationIndexesExistingMessages() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v17-revisions")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('a@example.org', 'chat', 0)")
            for (body, encryption, retracted) in [("old café news", "none", 0), ("hidden", "omemoUndecryptable", 0), ("gone", "none", 1),
                                                  ("aesgcm://example.org/f.jpg#key", "none", 0), ("geo:1,2", "none", 0)] {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption, isRetracted)
                    VALUES (1, 'incoming', 'a@example.org', ?, 0, 'received', 0, ?, ?)
                    """, arguments: [body, encryption, retracted])
            }
        }
        let migrated = try AppDatabase(queue)
        #expect(try migrated.searchMessages("cafe").map(\.messageId) == [1])
        for word in ["hidden", "gone", "aesgcm", "geo"] {
            #expect(try migrated.searchMessages(word).isEmpty)
        }
        try queue.write { try $0.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('integrity-check')") }
    }
}
