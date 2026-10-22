import Foundation
import GRDB
@preconcurrency import Martin

/// Yapnest's own settings, kept in step with our other devices through a PEP
/// node (see `SettingsItem`).
///
/// `syncedEntry` holds every entry of every item as last written or received:
/// the version and device that decide a conflict, and the value, nil for a
/// reset. The real columns and settings stay what the app reads; a change to
/// one goes through `touch`, in its own transaction, which records it as an
/// entry and marks its item to be published. A value arriving from another
/// device is written to the real column without marking anything.
extension AppDatabase {
    static let globalItem = "global"

    static func chatItem(_ peer: JID) -> String { SettingsItemID.chat(peer).raw }
    static func gifItem(_ id: String) -> String { SettingsItemID.gif(id).raw }
    static func usageItem(_ deviceId: String) -> String { SettingsItemID.usage(device: deviceId).raw }
    static let gifKey = "gif"

    /// How long a tombstone is kept before any device may retract it: a removed
    /// GIF's, or a chat item whose settings are all reset.
    static let gifTombstoneLifetime: TimeInterval = 30 * 24 * 3600

    /// Whether this build manages the item. Other kinds, such as one a newer
    /// build adds, are kept as they are and never deleted here.
    static func managesItem(_ item: String) -> Bool {
        switch SettingsItemID(item) {
        case .global, .chat, .gif: true
        case .usage, .unknown: false
        }
    }

    // MARK: Registry

    /// How one synced key reads its real value (nil at its default, so a
    /// reset is a tombstone and defaults are never published) and takes a
    /// remote one.
    struct SyncedKey: Sendable {
        var read: @Sendable (Database, JID?) throws -> String?
        var apply: @Sendable (Database, JID?, String?) throws -> Void
        /// For a chat's key, the same read from a conversation already fetched.
        var ofConversation: (@Sendable (Conversation) -> String?)?
    }

    private static func globalKey(_ key: SettingKey, default defaultValue: String? = nil) -> SyncedKey {
        SyncedKey(
            read: { db, _ in
                let raw = try setting(db, key)
                return raw == defaultValue ? nil : raw
            },
            apply: { db, _, value in try setSetting(db, key, value) },
            ofConversation: nil,
        )
    }

    private static func chatKey(
        read: @escaping @Sendable (Conversation) -> String?, apply: @escaping @Sendable (Database, Conversation, String?) throws -> Void,
    ) -> SyncedKey {
        SyncedKey(
            read: { db, peer in
                try peer.flatMap { try Conversation.filter(Column("peer") == $0).fetchOne(db) }.flatMap(read)
            },
            apply: { db, peer, value in
                guard let peer, let conversation = try Conversation.filter(Column("peer") == peer).fetchOne(db) else { return }
                try apply(db, conversation, value)
            },
            ofConversation: read,
        )
    }

    static let syncedGlobalKeys: [SettingKey: SyncedKey] = [
        .linkPreviews: globalKey(.linkPreviews, default: LinkPreviewSetting.askPerConversation.rawValue),
        .gifs: globalKey(.gifs, default: "1"),
        .sendsReadMarkers: globalKey(.sendsReadMarkers, default: "1"),
        .sendsChatStates: globalKey(.sendsChatStates, default: "1"),
        .encryptsNewChats: globalKey(.encryptsNewChats, default: "1"),
        .sharesLastSeen: globalKey(.sharesLastSeen, default: "0"),
        .availability: globalKey(.availability),
        .statusMessage: globalKey(.statusMessage),
    ]

    private static func setColumn(_ db: Database, _ conversation: Conversation, _ assignments: ColumnAssignment...) throws {
        guard let id = conversation.id else { return }
        _ = try Conversation.filter(key: id).updateAll(db, assignments)
    }

