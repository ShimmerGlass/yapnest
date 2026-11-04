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
        /// The contacts that restore has finished with, as a JSON list of
        /// addresses, kept while it's pending so a later connect skips them.
        case historyRestored
        /// This device's OMEMO device id.
        case omemoRegistrationId
        /// This device's OMEMO identity key pair, base64.
        case omemoIdentityKeyPair
        /// OMEMO device ids this install made and gave up, comma separated:
        /// see `OMEMOStore.findOrMakeIdentity`. Taken off the account's device
        /// list once connected.
        case omemoReplacedDeviceIds
        /// The highest one-time prekey id ever made, which never goes down.
        case omemoLastPreKeyId
        /// The members of private groups this install's OMEMO device has
        /// introduced itself to, as JSON: see `introducedMembers`.
        case introducedGroups
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
        /// When the avatars of chats without presence were last asked for,
        /// seconds since 1970.
        case lastAvatarRefresh
        /// The roster version we hold (RFC 6121 §2.6), so a new session
        /// only gets what changed.
        case rosterVersion
        /// Whether people see when we've read their messages (XEP-0333)
        /// and when we're typing (XEP-0085). Both on unless turned off.
        case sendsReadMarkers
        case sendsChatStates
        /// Whether a one-to-one chat started from now on encrypts with OMEMO.
        /// On unless turned off; chats that exist keep their own choice.
        case encryptsNewChats
        /// Whether link previews are ever loaded: see `LinkPreviewSetting`.
        case linkPreviews
        /// Whether the GIF picker is offered. On unless turned off, because
        /// its searches go to KLIPY.
        case gifs
        /// Set once the user has agreed to KLIPY, in the United States,
        /// seeing their searches, region and IP address: see
        /// `ConsentedGifService`. Not synced, and kept when GIFs are turned off.
        case gifConsent
        /// Whether a received location is drawn as a map, which Apple's
        /// servers see. On unless turned off: see `MapPreview`.
        case mapPreviews
        /// Set once the user has agreed to Apple seeing the places and their
        /// IP address. Not synced, and kept when maps are turned off.
        case mapConsent
        /// The GIFs starred before they were synced, as JSON. Taken into
        /// `syncedEntry` and removed by the first write: see `addGifFavorite`.
        case gifFavorites
        /// The name we publish for ourselves (XEP-0172).
        case nickname
        /// Our avatar or name changed while the server couldn't be reached,
        /// as JSON: see `OwedAvatarChange` and `OwedNicknameChange`. Kept
        /// until the server has answered.
        case owedAvatarChange
        case owedNicknameChange
        /// Set once this install has our own avatar, or name, as the server
        /// holds it, including none. Without it a missing value doesn't mean
        /// the server has none, so a change isn't checked against it.
        case ownAvatarRead
        case ownNicknameRead
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
        /// Whether our name and photo are readable by everyone, rather than
        /// only by contacts. Off unless turned on.
        case sharesProfilePublicly
        /// Whether a picture from a member of a private group we haven't added
        /// downloads by itself. On unless turned off, as it shows our IP
        /// address to the sender's server.
        case downloadsFromGroupMembers
        /// Whether calls only go through the server's relay, so the person
        /// called never sees our IP address. Off unless turned on.
        case relaysCalls
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
        /// The welcome screen that asks for the privacy settings: `pending`
        /// from the first sign-in until it is answered (`1`), so a launch in
        /// between asks again. Unset on an install from before it existed,
        /// which isn't asked. Not synced: each install asks once.
        case welcomeShown
        /// How far the server's clock is ahead of this device's, in milliseconds
        /// (negative when behind), as last estimated: see `serverClockOffset`.
        /// Kept in the database rather than the session because the converting
        /// code runs inside transactions, and an extension that creates a
        /// conversation applies stored entries without a session of its own.
        case serverClockOffset
    }

    public func setting(_ key: SettingKey) throws -> String? {
        try reader.read { try Self.setting($0, key) }
    }

    /// A key that is synced between devices also records the change, in the
    /// same transaction, to be published.
    public func setSetting(_ key: SettingKey, _ value: String?) throws {
        try writer.write { db in try Self.setSettingRecordingSync(db, key, value) }
    }

    /// `setSetting` for use inside a transaction that does more.
    static func setSettingRecordingSync(_ db: Database, _ key: SettingKey, _ value: String?) throws {
        try setSetting(db, key, value)
        if syncedGlobalKeys[key] != nil { try touch(db, item: globalItem, key: key.rawValue) }
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

    private struct Introductions: Codable {
        var device: UInt32
        var rooms: [String: [String]]
        /// Members found to have no OMEMO, by when. Not per room: support is
        /// the member's account's. Absent in what older builds wrote.
        var unsupported: [String: Date]?
    }

    /// How long a member found without OMEMO is left alone before the next
    /// join looks again. A device list they publish ends it sooner, but a
    /// room member who isn't a contact doesn't send us their notifications.
    public static let unsupportedRetryInterval: TimeInterval = 3 * 24 * 60 * 60

    /// The members of `room` that OMEMO device `device` has introduced itself
    /// to. Another device id, from a fresh install or a new identity, has
    /// introduced itself to none.
    public func introducedMembers(in room: JID, device: UInt32) -> Set<JID> {
        (try? reader.read { try Self.introducedMembers($0, in: room, device: device) }) ?? []
    }

    private static func introducedMembers(_ db: Database, in room: JID, device: UInt32) throws -> Set<JID> {
        guard let kept = try keptIntroductions(db), kept.device == device else { return [] }
        return Set((kept.rooms[room.description] ?? []).compactMap(JID.init(_:)))
    }

    /// A value of another shape reads as nothing introduced.
    private static func keptIntroductions(_ db: Database) throws -> Introductions? {
        try setting(db, .introducedGroups).flatMap { try? JSONDecoder().decode(Introductions.self, from: Data($0.utf8)) }
    }

    private static func keepIntroductions(_ db: Database, _ kept: Introductions) throws {
        try setSetting(db, .introducedGroups, String(decoding: try JSONEncoder().encode(kept), as: UTF8.self))
    }

    /// In one transaction: groups finish joining on queues of their own.
    public func markIntroduced(_ members: Set<JID>, in room: JID, device: UInt32) throws {
        try writer.write { db in
            var kept = try Self.keptIntroductions(db).flatMap { $0.device == device ? $0 : nil } ?? Introductions(device: device, rooms: [:])
            kept.rooms[room.description] = Set(kept.rooms[room.description] ?? []).union(members.map(\.description)).sorted()
            try Self.keepIntroductions(db, kept)
        }
    }

    /// The members `device` found to have no OMEMO, and has not looked at
    /// again since `unsupportedRetryInterval`.
    public func unsupportedMembers(device: UInt32, now: Date = Date()) -> Set<JID> {
        let kept = (try? reader.read { try Self.keptIntroductions($0) }) ?? nil
        guard let kept, kept.device == device else { return [] }
        return Set((kept.unsupported ?? [:]).filter { now.timeIntervalSince($0.value) < Self.unsupportedRetryInterval }.keys.compactMap(JID.init(_:)))
    }

    /// Keeps that `members` have no OMEMO, so the joins that follow leave
    /// them out.
    public func markUnsupported(_ members: Set<JID>, device: UInt32, at now: Date = Date()) throws {
        try writer.write { db in
            var kept = try Self.keptIntroductions(db).flatMap { $0.device == device ? $0 : nil } ?? Introductions(device: device, rooms: [:])
            var unsupported = kept.unsupported ?? [:]
            for member in members { unsupported[member.description] = now }
            kept.unsupported = unsupported
            try Self.keepIntroductions(db, kept)
        }
    }

    /// Whether `member` was kept as having no OMEMO, and no longer is.
    @discardableResult
    public func forgetUnsupported(_ member: JID, device: UInt32) throws -> Bool {
        // Asked at every device list heard, for nearly all of which there is
        // no mark: a read keeps those out of the write queue.
        let marked = try reader.read { db in
            try Self.keptIntroductions(db).map { $0.device == device && $0.unsupported?[member.description] != nil } ?? false
        }
        guard marked else { return false }
        return try writer.write { db in
            guard var kept = try Self.keptIntroductions(db), kept.device == device, kept.unsupported?[member.description] != nil else { return false }
            kept.unsupported?[member.description] = nil
            try Self.keepIntroductions(db, kept)
            return true
        }
    }

    /// Takes `member` off the members of `room` that `device` has introduced
    /// itself to, so the next introduction includes them again.
    public func forgetIntroduced(_ member: JID, in room: JID, device: UInt32) throws {
        try writer.write { db in
            guard var kept = try Self.keptIntroductions(db), kept.device == device,
                  let members = kept.rooms[room.description], members.contains(member.description) else { return }
            kept.rooms[room.description] = members.filter { $0 != member.description }
            try Self.keepIntroductions(db, kept)
        }
    }

    /// A setting that's on or off, `defaultValue` until set.
    public func flag(_ key: SettingKey, default defaultValue: Bool) -> Bool {
        (try? reader.read { try Self.flag($0, key, default: defaultValue) }) ?? defaultValue
    }

    /// For a read that must see the flag as of the same transaction as the rest.
    static func flag(_ db: Database, _ key: SettingKey, default defaultValue: Bool) throws -> Bool {
        try setting(db, key).map { $0 == "1" } ?? defaultValue
    }

    public func setFlag(_ key: SettingKey, _ on: Bool) throws {
        try setSetting(key, on ? "1" : "0")
    }

    /// `setFlag` for use inside a transaction that does more.
    static func setFlag(_ db: Database, _ key: SettingKey, _ on: Bool) throws {
        try setSettingRecordingSync(db, key, on ? "1" : "0")
    }

    /// A setting holding a moment, stored as seconds since 1970.
    public func date(_ key: SettingKey) -> Date? {
        (try? reader.read { try Self.date($0, key) }) ?? nil
    }

    static func date(_ db: Database, _ key: SettingKey) throws -> Date? {
        try setting(db, key).flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
    }

    public func setDate(_ key: SettingKey, _ date: Date) throws {
        try setSetting(key, String(date.timeIntervalSince1970))
    }

    static func setDate(_ db: Database, _ key: SettingKey, _ date: Date) throws {
        try setSetting(db, key, String(date.timeIntervalSince1970))
    }
}
