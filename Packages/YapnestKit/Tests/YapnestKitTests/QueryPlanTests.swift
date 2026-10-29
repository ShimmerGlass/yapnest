import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The app never runs ANALYZE, so SQLite plans from the schema alone, and a
/// query a person would call indexed can still scan a 40,000-message chat.
/// Each test runs the real function, takes the SQL GRDB made of it and reads
/// the plan SQLite gives that statement. An empty database gets the plan a
/// full one does, as there are no statistics either way.
struct QueryPlanTests {
    let db: AppDatabase
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!
    let room = JID("room@conference.example.org")!
    var chat: Int64 = 0
    var group: Int64 = 0

    init() throws {
        db = try AppDatabase.inMemory()
        chat = try db.conversation(with: alice).id!
        group = try db.joinGroupChat(room, nickname: "me").conversationId
        for index in 0..<5 {
            try db.insert(Message(
                conversationId: chat, direction: index % 2 == 0 ? .incoming : .outgoing, sender: index % 2 == 0 ? alice : me, body: "m\(index)",
                timestamp: Date(timeIntervalSince1970: 1000 + Double(index)), remoteId: "r\(index)", originId: "o\(index)", serverId: "s\(index)",
            ))
        }
    }

    struct Statement {
        var sql: String
        var plan: String
    }

    /// Every statement `body` runs that holds `marker`, with the plan of what
    /// was run (the values in place) and the SQL as GRDB made it.
    private func statements(containing marker: String, _ body: () throws -> Void) throws -> [Statement] {
        let log = Collected<String>()
        try db.writer.write { database in
            database.trace { event in
                if case .statement(let statement) = event, !statement.sql.hasPrefix("--") {
                    log.add(statement.sql)
                }
            }
        }
        defer { try? db.writer.write { $0.trace(options: .statement, nil) } }
        try body()
        try db.writer.write { $0.trace(options: .statement, nil) }
        return try log.all.filter { $0.contains(marker) }.map { sql in
            // The statement as GRDB prepares it, with its values unknown, as
            // SQLite plans it: a partial index can't serve a condition that is
            // a bound value, which a plan of the expanded SQL would not show.
            let arguments = StatementArguments(Array(repeating: DatabaseValue.null, count: sql.filter { $0 == "?" }.count))
            let plan = try db.writer.read { database in
                try Row.fetchAll(database, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }.joined(separator: " | ")
            }
            return Statement(sql: sql, plan: plan)
        }
    }