    static let syncedChatKeys: [String: SyncedKey] = [
        "linkPreviews": chatKey(
            read: { $0.linkPreviews.map { $0 ? "1" : "0" } },
            apply: { db, c, value in try setColumn(db, c, Column("linkPreviews").set(to: value.map { $0 == "1" })) },
        ),
        "notificationSound": chatKey(
            read: { $0.notificationSound },
            apply: { db, c, value in try setColumn(db, c, Column("notificationSound").set(to: value)) },
        ),
        "pinned": chatKey(
            read: { $0.isPinned ? "1" : nil },
            apply: { db, c, value in try setColumn(db, c, Column("isPinned").set(to: value == "1")) },
        ),
        "archivedAt": chatKey(
            read: { $0.archivedAt.map { String($0.settingsMilliseconds) } },
            apply: { db, c, value in
                let at = value.flatMap(Int64.init).map(Date.init(settingsMilliseconds:))
                // Archived only while nothing newer than the archiving is in
                // the chat, as a new message brings it back on every device.
                var archived = at != nil
                if let at, let id = c.id {
                    archived = try Message.filter(Column("conversationId") == id && Column("timestamp") > at).fetchCount(db) == 0
                }
                try setColumn(db, c, Column("archivedAt").set(to: at), Column("isArchived").set(to: archived))
            },
        ),
    ]

    private static func registryKey(_ id: SettingsItemID, key: String) -> (key: SyncedKey, peer: JID?)? {
        switch id {
        case .global: SettingKey(rawValue: key).flatMap { syncedGlobalKeys[$0] }.map { ($0, nil) }
        case .chat(let peer): syncedChatKeys[key].map { ($0, peer) }
        case .gif, .usage, .unknown: nil
        }
    }

    // MARK: Clock and device

    /// The id of this device in an entry's `by` and in its usage item. Empty
    /// until `seedSyncedSettingsIfNeeded` runs, which stamps what was written
    /// before it.
    static func syncDeviceId(_ db: Database) throws -> String? {
        try setting(db, .syncDeviceId)
    }

    static func settingsClock(_ db: Database) throws -> SettingsVersion {
        try setting(db, .settingsClock).flatMap(SettingsVersion.init) ?? .zero
    }

    /// Raises the stored clock to `version`, whether it won or lost: a device
    /// that rejected a version must still order its next change after it.
    static func noteSeen(_ db: Database, _ version: SettingsVersion) throws {
        if version > (try settingsClock(db)) { try setSetting(db, .settingsClock, version.description) }
    }

    static func issueVersion(_ db: Database, at now: Date) throws -> SettingsVersion {
        let version = try settingsClock(db).next(at: now)
        try setSetting(db, .settingsClock, version.description)
        return version
    }

    // MARK: Local changes

    /// Sets a synced setting of a chat that exists, as the same column write a
    /// remote change makes, and records it as a local change.
    static func setChatSetting(_ db: Database, _ peer: JID, _ key: String, _ value: String?) throws {
        try syncedChatKeys[key]?.apply(db, peer, value)
        try touch(db, item: chatItem(peer), key: key)
    }

    /// Records that `key` of `item` was just changed locally, from its real
    /// value. Writing back the value the entry already holds is no change: a
    /// new version for it would beat a newer one from another device that
    /// this device has not heard of yet.
    static func touch(_ db: Database, item: String, key: String, at now: Date = Date()) throws {
        guard let (synced, peer) = registryKey(SettingsItemID(item), key: key) else { return }
        let value = try synced.read(db, peer)
        let held = try syncedEntries(db, item: item).first { $0.key == key }
        if held?.value == value { return }
        try touch(db, item: item, key: key, value: value, at: now)
    }

    /// The same with the value given, for items that are their own storage.
    static func touch(_ db: Database, item: String, key: String, value: String?, at now: Date = Date()) throws {
        let version = try issueVersion(db, at: now)
        let by = try syncDeviceId(db) ?? ""
        try upsert(db, item: item, SettingsEntry(key: key, value: value, version: version, by: by))
        try markDirty(db, item)
    }

    static func upsert(_ db: Database, item: String, _ entry: SettingsEntry) throws {
        try db.execute(
            sql: """
                INSERT INTO syncedEntry (item, key, value, version, "by") VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(item, key) DO UPDATE SET value = excluded.value, version = excluded.version, "by" = excluded."by"
                """,
            arguments: [item, entry.key, entry.value, entry.version.description, entry.by],
        )
    }

    /// Records an entry only if the item has none for its key, as for what was
    /// set before sync: any real entry is to beat it.
    static func insertIfAbsent(_ db: Database, item: String, _ entry: SettingsEntry) throws {
        try db.execute(
            sql: #"INSERT OR IGNORE INTO syncedEntry (item, key, value, version, "by") VALUES (?, ?, ?, ?, ?)"#,
            arguments: [item, entry.key, entry.value, entry.version.description, entry.by],
        )
        try markDirty(db, item)
    }

