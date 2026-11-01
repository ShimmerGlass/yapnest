import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The chat list, the badge, the conversation, the unread count, the search
/// and the GIF favourites are watched by tables listed by hand, as what they
/// read changes with the data and GRDB would fetch on the writer to follow it.
/// A table left out would leave them stale after a change there, so these
/// compare the lists with what the fetches read. The database holds something
/// for each branch of a fetch.
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

    @Test func theGifFavoritesWatchEveryTableTheyRead() async throws {
        #expect(try await missing(from: AppDatabase.gifFavoritesTables) { _ = try AppDatabase.gifFavorites($0) } == [])
    }

    @Test func theSearchWatchesEveryTableItReads() async throws {
        let pattern = try #require(AppDatabase.searchPattern(for: "hi"))
        let conversationId = try await db.writer.read { try Conversation.fetchOne($0)!.id! }
        #expect(try await missing(from: AppDatabase.searchTables) { _ = try AppDatabase.searchMatches($0, pattern: pattern, in: conversationId, limit: 10) } == [])
    }
}

/// The observations whose reads don't change with the data let GRDB record
/// their tables (`trackingConstantRegion`). A table a fetch stops reading, or
/// an observation moved to a region that is too narrow, would leave the
/// screen stale, so each is written to in every table it reads.
struct ConstantRegionObservationTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let room = JID("room@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
        let id = try db.conversation(with: alice).id!
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: JID("me@example.org")!, body: "hi", timestamp: Date(timeIntervalSince1970: 1), remoteId: "m1"))
        try db.writer.write { try Contact(jid: alice).insert($0) }
        try db.joinGroupChat(room, nickname: "me")
    }

    private final class Count: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
    }

    /// Whether `observation` notifies again after `write`.
    private func reemits<R: ValueReducer>(_ observation: ValueObservation<R>, after write: @escaping @Sendable (AppDatabase) throws -> Void) async throws -> Bool where R.Value: Sendable {
        let count = Count()
        let running = observation.start(in: db.reader, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { _ in
            count.lock.withLock { count.value += 1 }
        })
        defer { running.cancel() }
        guard await eventually(timeout: 30, { count.lock.withLock { count.value } >= 1 }) else { return false }
        // Whatever the first fetch after the start repeats is let settle.
        _ = await eventually(timeout: 0.3) { false }
        let before = count.lock.withLock { count.value }
        try write(db)
        return await eventually(timeout: 5) { count.lock.withLock { count.value } > before }
    }

    @Test func aContactIsWatchedForItsRow() async throws {
        let alice = alice
        #expect(try await reemits(db.observeContact(alice)) { db in
            try db.writer.write { var contact = try Contact.fetchOne($0, key: alice)!; contact.requestedNickname = "A"; try contact.update($0) }
        })
    }

    @Test func contactNamesAndRequestsAreWatchedForContacts() async throws {
        let alice = alice
        let change: @Sendable (AppDatabase) throws -> Void = { db in
            try db.writer.write { var contact = try Contact.fetchOne($0, key: alice)!; contact.subscriptionRequestedAt = Date(); try contact.update($0) }
        }
        #expect(try await reemits(db.observeContactNames(), after: change))
        #expect(try await reemits(db.observeContactRequests()) { db in
            try db.writer.write { var contact = try Contact.fetchOne($0, key: alice)!; contact.subscriptionRequestedAt = nil; contact.requestedNickname = "B"; try contact.update($0) }
        })
    }

    @Test func aGroupIsWatchedForItsRow() async throws {
        let room = room
        #expect(try await reemits(db.observeGroupChat(room)) { _ = try $0.joinGroupChat(room, nickname: "me", name: "Renamed") })
    }

    @Test func theArchivedCountIsWatchedForConversations() async throws {
        let alice = alice
        #expect(try await reemits(db.observeArchivedCount()) { db in
            try db.writer.write { _ = try Conversation.filter(Column("peer") == alice).updateAll($0, Column("isArchived").set(to: true)) }
        })
    }

    @Test func aChatsLinkPreviewChoiceIsWatchedForItsConversation() async throws {
        let alice = alice
        #expect(try await reemits(db.observeLinkPreviews(peer: alice)) { try $0.setLinkPreviews(true, peer: alice) })
    }

    @Test func groupInvitationsAreWatchedForInvitations() async throws {
        let alice = alice
        #expect(try await reemits(db.observeGroupInvitations()) { try $0.recordGroupInvitation(room: JID("other@example.org")!, inviter: alice, reason: nil) })
    }

    @Test func deviceNoticesAreWatchedForNotices() async throws {
        #expect(try await reemits(db.observeDeviceNotices()) { try $0.addDeviceNoticeForFixture(id: 7, keyByte: 1) })
    }

    @Test func aDeliveryStateIsWatchedForItsMessage() async throws {
        let id = try await db.writer.read { try Message.fetchOne($0)!.id! }
        #expect(try await reemits(db.observeDeliveryState(id: id)) { db in
            try db.writer.write { try $0.execute(sql: "UPDATE \(Message.databaseTableName) SET error = 'x' WHERE id = ?", arguments: [id]) }
        })
    }

    @Test func theSettingFlagsAreWatchedForSettings() async throws {
        #expect(try await reemits(db.observeLinkPreviewSetting()) { try $0.setLinkPreviewSetting(.never) })
        #expect(try await reemits(db.observeGifsEnabled()) { try $0.setFlag(.gifs, false) })
        #expect(try await reemits(db.observeProfilePending()) { try $0.queueNicknameChange("New") })
        let session = try makeSession(JID("me@example.org")!, database: db)
        #expect(try await reemits(session.observeOwnStatus()) { try $0.setSetting(.availability, "dnd") })
    }

    @Test func thePublisherIsWatchedForMarksAndForEntries() async throws {
        #expect(try await reemits(AppDatabase.observeDirtySettings()) { db in
            try db.writer.write { try AppDatabase.markDirty($0, "global") }
        })
        // An item already marked stays as it was when it changes again; only its entry's write says so.
        try await db.writer.write { try AppDatabase.markDirty($0, "global") }
        #expect(try await reemits(AppDatabase.observeDirtySettings()) { db in
            try db.writer.write { try AppDatabase.touch($0, item: "global", key: "k", value: "v") }
        })
    }
}
