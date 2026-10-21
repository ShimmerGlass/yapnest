import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

/// Yapnest's own settings, merged between devices: see `AppDatabase+SyncedSettings`.
struct SettingsSyncTests {
    let db: AppDatabase
    let alice = YapnestKit.JID("alice@example.org")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        db = try AppDatabase.inMemory()
    }

    /// A time on the real clock that many days ahead, which local changes made now lose to.
    private func ahead(_ days: Double) -> Int64 {
        Int64(Date().addingTimeInterval(days * 86400).timeIntervalSince1970 * 1000)
    }

    private func version(_ ms: Int64, _ counter: Int = 0) -> SettingsVersion { SettingsVersion(ms: ms, counter: counter) }

    private func entry(_ key: String, _ value: String?, _ ms: Int64, counter: Int = 0, by: String = "other") -> SettingsEntry {
        SettingsEntry(key: key, value: value, version: version(ms, counter), by: by)
    }

    private func apply(_ item: String, _ entries: [SettingsEntry], to target: AppDatabase? = nil) throws -> AppDatabase.SyncedApplyResult {
        try (target ?? db).writer.write { try AppDatabase.applyRemote($0, item: item, entries: entries) }
    }

    private func stored(_ item: String, in target: AppDatabase? = nil) throws -> [String: SettingsEntry] {
        let entries = try (target ?? db).reader.read { try AppDatabase.syncedEntries($0, item: item) }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
    }

    private func isDirty(_ item: String, in target: AppDatabase? = nil) throws -> Bool {
        try (target ?? db).reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncedItemDirty WHERE item = ?", arguments: [item]) } == 1
    }

    private func gif(_ id: String) -> Gif {
        Gif(id: id, slug: id, title: id,
            preview: Rendition(url: URL(string: "https://cdn.example/\(id)/sm.gif")!, width: 2, height: 1),
            shared: Rendition(url: URL(string: "https://cdn.example/\(id)/md.gif")!, width: 4, height: 2))
    }

    private func message(_ conversation: Conversation, at seconds: TimeInterval, _ body: String = "hi") -> YapnestKit.Message {
        YapnestKit.Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: body, timestamp: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Wire format

    @Test func versionRoundTripsAndOrders() {
        #expect(SettingsVersion("1729425600123.7")?.description == "1729425600123.7")
        #expect(SettingsVersion("abc") == nil)
        #expect(SettingsVersion("1.2.3") == nil)
        #expect(version(2) > version(1, 9))
        #expect(version(2, 1) > version(2, 0))
        // Compared as numbers, not text.
        #expect(version(1000) > version(999, 5))
    }

    @Test func itemRoundTripsWithUnknownKeysAndTombstones() throws {
        let xml = """
            <settings xmlns='https://yapnest.fr/protocol/settings:0'>\
            <entry key='linkPreviews' v='5.0' by='d1'>never</entry>\
            <entry key='fromTheFuture' v='6.2' by='d2'>x y</entry>\
            <entry key='notificationSound' v='7.0' by='d1'/></settings>
            """
        let item = try #require(SettingsItem(element: Element.from(string: xml)))
        #expect(item.entries.map(\.key) == ["fromTheFuture", "linkPreviews", "notificationSound"])
        #expect(item.entries.first { $0.key == "notificationSound" }?.value == nil)
        #expect(SettingsItem(element: Element.from(string: item.element.stringValue)) == item)
        #expect(SettingsItem(element: Element.from(string: "<settings xmlns='other'/>")) == nil)
    }

    @Test func malformedEntriesAreSkippedAndTheNewestOfADuplicateKeyIsKept() throws {
        let xml = """
            <settings xmlns='https://yapnest.fr/protocol/settings:0'>\
            <entry key='a' v='bad' by='d1'>x</entry><entry key='b' v='1.0'>x</entry>\
            <entry key='c' v='1.0' by='d1'>old</entry><entry key='c' v='2.0' by='d1'>new</entry></settings>
            """
        let item = try #require(SettingsItem(element: Element.from(string: xml)))
        #expect(item.entries.map(\.key) == ["c"])
        #expect(item.entries.first?.value == "new")
    }

    @Test func usageItemRoundTrips() throws {
        var ranking = ReactionRanking()
        ranking.record("👍", at: now)
        ranking.record("🔥", at: now.addingTimeInterval(5))
        let parsed = try #require(ReactionRanking(usage: Element.from(string: ranking.usageElement.stringValue)))
        #expect(parsed.score(of: "👍", at: now) > 0.99)
        #expect(Set(parsed.entries.keys) == ["👍", "🔥"])
        #expect(ReactionRanking(usage: Element.from(string: "<settings xmlns='https://yapnest.fr/protocol/settings:0'/>")) == nil)
    }

    // MARK: Merging

    @Test func aNewerEntryWinsAndATieBreaksOnTheDevice() throws {
        try apply("global", [entry("statusMessage", "old", 100, by: "a")])
        try apply("global", [entry("statusMessage", "newer", 200, by: "a")])
        try apply("global", [entry("statusMessage", "stale", 150, by: "z")])
        #expect(try db.setting(.statusMessage) == "newer")
        try apply("global", [entry("statusMessage", "tie-low", 200, by: "0")])
        #expect(try db.setting(.statusMessage) == "newer")
        try apply("global", [entry("statusMessage", "tie-high", 200, by: "b")])
        #expect(try db.setting(.statusMessage) == "tie-high")
        try apply("global", [entry("statusMessage", "counter", 200, counter: 1, by: "0")])
        #expect(try db.setting(.statusMessage) == "counter")
    }

    @Test func aTombstoneResetsTheValueToItsDefault() throws {
        try db.setFlag(.sendsChatStates, false)
        #expect(db.flag(.sendsChatStates, default: true) == false)
        let tombstone = entry("sendsChatStates", nil, ahead(1))
        try apply("global", [tombstone])
        #expect(try db.setting(.sendsChatStates) == nil)
        #expect(db.flag(.sendsChatStates, default: true))
    }

    @Test func mergingIsCommutativeAndIdempotent() throws {
        let a = [entry("statusMessage", "a", 100, by: "x"), entry("availability", "away", 300, by: "x"), entry("future", "1", 5, by: "x")]
        let b = [entry("statusMessage", "b", 200, by: "y"), entry("availability", "dnd", 300, by: "y"), entry("future", "2", 5, by: "y")]
        let first = try AppDatabase.inMemory(), second = try AppDatabase.inMemory()
        try apply("global", a, to: first)
        try apply("global", b, to: first)
        try apply("global", b, to: first)
        try apply("global", b, to: second)
        try apply("global", a, to: second)
        try apply("global", a, to: second)
        #expect(try stored("global", in: first) == stored("global", in: second))
        #expect(try first.setting(.statusMessage) == second.setting(.statusMessage))
        #expect(try first.setting(.availability) == "dnd")
        #expect(try first.setting(.statusMessage) == "b")
    }

    @Test func unknownKeysAndItemsAreKeptAndPublishedUnchanged() throws {
        try apply("global", [entry("fromTheFuture", "keep me", 10)])
        try apply("widget:7", [entry("size", "big", 11)])
        try db.setSetting(.statusMessage, "mine")
        let pending = try db.pendingSyncItems()
        #expect(pending.map(\.id) == ["global"])
        let republished = try #require(SettingsItem(element: pending.first?.element))
        #expect(republished.entries.contains { $0.key == "fromTheFuture" && $0.value == "keep me" && $0.by == "other" })
        #expect(try stored("widget:7")["size"]?.value == "big")
    }

    @Test func aDeviceBehindOrdersItsChangesAfterWhatItHasSeen() throws {
        let future = ahead(10)
        try apply("global", [entry("statusMessage", "theirs", future, counter: 3)])
        try db.setSetting(.statusMessage, "ours")
        let ours = try #require(try stored("global")["statusMessage"])
        #expect(ours.version == version(future, 4))
        // So it wins over what it had seen, and a replay of theirs doesn't undo it.
        try apply("global", [entry("statusMessage", "theirs", future, counter: 3)])
        #expect(try db.setting(.statusMessage) == "ours")
    }

    @Test func aLosingEntryStillRaisesTheClock() throws {
        let future = ahead(1)
        try apply("global", [entry("statusMessage", "newer", future, by: "z")])
        try apply("global", [entry("statusMessage", "older", future - 5000, counter: 9, by: "z"), entry("availability", "away", future + 77)])
        let clock = try db.reader.read { try AppDatabase.settingsClock($0) }
        #expect(clock == version(future + 77))
    }

    @Test func theClockNeverGoesBackAcrossARelaunch() throws {
        let queue = try DatabaseQueue()
        let first = try AppDatabase(queue)
        let future = ahead(1)
        try apply("global", [entry("statusMessage", "x", future)], to: first)
        try first.setSetting(.availability, "away")
        let issued = try #require(try stored("global", in: first)["availability"]).version
        let relaunched = try AppDatabase(queue)
        try relaunched.setSetting(.statusMessage, "y")
        let next = try #require(try stored("global", in: relaunched)["statusMessage"]).version
        #expect(next > issued)
        #expect(try relaunched.setting(.settingsClock) == next.description)
    }

    @Test func versionsIssuedInTheSameMillisecondStillIncrease() throws {
        try db.writer.write { dbc in
            let a = try AppDatabase.issueVersion(dbc, at: now)
            let b = try AppDatabase.issueVersion(dbc, at: now)
            let c = try AppDatabase.issueVersion(dbc, at: now.addingTimeInterval(-60))
            #expect(a < b && b < c)
        }
    }

    // MARK: Dirty tracking

    @Test func applyingAValueDoesNotMarkTheItem() throws {
        let result = try apply("global", [entry("statusMessage", "hello", 100)])
        #expect(result.markedDirty == false)
        #expect(try db.setting(.statusMessage) == "hello")
        #expect(try !isDirty("global"))
    }

    @Test func holdingANewerEntryMarksTheItemButHoldingNothingNewerDoesNot() throws {
        try apply("global", [entry("statusMessage", "theirs", 100)])
        try db.setSetting(.statusMessage, "ours")
        try db.writer.write { try AppDatabase.clearDirty($0, "global") }
        // The server's copy is older than ours: it is to be published again.
        let stale = try apply("global", [entry("statusMessage", "theirs", 100)])
        #expect(stale.markedDirty)
        #expect(try isDirty("global"))

        try db.writer.write { try AppDatabase.clearDirty($0, "global") }
        let current = try #require(try stored("global")["statusMessage"])
        // The same entry back leaves it alone, while an older one from another writer marks it dirty.
        // An entry newer than ours is taken over without marking it dirty.
        #expect(try apply("global", [current]).markedDirty == false)
        #expect(try apply("global", [entry("statusMessage", "newest", 1, by: "q")]).markedDirty == true)
        try db.writer.write { try AppDatabase.clearDirty($0, "global") }
        let newer = SettingsEntry(key: "statusMessage", value: "newest", version: version(current.version.ms + 1), by: "q")
        #expect(try apply("global", [newer]).markedDirty == false)
        #expect(try !isDirty("global"))
    }

    @Test func anEntryTheServerLacksMarksTheItem() throws {
        try db.setSetting(.availability, "away")
        try db.writer.write { try AppDatabase.clearDirty($0, "global") }
        let result = try apply("global", [entry("statusMessage", "x", 100)])
        #expect(result.markedDirty)
        #expect(try isDirty("global"))
    }

    @Test func reportsWhichGlobalValuesChanged() throws {
        try db.setFlag(.sharesLastSeen, true)
        let future = ahead(1)
        let result = try apply("global", [
            entry("sharesLastSeen", nil, future), entry("availability", "away", future), entry("statusMessage", nil, future),
        ])
        #expect(result.changedGlobalKeys == [.sharesLastSeen, .availability])
    }

    // MARK: Local changes

    @Test func settersRecordEntriesAndMarkTheirItems() throws {
        try db.setLinkPreviewSetting(.never)
        try db.setFlag(.gifs, false)
        try db.setSetting(.availability, "dnd")
        let conversation = try db.conversation(with: alice)
        try db.setPinned(true, conversationId: conversation.id!)
        try db.setLinkPreviews(true, peer: alice)
        try db.setNotificationSound("chime", peer: alice)
        let global = try stored("global")
        #expect(global["linkPreviews"]?.value == "never")
        #expect(global["gifs"]?.value == "0")
        #expect(global["availability"]?.value == "dnd")
        let chat = try stored("chat:alice@example.org")
        #expect(chat["pinned"]?.value == "1")
        #expect(chat["linkPreviews"]?.value == "1")
        #expect(chat["notificationSound"]?.value == "chime")
        #expect(try isDirty("global") && isDirty("chat:alice@example.org"))
        try db.setPinned(false, conversationId: conversation.id!)
        try db.setLinkPreviews(nil, peer: alice)
        #expect(try stored("chat:alice@example.org")["pinned"]?.value == nil)
        #expect(try stored("chat:alice@example.org")["linkPreviews"]?.value == nil)
    }

    @Test func settingADefaultIsATombstoneNotAValue() throws {
        try db.setLinkPreviewSetting(.never)
        try db.setFlag(.sendsReadMarkers, false)
        try db.setLinkPreviewSetting(.askPerConversation)
        try db.setFlag(.sendsReadMarkers, true)
        let global = try stored("global")
        #expect(global["linkPreviews"]?.value == nil)
        #expect(global["sendsReadMarkers"]?.value == nil)
        #expect(global["linkPreviews"] != nil)
    }

    @Test func writingBackTheValueAnEntryHoldsIsNotAChange() throws {
        _ = try apply("global", [entry("statusMessage", "remote", 5)])
        try db.writer.write { try AppDatabase.clearDirty($0, "global") }
        try db.setSetting(.statusMessage, "remote")
        #expect(try !isDirty("global"))
        #expect(try stored("global")["statusMessage"]?.version == SettingsVersion(ms: 5, counter: 0))
        try db.setFlag(.gifs, true)
        #expect(try stored("global")["gifs"] == nil)
        #expect(try !isDirty("global"))
    }

    @Test func archivingAChatThatIsArchivedChangesNothing() throws {
        let conversation = try db.conversation(with: alice)
        try db.setArchived(true, conversationId: conversation.id!)
        let first = try stored("chat:alice@example.org")["archivedAt"]
        try db.setArchived(true, conversationId: conversation.id!)
        #expect(try stored("chat:alice@example.org")["archivedAt"] == first)
    }

    @Test func settingsThatAreNotSyncedLeaveNoEntry() throws {
        try db.setSetting(.nickname, "me")
        try db.setSetting(.rosterVersion, "3")
        #expect(try stored("global").isEmpty)
        #expect(try !isDirty("global"))
    }

    // MARK: Archived

    @Test func archivingKeepsTheTimeAndAnUnarchiveClearsIt() throws {
        let conversation = try db.conversation(with: alice)
        try db.setArchived(true, conversationId: conversation.id!)
        let archived = try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) })
        #expect(archived.isArchived && archived.archivedAt != nil)
        let entry = try #require(try stored("chat:alice@example.org")["archivedAt"])
        #expect(entry.value != nil)
        try db.setArchived(false, conversationId: conversation.id!)
        #expect(try stored("chat:alice@example.org")["archivedAt"]?.value == nil)
        let restored = try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) })
        #expect(!restored.isArchived && restored.archivedAt == nil)
    }

    @Test func aNewMessageUnarchivesWithoutTouchingTheItem() throws {
        let conversation = try db.conversation(with: alice)
        try db.setArchived(true, conversationId: conversation.id!)
        let before = try stored("chat:alice@example.org")["archivedAt"]
        try db.insert(message(conversation, at: Date().timeIntervalSince1970 + 100))
        let after = try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) })
        #expect(!after.isArchived)
        #expect(try stored("chat:alice@example.org")["archivedAt"] == before)
    }

    @Test func aRemoteArchiveOlderThanTheNewestMessageLeavesTheChatUnarchived() throws {
        let conversation = try db.conversation(with: alice)
        try db.insert(message(conversation, at: 5000))
        func archivedAfter(_ seconds: Int64) throws -> Bool {
            try apply("chat:alice@example.org", [entry("archivedAt", String(seconds * 1000), seconds)])
            return try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) }).isArchived
        }
        #expect(try archivedAfter(4000) == false)
        #expect(try archivedAfter(6000))
        // The tombstone unarchives.
        try apply("chat:alice@example.org", [entry("archivedAt", nil, 7000)])
        #expect(try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) }).isArchived == false)
    }

    @Test func chatEntriesReceivedBeforeTheChatExistsApplyWhenItIsCreated() throws {
        try apply("chat:alice@example.org", [entry("pinned", "1", 100), entry("notificationSound", "chime", 100)])
        #expect(try db.reader.read { try Conversation.fetchCount($0) } == 0)
        let conversation = try db.conversation(with: alice)
        #expect(conversation.isPinned)
        #expect(conversation.notificationSound == "chime")
        #expect(try !isDirty("chat:alice@example.org"))
    }

    // MARK: Full fetch

    @Test func aCleanItemTheServerLacksIsDeletedAndADirtyOneIsKept() throws {
        try apply("gif:1", [entry("gif", gifJSON("1"), 100)])
        try apply("chat:alice@example.org", [entry("pinned", "1", 100)])
        try db.setSetting(.statusMessage, "mine")
        try db.reconcileFetched([])
        #expect(try stored("gif:1").isEmpty)
        #expect(try stored("chat:alice@example.org").isEmpty)
        #expect(try stored("global")["statusMessage"]?.value == "mine")
        #expect(try db.pendingSyncItems().map(\.id) == ["global"])
    }

    @Test func aRetractedGifIsNotBroughtBackByADeviceThatWasOffline() throws {
        try apply("gif:1", [entry("gif", gifJSON("1"), 100)])
        try apply("gif:2", [entry("gif", gifJSON("2"), 100)])
        #expect(Set(db.gifFavorites().map(\.id)) == ["1", "2"])
        let kept = try #require(SettingsItem(entries: [entry("gif", gifJSON("2"), 100)]).element)
        try db.reconcileFetched([(id: "gif:2", payload: kept)])
        #expect(db.gifFavorites().map(\.id) == ["2"])
        #expect(try db.pendingSyncItems().isEmpty)
    }

    @Test func anItemOfAKindThisBuildDoesNotManageIsKept() throws {
        try apply("kind:1", [entry("x", "1", 100)])
        try db.reconcileFetched([])
        #expect(try stored("kind:1")["x"]?.value == "1")
    }

    @Test func aFetchAppliesItemsAndReportsChanges() throws {
        let global = SettingsItem(entries: [entry("availability", "away", 100)]).element
        let result = try db.reconcileFetched([(id: "global", payload: global)])
        #expect(result.changedGlobalKeys == [.availability])
        #expect(try db.setting(.availability) == "away")
    }

    @Test func expiredTombstonesAreListedOnceOldEnough() throws {
        let old = Int64(now.addingTimeInterval(-31 * 86400).timeIntervalSince1970 * 1000)
        let recent = Int64(now.addingTimeInterval(-5 * 86400).timeIntervalSince1970 * 1000)
        try apply("gif:old", [entry("gif", nil, old)])
        try apply("gif:recent", [entry("gif", nil, recent)])
        try apply("gif:live", [entry("gif", gifJSON("live"), old)])
        #expect(try db.expiredTombstones(at: now) == ["gif:old"])
        try db.forgetSyncedItem("gif:old")
        #expect(try db.expiredTombstones(at: now).isEmpty)
    }

    @Test func aDeletedChatIsResetOnEveryDeviceAndStaysResetWhenCreatedAgain() throws {
        let conversation = try db.conversation(with: alice)
        try db.setPinned(true, conversationId: conversation.id!)
        try db.setNotificationSound("chime", peer: alice)
        try db.writer.write { try AppDatabase.clearDirty($0, "chat:alice@example.org") }
        try db.deleteConversation(id: conversation.id!)
        let chat = try stored("chat:alice@example.org")
        #expect(chat["pinned"]?.value == nil && chat["pinned"] != nil)
        #expect(chat["notificationSound"]?.value == nil && chat["notificationSound"] != nil)
        #expect(try isDirty("chat:alice@example.org"))
        let again = try db.conversation(with: alice)
        #expect(!again.isPinned && again.notificationSound == nil)
    }

    @Test func aChatResetForLongEnoughIsListedToBeRetracted() throws {
        let old = Int64(now.addingTimeInterval(-31 * 86400).timeIntervalSince1970 * 1000)
        let recent = Int64(now.addingTimeInterval(-5 * 86400).timeIntervalSince1970 * 1000)
        try apply("chat:old@example.org", [entry("pinned", nil, old), entry("notificationSound", nil, old)])
        try apply("chat:recent@example.org", [entry("pinned", nil, recent)])
        try apply("chat:mixed@example.org", [entry("pinned", nil, old), entry("notificationSound", "chime", old)])
        #expect(try db.expiredTombstones(at: now) == ["chat:old@example.org"])
    }

    @Test func aDelayedMessageOlderThanTheArchivingDoesNotUnarchive() throws {
        let conversation = try db.conversation(with: alice)
        let base = Date().timeIntervalSince1970
        try db.insert(message(conversation, at: base - 1000))
        try db.setArchived(true, conversationId: conversation.id!)
        let before = try stored("chat:alice@example.org")["archivedAt"]
        try db.insert(message(conversation, at: base - 500))
        #expect(try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) }).isArchived)
        try db.insert(message(conversation, at: base + 100))
        #expect(!(try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) }).isArchived))
        #expect(try stored("chat:alice@example.org")["archivedAt"] == before)
    }

    @Test func aHistoryMessageNewerThanTheArchivingUnarchives() throws {
        let conversation = try db.conversation(with: alice)
        try db.setArchived(true, conversationId: conversation.id!)
        let later = message(conversation, at: Date().timeIntervalSince1970 + 100)
        _ = try db.writer.write { try AppDatabase.insert($0, later) }
        #expect(!(try #require(try db.reader.read { try Conversation.fetchOne($0, key: conversation.id!) }).isArchived))
    }

    // MARK: GIF favorites

    @Test func unstarringIsATombstoneAndTheLaterOfStarAndUnstarWins() throws {
        try db.addGifFavorite(gif("1"))
        try db.removeGifFavorite(id: "1")
        let tombstone = try #require(try stored("gif:1")["gif"])
        #expect(tombstone.value == nil)
        #expect(db.gifFavorites().isEmpty)
        // Starred again on another device after the unstar.
        try apply("gif:1", [entry("gif", gifJSON("1"), tombstone.version.ms + 10)])
        #expect(db.gifFavorites().map(\.id) == ["1"])
        // And an older star from there doesn't undo a later unstar.
        try db.removeGifFavorite(id: "1")
        try apply("gif:1", [entry("gif", gifJSON("1"), tombstone.version.ms + 10)])
        #expect(db.gifFavorites().isEmpty)
    }

    @Test func overTheCapTheOldestAreUnstarredSoTheyStayGone() throws {
        for index in 0..<(AppDatabase.gifFavoritesCapacity + 3) { try db.addGifFavorite(gif(String(index))) }
        #expect(db.gifFavorites().count == 200)
        #expect(try stored("gif:0")["gif"]?.value == nil)
        #expect(try stored("gif:2")["gif"]?.value == nil)
        #expect(try stored("gif:3")["gif"]?.value != nil)
    }

    @Test func starsFromBeforeSyncKeepTheirOrderAndLoseToTheServer() throws {
        let legacy = try JSONEncoder().encode([gif("c"), gif("b"), gif("a")])
        try db.setSetting(.gifFavorites, String(decoding: legacy, as: UTF8.self))
        #expect(db.gifFavorites().map(\.id) == ["c", "b", "a"])
        try db.seedSyncedSettingsIfNeeded(deviceId: "me")
        #expect(db.gifFavorites().map(\.id) == ["c", "b", "a"])
        #expect(try db.setting(.gifFavorites) == nil)
        #expect(try stored("gif:c")["gif"]?.version.ms == 0)
        #expect(try isDirty("gif:a"))
        // The server unstarred "b" long after.
        try apply("gif:b", [entry("gif", nil, 1000)])
        #expect(db.gifFavorites().map(\.id) == ["c", "a"])
    }

    // MARK: Seeding

    @Test func seedingRecordsOnlyNonDefaultValuesAtVersionZero() throws {
        try db.writer.write { dbc in
            try AppDatabase.setSetting(dbc, .linkPreviews, "never")
            try AppDatabase.setSetting(dbc, .sendsReadMarkers, "1")
            try AppDatabase.setSetting(dbc, .sharesLastSeen, "1")
            try AppDatabase.setSetting(dbc, .nickname, "me")
        }
        var pinned = try db.conversation(with: alice)
        pinned.isPinned = true
        try db.writer.write { try pinned.update($0) }
        _ = try db.conversation(with: YapnestKit.JID("bob@example.org")!)

        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        let global = try stored("global")
        #expect(Set(global.keys) == ["linkPreviews", "sharesLastSeen"])
        #expect(global["linkPreviews"] == SettingsEntry(key: "linkPreviews", value: "never", version: .zero, by: "dev1"))
        #expect(try stored("chat:alice@example.org").keys.sorted() == ["pinned"])
        #expect(try stored("chat:bob@example.org").isEmpty)
        #expect(try isDirty("global") && isDirty("chat:alice@example.org") && !isDirty("chat:bob@example.org"))
        #expect(try db.setting(.syncDeviceId) == "dev1")
    }

    @Test func seedingRunsOnce() throws {
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        try db.writer.write { try AppDatabase.setSetting($0, .linkPreviews, "never") }
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        #expect(try stored("global").isEmpty)
    }

    @Test func aSeededValueLosesToTheServer() throws {
        try db.writer.write { try AppDatabase.setSetting($0, .statusMessage, "old local") }
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        try db.reconcileFetched([(id: "global", payload: SettingsItem(entries: [entry("statusMessage", "server", 5)]).element)])
        #expect(try db.setting(.statusMessage) == "server")
        #expect(try !isDirty("global"))
    }

    @Test func aSeededValueIsPublishedWhenTheServerHasNothing() throws {
        try db.writer.write { try AppDatabase.setSetting($0, .statusMessage, "old local") }
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        try db.reconcileFetched([])
        let pending = try #require(try db.pendingSyncItems().first)
        #expect(pending.id == "global")
        #expect(try SettingsItem(element: pending.element)?.entries.first?.value == "old local")
        try db.markPublished(pending)
        #expect(try db.pendingSyncItems().isEmpty)
    }

    @Test func changesBeforeTheDeviceIsKnownAreStampedWhenItIs() throws {
        try db.setSetting(.statusMessage, "early")
        #expect(try stored("global")["statusMessage"]?.by == "")
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        #expect(try stored("global")["statusMessage"]?.by == "dev1")
    }

    @Test func aPublishThatRacedAChangeLeavesTheItemMarked() throws {
        try db.setSetting(.statusMessage, "one")
        let published = try #require(try db.pendingSyncItems().first)
        try db.setSetting(.statusMessage, "two")
        try db.markPublished(published)
        #expect(try isDirty("global"))
        try db.markPublished(try #require(try db.pendingSyncItems().first))
        #expect(try !isDirty("global"))
    }

    // MARK: Usage

    private func ranking(_ picks: [(String, Date)]) -> ReactionRanking {
        var ranking = ReactionRanking()
        for (emoji, at) in picks { ranking.record(emoji, at: at) }
        return ranking
    }

    @Test func theSummedRankingEqualsEveryPickReplayedOnOneDevice() {
        let day = 86400.0
        let picks: [(String, Date)] = [
            ("🔥", now), ("👍", now.addingTimeInterval(1 * day)), ("🔥", now.addingTimeInterval(3 * day)), ("🪺", now.addingTimeInterval(4 * day)),
            ("🔥", now.addingTimeInterval(9 * day)), ("👍", now.addingTimeInterval(10 * day)), ("🪺", now.addingTimeInterval(12 * day)),
        ]
        let phone = ranking(picks.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        let tablet = ranking(picks.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        let all = ranking(picks)
        for readAt in [20.0, 30, 60].map({ now.addingTimeInterval($0 * day) }) {
            let summed = ReactionRanking.summed([phone, tablet], at: readAt)
            for emoji in ["🔥", "👍", "🪺", "😀"] {
                #expect(abs(summed.score(of: emoji, at: readAt) - all.score(of: emoji, at: readAt)) < 1e-9)
            }
            #expect(summed.row(at: readAt) == all.row(at: readAt))
        }
    }

    @Test func theCombinedRankingAddsOtherDevicesToOurOwn() throws {
        try db.recordEmojiPick("🔥", at: now)
        let other = ranking([("🔥", now), ("🪺", now)])
        try db.reconcileFetched([(id: "usage:other", payload: other.usageElement)], at: now)
        let combined = db.emojiRanking(at: now)
        #expect(abs(combined.score(of: "🔥", at: now) - 2) < 1e-3)
        #expect(abs(combined.score(of: "🪺", at: now) - 1) < 1e-3)
        #expect(abs(db.reactionRanking().score(of: "🔥", at: now) - 1) < 1e-3)
    }

    @Test func aPickMarksOurUsageItemOnceTheDeviceIsKnown() throws {
        try db.recordEmojiPick("🔥", at: now)
        #expect(try db.pendingSyncItems().isEmpty)
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        #expect(try isDirty("usage:dev1"))
        let pending = try #require(try db.pendingSyncItems().first)
        #expect(pending.id == "usage:dev1")
        try db.markPublished(pending)
        try db.recordEmojiPick("🔥", at: now)
        #expect(try isDirty("usage:dev1"))
    }

    @Test func ourOwnItemIsMergedIntoAnEmptiedRankingNotOverwritten() throws {
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        let server = ranking([("🔥", now), ("🔥", now), ("🪺", now)])
        let result = try db.reconcileFetched([(id: "usage:dev1", payload: server.usageElement)], at: now)
        let own = db.reactionRanking()
        #expect(abs(own.score(of: "🔥", at: now) - 2) < 1e-3)
        #expect(abs(own.score(of: "🪺", at: now) - 1) < 1e-3)
        // Nothing here exceeds the server's copy, so nothing needs publishing.
        #expect(result.markedDirty == false)
        #expect(try !isDirty("usage:dev1"))
    }

    @Test func aLocalRankingAheadOfTheServersIsKeptAndPublished() throws {
        try db.seedSyncedSettingsIfNeeded(deviceId: "dev1")
        try db.recordEmojiPick("🔥", at: now)
        try db.recordEmojiPick("🔥", at: now)
        try db.markPublished(try #require(try db.pendingSyncItems().first))
        let server = ranking([("🔥", now), ("🪺", now)])
        let result = try db.reconcileFetched([(id: "usage:dev1", payload: server.usageElement)], at: now)
        #expect(result.markedDirty)
        let own = db.reactionRanking()
        #expect(abs(own.score(of: "🔥", at: now) - 2) < 1e-3)
        #expect(abs(own.score(of: "🪺", at: now) - 1) < 1e-3)
    }

    @Test func anotherDevicesItemMissingFromTheServerIsDropped() throws {
        let other = ranking([("🔥", now)])
        try db.reconcileFetched([(id: "usage:other", payload: other.usageElement)], at: now)
        #expect(db.emojiRanking(at: now).score(of: "🔥", at: now) > 0.9)
        try db.reconcileFetched([], at: now)
        #expect(db.emojiRanking(at: now).score(of: "🔥", at: now) == 0)
    }

    @Test func aDeviceWhoseEveryEmojiHasDecayedIsReportedForRetraction() throws {
        let stale = ranking([("🔥", now)])
        let fresh = ranking([("🔥", now.addingTimeInterval(200 * 86400))])
        let later = now.addingTimeInterval(200 * 86400)
        try db.reconcileFetched([(id: "usage:stale", payload: stale.usageElement), (id: "usage:fresh", payload: fresh.usageElement)], at: later)
        #expect(try db.forgottenUsageDevices(at: later) == ["stale"])
        try db.removeRemoteUsage(deviceId: "stale")
        #expect(try db.forgottenUsageDevices(at: later).isEmpty)
    }

    private func gifJSON(_ id: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(gif(id)), as: UTF8.self)
    }
}