    static func markDirty(_ db: Database, _ item: String) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO syncedItemDirty (item) VALUES (?)", arguments: [item])
    }

    static func clearDirty(_ db: Database, _ item: String) throws {
        try db.execute(sql: "DELETE FROM syncedItemDirty WHERE item = ?", arguments: [item])
    }

    static func removeRemoteUsage(_ db: Database, deviceId: String) throws {
        try db.execute(sql: "DELETE FROM remoteUsage WHERE deviceId = ?", arguments: [deviceId])
    }

    static func markOwnUsageDirty(_ db: Database) throws {
        guard let id = try syncDeviceId(db), !id.isEmpty else { return }
        try markDirty(db, usageItem(id))
    }

    static func syncedEntries(_ db: Database, item: String) throws -> [SettingsEntry] {
        try Row.fetchAll(db, sql: #"SELECT key, value, version, "by" FROM syncedEntry WHERE item = ?"#, arguments: [item])
            .compactMap(entry(from:))
    }

    private static func entry(from row: Row) -> SettingsEntry? {
        guard let version = SettingsVersion(row["version"] as String) else { return nil }
        return SettingsEntry(key: row["key"], value: row["value"], version: version, by: row["by"])
    }

    /// Removes an item from this device, as when it is gone from the server.
    static func forgetSyncedItem(_ db: Database, _ item: String) throws {
        try db.execute(sql: "DELETE FROM syncedEntry WHERE item = ?", arguments: [item])
        try clearDirty(db, item)
    }

    /// A conversation created after its entries arrived takes them now.
    /// Whether it changed anything.
    @discardableResult
    static func applyStoredChatEntries(_ db: Database, peer: JID) throws -> Bool {
        var applied = false
        for entry in try syncedEntries(db, item: chatItem(peer)) {
            guard let known = registryKey(.chat(peer), key: entry.key) else { continue }
            try known.key.apply(db, peer, entry.value)
            applied = true
        }
        return applied
    }

    // MARK: Remote changes

    struct SyncedApplyResult: Equatable {
        /// Global keys whose real value changed, for the session to act on
        /// (`sharesLastSeen`, `availability`, `statusMessage`).
        var changedGlobalKeys: Set<SettingKey> = []
        /// Whether local holds something newer than, or missing from, the
        /// item received, so it is to be published again.
        var markedDirty = false

        mutating func formUnion(_ other: SyncedApplyResult) {
            changedGlobalKeys.formUnion(other.changedGlobalKeys)
            markedDirty = markedDirty || other.markedDirty
        }
    }

    /// Merges an item received from the server, entry by entry: the higher
    /// version wins, and the same answer comes out in any order. Winners go
    /// to the real values without marking the item. It is marked only when
    /// local keeps an entry newer than the server's or one it lacks, which
    /// is how an update lost to a concurrent publish is published again.
    static func applyRemote(_ db: Database, item: String, entries: [SettingsEntry]) throws -> SyncedApplyResult {
        var result = SyncedApplyResult()
        var local = Dictionary(try syncedEntries(db, item: item).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let id = SettingsItemID(item)
        if let newest = entries.map(\.version).max() { try noteSeen(db, newest) }
        var seen = Set<String>()
        for remote in entries {
            seen.insert(remote.key)
            if let mine = local[remote.key], !remote.supersedes(mine) {
                if mine.supersedes(remote) { result.markedDirty = true }
                continue
            }
            let known = registryKey(id, key: remote.key)
            let before = id == .global ? try known.flatMap { try $0.key.read(db, $0.peer) } : nil
            try upsert(db, item: item, remote)
            local[remote.key] = remote
            guard let known else { continue }
            try known.key.apply(db, known.peer, remote.value)
            if id == .global, let key = SettingKey(rawValue: remote.key), try known.key.read(db, known.peer) != before {
                result.changedGlobalKeys.insert(key)
            }
        }
        if local.keys.contains(where: { !seen.contains($0) }) { result.markedDirty = true }
        // What the server now holds covers everything here, so nothing is left to publish.
        if result.markedDirty { try markDirty(db, item) } else { try clearDirty(db, item) }
        return result
    }

    /// Applies one item received live. Our own device's usage item is merged
    /// into our ranking, and another's replaces what we hold of it.
    @discardableResult
    func applyRemoteItem(id: String, payload: Element?) throws -> SyncedApplyResult {
        try writer.write { db in try Self.applyRemoteItem(db, id: id, payload: payload) }
    }

    private static func applyRemoteItem(_ db: Database, id: String, payload: Element?, at now: Date = Date()) throws -> SyncedApplyResult {
        if case .usage(let device) = SettingsItemID(id) {
            guard let ranking = ReactionRanking(usage: payload), !device.isEmpty else { return SyncedApplyResult() }
            if device == (try syncDeviceId(db)) {
                var own = try ownRanking(db)
                own.merge(ranking, at: now)
                try storeOwnRanking(db, own)
                if own.exceeds(ranking, at: now) {
                    try markDirty(db, id)
                    return SyncedApplyResult(markedDirty: true)
                }
            } else {
                try db.execute(
                    sql: "INSERT INTO remoteUsage (deviceId, json) VALUES (?, ?) ON CONFLICT(deviceId) DO UPDATE SET json = excluded.json",
                    arguments: [device, try encodeRanking(ranking)],
                )
            }
            return SyncedApplyResult()
        }
        guard let item = SettingsItem(element: payload) else { return SyncedApplyResult() }
        return try applyRemote(db, item: id, entries: item.entries)
    }

    /// Applies every item received, in one transaction, without deciding that
    /// anything missing is gone: for a fetch that may be partial.
    @discardableResult
    func applyFetched(_ items: [(id: String, payload: Element?)], at now: Date = Date()) throws -> SyncedApplyResult {
        try writer.write { db in try Self.applyFetched(db, items, at: now) }
    }

    private static func applyFetched(_ db: Database, _ items: [(id: String, payload: Element?)], at now: Date) throws -> SyncedApplyResult {
        var result = SyncedApplyResult()
        for item in items { result.formUnion(try applyRemoteItem(db, id: item.id, payload: item.payload, at: now)) }
        return result
    }

    /// Takes every item the server holds. An item the server lacks was
    /// removed there, so it goes from here too unless it is waiting to be
    /// published; those are what a device offline since before a removal must
    /// not bring back, and what it set while offline. Our own usage is kept.
    /// `keeping` names items that arrived live while the fetch was under way:
    /// its pages may predate them, so their absence says nothing.
    @discardableResult
    func reconcileFetched(
        _ items: [(id: String, payload: Element?)], keeping live: Set<String> = [], at now: Date = Date(),
    ) throws -> SyncedApplyResult {
        try writer.write { db in
            let result = try Self.applyFetched(db, items, at: now)
            let present = Set(items.map(\.id)).union(live)
            let dirty = Set(try String.fetchAll(db, sql: "SELECT item FROM syncedItemDirty"))
            for item in try String.fetchAll(db, sql: "SELECT DISTINCT item FROM syncedEntry") where Self.managesItem(item) && !present.contains(item) && !dirty.contains(item) {
                try Self.forgetSyncedItem(db, item)
            }
            for device in try String.fetchAll(db, sql: "SELECT deviceId FROM remoteUsage") where !present.contains(Self.usageItem(device)) {
                try Self.removeRemoteUsage(db, deviceId: device)
            }
            return result
        }
    }

    /// Another device's usage item was retracted.
    func removeRemoteUsage(deviceId: String) throws {
        try writer.write { db in try Self.removeRemoteUsage(db, deviceId: deviceId) }
    }

    // MARK: Publishing

    struct PendingSyncItem: Equatable {
        var id: String
        var element: Element
        /// What the item holds, in an order that doesn't depend on how the
        /// element happened to be built, to tell whether it changed.
        var content: String

        static func == (a: PendingSyncItem, b: PendingSyncItem) -> Bool {
            a.id == b.id && a.content == b.content
        }
    }

    /// The items to publish, built from everything held of each.
    func pendingSyncItems() throws -> [PendingSyncItem] {
        try reader.read { db in try Self.pendingSyncItems(db) }
    }

    private static func pendingSyncItems(_ db: Database) throws -> [PendingSyncItem] {
        let own = try syncDeviceId(db)
        return try String.fetchAll(db, sql: "SELECT item FROM syncedItemDirty ORDER BY item").compactMap { try pendingSyncItem(db, id: $0, ownDevice: own) }
    }

    private static func pendingSyncItem(_ db: Database, id: String, ownDevice: String?) throws -> PendingSyncItem? {
        if case .usage(let device) = SettingsItemID(id) {
            guard device == ownDevice else { return nil }
            let ranking = try ownRanking(db)
            return PendingSyncItem(id: id, element: ranking.usageElement, content: try encodeRanking(ranking))
        }
        let entries = try syncedEntries(db, item: id)
        let item = SettingsItem(entries: entries)
        return entries.isEmpty ? nil : PendingSyncItem(id: id, element: item.element, content: item.content)
    }

    /// Clears an item's mark once it is published, unless it changed while
    /// the publish was out: then it stays marked, to go again.
    func markPublished(_ published: PendingSyncItem) throws {
        try writer.write { db in
            let current = try Self.pendingSyncItem(db, id: published.id, ownDevice: try Self.syncDeviceId(db))
            if current == nil || current == published { try Self.clearDirty(db, published.id) }
        }
    }

    /// Items that have only been removed or reset for longer than any device
    /// should still be told of, for the session to retract: a GIF unstarred,
    /// and a chat whose every setting is back at its default.
    /// `forgetSyncedItem` follows the retract.
    func expiredTombstones(at now: Date = Date()) throws -> [String] {
        try reader.read { db in
            let isOld = { (row: Row) -> Bool in
                guard let version = SettingsVersion(row["version"] as String) else { return false }
                return now.timeIntervalSince(version.date) > Self.gifTombstoneLifetime
            }
            let gifs = try Row.fetchAll(db, sql: #"SELECT item, version FROM syncedEntry WHERE item LIKE 'gif:%' AND key = ? AND value IS NULL"#, arguments: [Self.gifKey])
                .filter(isOld).map { $0["item"] as String }
            var chats: [String: Bool] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT item, value, version FROM syncedEntry WHERE item LIKE 'chat:%'") {
                let item: String = row["item"]
                let expired = (row["value"] as String?) == nil && isOld(row)
                chats[item] = (chats[item] ?? true) && expired
            }
            return gifs + chats.filter(\.value).keys.sorted()
        }
    }

    func forgetSyncedItem(_ item: String) throws {
        try writer.write { db in try Self.forgetSyncedItem(db, item) }
    }

    /// A conversation deleted here is reset on every device: its settings are
    /// recorded as back at their defaults, to be published, rather than left
    /// to come back with a chat created again.
    static func resetChatSettings(_ db: Database, peer: JID) throws {
        for entry in try syncedEntries(db, item: chatItem(peer)) where entry.value != nil {
            try touch(db, item: chatItem(peer), key: entry.key, value: nil)
        }
    }

    // MARK: Seeding

    /// Records what was set before this feature existed, once, so the first
    /// sync publishes it: each non-default value as an entry at version 0,
    /// which any real version from the server beats. Also keeps the device
    /// id, and stamps entries written before it was known with it.
    func seedSyncedSettingsIfNeeded(deviceId: String) throws {
        try writer.write { db in
            try Self.setSetting(db, .syncDeviceId, deviceId)
            try db.execute(sql: #"UPDATE syncedEntry SET "by" = ? WHERE "by" = ''"#, arguments: [deviceId])
            guard try Self.setting(db, .settingsSeeded) == nil else { return }
            try Self.adoptLegacyGifFavorites(db, by: deviceId)
            func seed(_ item: String, _ key: String, _ value: String) throws {
                try Self.insertIfAbsent(db, item: item, SettingsEntry(key: key, value: value, version: .zero, by: deviceId))
            }
            for (key, synced) in Self.syncedGlobalKeys {
                if let value = try synced.read(db, nil) { try seed(Self.globalItem, key.rawValue, value) }
            }
            for conversation in try Conversation.fetchAll(db) {
                for (key, synced) in Self.syncedChatKeys {
                    if let value = synced.ofConversation?(conversation) { try seed(Self.chatItem(conversation.peer), key, value) }
                }
            }
            if !(try Self.ownRanking(db).entries.isEmpty) { try Self.markDirty(db, Self.usageItem(deviceId)) }
            try Self.setSetting(db, .settingsSeeded, "1")
        }
    }
}