    private func expectIndexed(_ statements: [Statement], using index: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!statements.isEmpty, "the statement was not run", sourceLocation: sourceLocation)
        for statement in statements {
            #expect(statement.plan.contains(index), "\(statement.plan)", sourceLocation: sourceLocation)
            #expect(!statement.plan.contains("SCAN message"), "\(statement.plan)", sourceLocation: sourceLocation)
        }
    }

    private func expectOneIndexLookupPerBranch(_ statements: [Statement], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!statements.isEmpty, "the statement was not run", sourceLocation: sourceLocation)
        for statement in statements {
            #expect(statement.plan.contains("MULTI-INDEX OR"), "\(statement.plan)", sourceLocation: sourceLocation)
            #expect(!statement.plan.contains("SCAN message"), "\(statement.plan)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Identifiers

    @Test func aStanzaIdIsLookedUpWithinItsConversation() throws {
        let probe = Message(conversationId: chat, direction: .incoming, sender: alice, body: "", serverId: "s3")
        let found = try statements(containing: "serverId") { _ = try db.writer.read { try AppDatabase.duplicate(of: probe, $0) } }
        expectIndexed(found, using: "message_on_conversation_serverId")
    }

    @Test func aDuplicateIsLookedUpByEachIdWithinItsConversation() throws {
        let probe = Message(conversationId: chat, direction: .incoming, sender: alice, body: "", remoteId: "r3", originId: "o3")
        let found = try statements(containing: "originId") { _ = try db.writer.read { try AppDatabase.duplicate(of: probe, $0) } }
        expectOneIndexLookupPerBranch(found)
    }

    @Test func aReferenceIsLookedUpByEachIdWithinItsConversation() throws {
        let found = try statements(containing: "serverId") {
            _ = try db.writer.read { try AppDatabase.referencedMessage($0, conversationId: chat, id: "s2", direction: .outgoing) }
        }
        expectOneIndexLookupPerBranch(found)
    }

    @Test func aReplysTargetIsLookedUpByEachIdWithinItsConversation() throws {
        let found = try statements(containing: "serverId") {
            _ = try db.writer.read {
                try AppDatabase.addressesUs($0, conversationId: group, body: "", mentionsMe: false, replyToId: "x", nickname: "")
            }
        }
        expectOneIndexLookupPerBranch(found)
    }

    @Test func quotesAreLookedUpByEachIdWithinTheirConversation() throws {
        try db.insert(Message(conversationId: chat, direction: .incoming, sender: alice, body: "re", timestamp: Date(timeIntervalSince1970: 2000), replyToId: "r1"))
        let found = try statements(containing: "\"originId\"") {
            _ = try db.writer.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
            _ = try db.writer.read { try ConversationItemCache(me: me).fetch($0, peer: alice, since: nil) }
        }
        let lookups = found.filter { $0.sql.contains(" OR ") }
        #expect(lookups.count == 2)
        expectOneIndexLookupPerBranch(lookups)
    }

    // MARK: Windows

    @Test func aWindowStartingAtACursorIsARangeOfTheIndex() throws {
        let cursor = MessageCursor(timestamp: Date(timeIntervalSince1970: 1002), id: 3)
        let found = try statements(containing: "FROM \"message\" WHERE") {
            _ = try db.writer.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: cursor) }
            _ = try db.writer.read { try AppDatabase.conversationItems($0, peer: alice, me: me, until: cursor) }
        }
        let windows = found.filter { $0.sql.contains("\"timestamp\"") && $0.sql.contains("ORDER BY") }
        #expect(windows.count == 2)
        for window in windows {
            #expect(window.plan.contains("conversationId=? AND timestamp"), "\(window.plan)")
            #expect(window.plan.contains("timestamp>?") || window.plan.contains("timestamp<?"), "\(window.plan)")
        }
    }

    // MARK: Unread

    @Test func theUnreadQueriesUseThePartialIndex() throws {
        let hasUnread = try statements(containing: "isRead") {
            _ = try db.hasUnread(conversationId: chat, through: .distantFuture)
            _ = try db.unreadMessageCount(peer: alice)
            _ = try db.openingWindow(peer: alice)
        }
        #expect(hasUnread.count == 3)
        for statement in hasUnread {
            #expect(statement.sql.contains("isRead = 0"), "the index only serves a condition written as a literal: \(statement.sql)")
        }
        expectIndexed(hasUnread, using: "message_unread")
    }

    @Test func markingReadUsesThePartialIndex() throws {
        let found = try statements(containing: "UPDATE \"message\" SET \"isRead\"") { try db.markRead(conversationId: chat) }
        #expect(found.first?.sql.contains("isRead = 0") == true)
        expectIndexed(found, using: "message_unread")
    }

    /// The badge's counts and its dot come from one query, the chat list's.
    @Test func theBadgeIsOneIndexedCountOfTheChats() throws {
        let all = try statements(containing: "isArchived") {
            let seen = Seen()
            let queue = DispatchQueue(label: "badge")
            let cancellable = db.observeUnreadBadge().start(in: db.writer, scheduling: .async(onQueue: queue), onError: { _ in }, onChange: { _ in seen.set() })
            let deadline = Date().addingTimeInterval(5)
            while !seen.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            cancellable.cancel()
        }
        #expect(all.count == 1)
        #expect(all.allSatisfy { $0.sql.contains("mentions") })
        expectIndexed(all, using: "message_unread")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false
        func set() { lock.withLock { seen = true } }
        var value: Bool { lock.withLock { seen } }
    }

    @Test func theUnreadCountsOfAllChatsUseTheIndices() throws {
        let found = try statements(containing: "mentions") {
            _ = try db.writer.read { try AppDatabase.unreadCounts($0, archived: false) }
        }
        #expect(found.count == 1)
        for statement in found {
            #expect(statement.plan.contains("message_unread_mention"), "\(statement.plan)")
            #expect(statement.plan.contains("message_unread"), "\(statement.plan)")
            #expect(!statement.plan.contains("SCAN message"), "\(statement.plan)")
        }
    }

    @Test func theChatListCountsUnreadMessagesWithoutJoiningThem() throws {
        let found = try statements(containing: "FROM \"conversation\"") { _ = try db.chatList() }
        #expect(!found.isEmpty)
        for statement in found {
            #expect(!statement.sql.contains("COUNT(DISTINCT"), "\(statement.sql)")
            #expect(!statement.plan.contains("SCAN message"), "\(statement.plan)")
        }
    }

    // MARK: Outgoing messages

    @Test func theMessagesThePeerReadAreFoundByStatus() throws {
        let found = try statements(containing: "SET \"status\" = ") {
            try db.writer.write { try AppDatabase.markDisplayed($0, conversationId: chat, through: .distantFuture) }
        }
        expectIndexed(found, using: "message_outgoing_status")
    }

    @Test func theMessagesOfARoomNotYetSentAreFoundByStatus() throws {
        let found = try statements(containing: "\"status\"") { _ = try db.pendingOutgoing(conversationId: group) }
        expectIndexed(found, using: "message_outgoing_status")
    }

    @Test func theMessagesOfARoomSentAroundItsJoinAreARangeOfTheIndex() throws {
        let found = try statements(containing: "\"status\"") {
            _ = try db.unconfirmedOutgoing(conversationId: group, before: Date(), since: Date().addingTimeInterval(-100))
        }
        #expect(found.count == 1)
        for statement in found {
            #expect(statement.plan.contains("conversationId=? AND timestamp>? AND timestamp<?"), "\(statement.plan)")
        }
    }

    @Test func theUnsentMessagesOfAllChatsAreFoundByStatus() throws {
        let found = try statements(containing: "\"status\"") { _ = try db.unconfirmedOutgoing() }
        expectIndexed(found, using: "message_outgoing_status")
        for statement in found { #expect(!statement.sql.contains("\"timestamp\" >="), "no bounds were asked for: \(statement.sql)") }
    }

    @Test func aPendingMessageIsFoundByItsStanzaId() throws {
        let found = try statements(containing: "\"remoteId\"") { _ = try db.pendingOutgoing(remoteId: "r1") }
        expectIndexed(found, using: "message_pending_remoteId")
    }

    @Test func theChatsWithMessagesAreFoundWithoutScanningThem() throws {
        let found = try statements(containing: "kind = 'chat'") { _ = try db.peersWithMessages() }
        #expect(found.count == 1)
        for statement in found {
            #expect(!statement.plan.contains("SCAN message"), "\(statement.plan)")
            #expect(statement.plan.contains("SEARCH message EXISTS USING INDEX") && statement.plan.contains("(conversationId=?)"), "\(statement.plan)")
        }
    }

    // MARK: Schema

    @Test func theIndicesAreTheOnesTheQueriesUse() throws {
        let names = try db.writer.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'index'") }
        for name in ["message_on_conversation_serverId", "message_unread", "message_unread_mention", "message_outgoing_status",
                     "message_pending_remoteId", "pendingEdit_on_standInId", "message_on_conversation_timestamp"] {
            #expect(names.contains(name), "\(name)")
        }
        for name in ["message_on_serverId", "message_on_conversationId", "newReaction_on_messageId", "pendingEdit_on_createdAt"] {
            #expect(!names.contains(name), "\(name)")
        }
    }

    @Test func deletingAMessageDoesNotScanThePendingEditsForItsStandIn() throws {
        let plan = try db.writer.read { database in
            try Row.fetchAll(database, sql: "EXPLAIN QUERY PLAN SELECT 1 FROM pendingEdit WHERE standInId = 1").map { $0["detail"] as String }.joined()
        }
        #expect(plan.contains("pendingEdit_on_standInId"), "\(plan)")
    }
}
