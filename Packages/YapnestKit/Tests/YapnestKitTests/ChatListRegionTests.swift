import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The chat list, the badge and the other observations are watched by the
/// tables they read, which are listed by hand. A table left out would leave
/// them stale after a change there, so these compare the lists with what the
/// fetches read. The database holds something for each branch of a fetch.
struct ChatListRegionTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
        // A message with a file, so every part of the fetch runs.
        let id = try db.conversation(with: alice).id!
        let message = try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "hi", timestamp: Date(timeIntervalSince1970: 1), remoteId: "m1"))
        try db.writer.write { db in
            try Attachment(messageId: message.id!, url: "https://example.org/a.png", name: "a.png", mimeType: "image/png", state: .pendingUpload).insert(db)
        }
        // A reply with a link, a reaction and a preview, so the conversation's quote, reaction and preview reads run.
        var reply = Message(conversationId: id, direction: .incoming, sender: alice, body: "re https://example.org/x", timestamp: Date(timeIntervalSince1970: 2), remoteId: "m2", replyToId: "m1")
        reply.link = "https://example.org/x"
        let stored = try db.insert(reply)
        try db.writer.write { db in
            try Reaction(messageId: message.id!, sender: alice, emoji: "x").insert(db)
            try LinkPreview(url: "https://example.org/x", kind: .page, title: "t", fetchedAt: Date(timeIntervalSince1970: 3)).insert(db)
            try Contact(jid: alice, subscriptionRequestedAt: Date(timeIntervalSince1970: 4)).insert(db)
            _ = stored
        }
        try db.addDeviceNoticeForFixture(id: 7, keyByte: 1)
        try db.recordGroupInvitation(room: JID("room@example.org")!, inviter: alice, reason: nil)
        try db.setSetting(.availability, "away")
    }

    /// The region GRDB itself works out from what `fetch` reads.
    private func readRegion(_ fetch: @escaping @Sendable (Database) throws -> Void) async throws -> DatabaseRegion {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var region: DatabaseRegion?
        }
        let box = Box()
        let observation = ValueObservation.tracking { db in try fetch(db) }
            .handleEvents(willTrackRegion: { region in box.lock.withLock { box.region = region } })
            .start(in: db.writer, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { _ in })
        defer { observation.cancel() }
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let region = box.lock.withLock({ box.region }) { return region }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    /// Tables whose change the fetch's own reads would notice but `watched` wouldn't.
    private func missing(from watched: [any DatabaseRegionConvertible], reading fetch: @escaping @Sendable (Database) throws -> Void) async throws -> [String] {
        let read = try await readRegion(fetch)
        return try await db.writer.read { db in
            var declared = DatabaseRegion()
            for table in watched { declared.formUnion(try table.databaseRegion(db)) }
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            return tables.filter { table in
                read.isModified(byEventsOfKind: .insert(tableName: table)) && !declared.isModified(byEventsOfKind: .insert(tableName: table))
            }
        }
    }

    @Test func theChatListWatchesEveryTableItReads() async throws {
        #expect(try await missing(from: AppDatabase.chatListTables) { _ = try ChatListItem.fetch($0, archived: false) } == [])
    }

    @Test func theBadgeWatchesEveryTableItReads() async throws {
        #expect(try await missing(from: AppDatabase.unreadBadgeTables) { _ = try AppDatabase.unreadCounts($0, archived: false) } == [])
    }

    @Test func theConversationWatchesEveryTableItReads() async throws {
        let cache = ConversationItemCache(me: JID("me@example.org")!)
        let alice = alice
        #expect(try await missing(from: AppDatabase.conversationTables) { _ = try cache.fetch($0, peer: alice, since: nil) } == [])
    }

    @Test func theUnreadCountWatchesEveryTableItReads() async throws {
        let alice = alice
        #expect(try await missing(from: AppDatabase.unreadCountTables) { _ = try AppDatabase.unreadCount($0, peer: alice) } == [])
    }

    @Test func theContactNamesWatchEveryTableTheyRead() async throws {
        #expect(try await missing(from: AppDatabase.contactTables) { _ = try AppDatabase.contactNames($0) } == [])
    }

    @Test func theContactRequestsWatchEveryTableTheyRead() async throws {
        #expect(try await missing(from: AppDatabase.contactTables) { _ = try AppDatabase.contactRequests($0) } == [])
    }

    @Test func aContactIsWatchedByItsRow() async throws {
        let alice = alice
        #expect(try await missing(from: [Contact.filter(key: alice)]) { _ = try Contact.fetchOne($0, key: alice) } == [])
    }

    @Test func aGroupIsWatchedByItsRow() async throws {
        let room = JID("room@example.org")!
        #expect(try await missing(from: [GroupChat.filter(Column("jid") == room)]) { _ = try GroupChat.filter(Column("jid") == room).fetchOne($0) } == [])
    }

    @Test func aChatsLinkPreviewChoiceIsWatchedByItsConversation() async throws {
        let alice = alice
        #expect(try await missing(from: [Conversation.filter(Column("peer") == alice)]) { _ = try AppDatabase.existingConversation($0, peer: alice)?.linkPreviews } == [])
    }

    @Test func theArchivedCountWatchesEveryTableItReads() async throws {
        #expect(try await missing(from: AppDatabase.archivedCountTables) { _ = try AppDatabase.archivedCount($0) } == [])
    }

    @Test func theGroupInvitationsWatchEveryTableTheyRead() async throws {
        #expect(try await missing(from: AppDatabase.groupInvitationTables) { _ = try AppDatabase.groupInvitations($0) } == [])
    }

    @Test func theDeviceNoticesWatchEveryTableTheyRead() async throws {
        #expect(try await missing(from: AppDatabase.deviceNoticeTables) { _ = try AppDatabase.deviceNotices($0) } == [])
    }

    @Test func aDeliveryStateIsWatchedByItsRow() async throws {
        let id = try await db.writer.read { try Message.fetchOne($0)!.id! }
        #expect(try await missing(from: [Message.filter(key: id)]) { _ = try Message.fetchOne($0, key: id) } == [])
    }

    private func settingsMissing(_ fetch: @escaping @Sendable (Database) throws -> Void) async throws -> [String] {
        try await missing(from: AppDatabase.settingTables, reading: fetch)
    }

    @Test func theLinkPreviewSettingWatchesEveryTableItReads() async throws {
        #expect(try await settingsMissing { _ = try AppDatabase.setting($0, .linkPreviews) } == [])
    }

    @Test func theProfilePendingWatchesEveryTableItReads() async throws {
        #expect(try await settingsMissing { db in
            _ = try AppDatabase.setting(db, .owedAvatarChange)
            _ = try AppDatabase.setting(db, .owedNicknameChange)
        } == [])
    }

    @Test func theOwnStatusWatchesEveryTableItReads() async throws {
        #expect(try await settingsMissing { db in
            _ = try AppDatabase.setting(db, .availability)
            _ = try AppDatabase.setting(db, .statusMessage)
        } == [])
    }

    @Test func theGifSettingWatchesEveryTableItReads() async throws {
        #expect(try await settingsMissing { _ = try AppDatabase.flag($0, .gifs, default: true) } == [])
    }

    @Test func theGifFavoritesWatchEveryTableTheyRead() async throws {
        #expect(try await missing(from: AppDatabase.gifFavoritesTables) { _ = try AppDatabase.gifFavorites($0) } == [])
    }

    @Test func thePublisherWatchesEveryTableItReads() async throws {
        #expect(try await missing(from: AppDatabase.dirtySettingsTables) { _ = try AppDatabase.dirtySettings($0) } == [])
    }

    @Test func theSearchWatchesEveryTableItReads() async throws {
        let pattern = try #require(AppDatabase.searchPattern(for: "hi"))
        let conversationId = try await db.writer.read { try Conversation.fetchOne($0)!.id! }
        #expect(try await missing(from: AppDatabase.searchTables) { _ = try AppDatabase.searchMatches($0, pattern: pattern, in: conversationId, limit: 10) } == [])
    }
}
