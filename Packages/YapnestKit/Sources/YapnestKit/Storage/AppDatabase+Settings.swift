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
        /// The GIFs the user starred in the picker, newest first, as JSON:
        /// see `addGifFavorite`. Per device, never synced.
        case gifFavorites
        /// The name we publish for ourselves (XEP-0172).
        case nickname
        /// What we tell contacts we're doing (RFC 6121): `away` or `dnd`,
        /// unset when available, and free text.
        case availability
        case statusMessage
        /// How much each emoji has been picked as a reaction, decayed: see
        /// `ReactionRanking`. Per device, never synced.
        case reactionRanking
        /// Whether we tell contacts when we were last active (XEP-0012) and
        /// show them theirs. Off unless turned on.
        case sharesLastSeen
    }

    public func setting(_ key: SettingKey) throws -> String? {
        try reader.read { try Self.setting($0, key) }
    }

    public func setSetting(_ key: SettingKey, _ value: String?) throws {
        try writer.write { try Self.setSetting($0, key, value) }
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

    /// Changes a JSON setting in one transaction so two writers can't lose
    /// each other's changes. An unreadable or missing value starts from
    /// `defaultValue`.
    ///
    /// An unreadable value is replaced by the default on the next change, so
    /// what was stored is lost. A type kept this way (`Gif`, `Rendition`,
    /// `ReactionRanking`) must therefore keep decoding the JSON it wrote
    /// before it changed, with any new field optional.
    @discardableResult
    func updateJSONSetting<T: Codable, R>(
        _ key: SettingKey,
        default defaultValue: T,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        _ change: (inout T) -> R,
    ) throws -> R {
        try writer.write { db in
            var value = try Self.setting(db, key)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(T.self, from: $0) } ?? defaultValue
            let result = change(&value)
            try Self.setSetting(db, key, String(decoding: try encoder.encode(value), as: UTF8.self))
            return result
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
