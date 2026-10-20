import Foundation
import GRDB

extension AppDatabase {
    /// Small per-account values such as sync cursors.
    public enum SettingKey: String, Sendable {
        /// Id of the newest MAM result we've processed.
        case lastArchiveId
        /// `pending` from a sync that began without a cursor until the chats
        /// older than its window are restored: see `XMPPSession.restoreChats`.
        case historyRestore
        /// This device's OMEMO device id.
        case omemoRegistrationId
        /// This device's OMEMO identity key pair, base64.
        case omemoIdentityKeyPair
        /// This device's APNs token, hex, and whether it's a development
        /// build's ("sandbox") or not ("production").
        case pushToken
        case pushEnvironment
        /// The push relay and node our server publishes to, once enabled.
        case pushRelay
        case pushNode
        /// Nodes replaced by a newer one whose disable the server hasn't
        /// answered yet, as JSON: see `StalePushNode`.
        case pushStaleNodes
        /// The newest message a notification was shown for, or that was seen
        /// in the app, so the app and the notification extension don't
        /// notify about the same message twice.
        case lastNotifiedMessageId
        /// When notifications were last claimed, seconds since 1970.
        case lastNotifiedAt
        /// The roster version we hold (RFC 6121 §2.6), so a new session
        /// only gets what changed.
        case rosterVersion
        /// Whether people see when we've read their messages (XEP-0333)
        /// and when we're typing (XEP-0085). Both on unless turned off.
        case sendsReadMarkers
        case sendsChatStates
        /// Whether link previews are ever loaded: see `LinkPreviewSetting`.
        case linkPreviews
        /// Whether the GIF picker is offered. On unless turned off, because
        /// its searches go to KLIPY.
        case gifs
        /// The GIFs starred before they were synced, as JSON. Taken into
        /// `syncedEntry` and removed by the first write: see `addGifFavorite`.
        case gifFavorites
        /// The name we publish for ourselves (XEP-0172).
        case nickname
        /// What we tell contacts we're doing (RFC 6121): `away` or `dnd`,
        /// unset when available, and free text.
        case availability
        case statusMessage
        /// How much each emoji has been picked as a reaction, decayed: see
        /// `ReactionRanking`. This device's own picks; the other devices' are
        /// in `remoteUsage`, and published as our `usage:` item.
        case reactionRanking
        /// Whether we tell contacts when we were last active (XEP-0012) and
        /// show them theirs. Off unless turned on.
        case sharesLastSeen
        /// The highest settings version issued or seen, so the clock never
        /// goes back, even after a relaunch: see `SettingsVersion`.
        case settingsClock
        /// This device's id in synced entries and in its `usage:` item.
        case syncDeviceId
        /// Set once the values from before settings were synced are recorded.
        case settingsSeeded
        /// Set once the composer's old per-device shortcode recents are taken
        /// into `reactionRanking`: see `importEmojiRecents`.
        case emojiRecentsImported
    }

    public func setting(_ key: SettingKey) throws -> String? {
        try reader.read { try Self.setting($0, key) }
    }

    /// A key that is synced between devices also records the change, in the
    /// same transaction, to be published.
    public func setSetting(_ key: SettingKey, _ value: String?) throws {
        try writer.write { db in
            try Self.setSetting(db, key, value)
            if Self.syncedGlobalKeys[key] != nil { try Self.touch(db, item: Self.globalItem, key: key.rawValue) }
        }
    }

    /// For use inside a transaction or an observation.
    public static func setting(_ db: Database, _ key: SettingKey) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.rawValue])
    }

    /// Setting nil removes the key.
    public static func setSetting(_ db: Database, _ key: SettingKey, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key.rawValue, value])
        } else {
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key.rawValue])
        }
    }

    /// A setting that's on or off, `defaultValue` until set.
    public func flag(_ key: SettingKey, default defaultValue: Bool) -> Bool {
        guard let value = try? setting(key) else { return defaultValue }
        return value == "1"
    }

    public func setFlag(_ key: SettingKey, _ on: Bool) throws {
        try setSetting(key, on ? "1" : "0")
    }
}
