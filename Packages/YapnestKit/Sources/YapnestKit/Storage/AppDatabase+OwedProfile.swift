import Foundation
import GRDB

/// A new avatar, or its removal, that the server doesn't have yet.
struct OwedAvatarChange: Codable, Equatable, Sendable {
    /// The picture's file is in the avatar store under `hash`, so nothing is
    /// read from Photos again when it is sent.
    struct Image: Codable, Equatable, Sendable {
        var hash: String
        var mimeType: String
        var size: Int
        var width: Int?
        var height: Int?
    }

    /// Nil takes the avatar back.
    var image: Image?
    /// The avatar the server had, as far as we knew, when the first change
    /// not yet sent was made; nil for none. Ours is only sent if the server
    /// still has this one.
    var base: String?
    /// Whether `base` is what the server had. A fresh install, or one that
    /// hasn't read our avatar from the server yet, doesn't know, and then
    /// nil in `base` doesn't mean the server has none.
    var baseKnown = true
}

/// A new name, or taking it back, that the server doesn't have yet.
struct OwedNicknameChange: Codable, Equatable, Sendable {
    /// Nil takes the name back.
    var value: String?
    /// The name the server had, as far as we knew, when the first change not
    /// yet sent was made.
    var base: String?
    /// As for `OwedAvatarChange.baseKnown`.
    var baseKnown = true
}

/// A change stored before `baseKnown` existed knew its base.
extension OwedAvatarChange {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        image = try values.decodeIfPresent(Image.self, forKey: .image)
        base = try values.decodeIfPresent(String.self, forKey: .base)
        baseKnown = try values.decodeIfPresent(Bool.self, forKey: .baseKnown) ?? true
    }
}

extension OwedNicknameChange {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        base = try values.decodeIfPresent(String.self, forKey: .base)
        baseKnown = try values.decodeIfPresent(Bool.self, forKey: .baseKnown) ?? true
    }
}

/// What the avatar and the name share as a change not sent yet: where it is
/// kept, and what showing it means.
protocol OwedChange: Codable, Equatable, Sendable {
    associatedtype Value

    /// Where the change is kept, and the setting that records this install
    /// has read the server's value.
    static var changeKey: AppDatabase.SettingKey { get }
    static var readKey: AppDatabase.SettingKey { get }

    var base: String? { get set }
    var baseKnown: Bool { get set }

    init(value: Value, base: String?, baseKnown: Bool)

    /// What is shown for `value`, and what is shown now.
    static func shown(for value: Value) -> String?
    static func currentlyShown(_ db: Database, account: JID?) throws -> String?
    static func show(_ shown: String?, _ db: Database, account: JID?) throws
}

extension OwedAvatarChange: OwedChange {
    static var changeKey: AppDatabase.SettingKey { .owedAvatarChange }
    static var readKey: AppDatabase.SettingKey { .ownAvatarRead }

    init(value: Image?, base: String?, baseKnown: Bool) {
        self.init(image: value, base: base, baseKnown: baseKnown)
    }

    static func shown(for value: Image?) -> String? { value?.hash }

    static func currentlyShown(_ db: Database, account: JID?) throws -> String? {
        guard let account else { return nil }
        return try Contact.fetchOne(db, key: account)?.avatarHash
    }

    static func show(_ shown: String?, _ db: Database, account: JID?) throws {
        guard let account else { return }
        try AppDatabase.updateContact(db, account) { $0.avatarHash = shown }
    }
}

extension OwedNicknameChange: OwedChange {
    static var changeKey: AppDatabase.SettingKey { .owedNicknameChange }
    static var readKey: AppDatabase.SettingKey { .ownNicknameRead }

    static func shown(for value: String?) -> String? { value }

    static func currentlyShown(_ db: Database, account _: JID?) throws -> String? {
        try AppDatabase.setting(db, .nickname)
    }

    static func show(_ shown: String?, _ db: Database, account _: JID?) throws {
        try AppDatabase.setSetting(db, .nickname, shown)
    }
}

/// What our avatar and name are waiting to send. They are kept as settings
/// rather than a table: there is at most one of each, and a newer change
/// replaces the older one while keeping its base.
extension AppDatabase {
    private static func owed<Change: OwedChange>(_ db: Database, as _: Change.Type) throws -> Change? {
        try setting(db, Change.changeKey).flatMap { try? JSONDecoder().decode(Change.self, from: Data($0.utf8)) }
    }

    private static func setOwed<Change: OwedChange>(_ db: Database, _ change: Change?) throws {
        try setSetting(db, Change.changeKey, try change.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) })
    }

    func owedAvatarChange() throws -> OwedAvatarChange? {
        try reader.read { try Self.owed($0, as: OwedAvatarChange.self) }
    }

    func owedNicknameChange() throws -> OwedNicknameChange? {
        try reader.read { try Self.owed($0, as: OwedNicknameChange.self) }
    }

    /// The server's value as it was known when a change was made.
    struct OwedBase: Equatable, Sendable {
        var value: String?
        var known: Bool
    }

    /// Records the change and shows it at once, in one transaction. The base
    /// is kept from the change it replaces, or is `base` when given (a retry
    /// of a refused change, whose value is no longer shown), or is the value
    /// shown now. That is unknown when none is shown and this install
    /// hasn't read ours from the server.
    private func queueOwed<Change: OwedChange>(_ value: Change.Value, for account: JID?, base given: OwedBase?) throws -> Change {
        try writer.write { db in
            let base: OwedBase
            if let previous = try Self.owed(db, as: Change.self) {
                base = OwedBase(value: previous.base, known: previous.baseKnown)
            } else if let given {
                base = given
            } else {
                let shown = try Change.currentlyShown(db, account: account)
                let read = try Self.setting(db, Change.readKey) != nil
                base = OwedBase(value: shown, known: shown != nil || read)
            }
            let change = Change(value: value, base: base.value, baseKnown: base.known)
            try Self.setOwed(db, change)
            try Change.show(Change.shown(for: value), db, account: account)
            return change
        }
    }

    func queueAvatarChange(_ image: OwedAvatarChange.Image?, for account: JID, base given: OwedBase? = nil) throws {
        let _: OwedAvatarChange = try queueOwed(image, for: account, base: given)
    }

    func queueNicknameChange(_ value: String?, base given: OwedBase? = nil) throws {
        let _: OwedNicknameChange = try queueOwed(value, for: nil, base: given)
    }

    /// Records that this install has our own avatar or name as the server
    /// holds it, even if that is none.
    func markOwnAvatarRead() throws { try setSetting(.ownAvatarRead, "1") }
    func markOwnNicknameRead() throws { try setSetting(.ownNicknameRead, "1") }

    /// Ends the owing of `sent`, which the server has answered. A change made
    /// meanwhile stays, now based on what the server holds from `sent`.
    /// Returns whether `sent` was still the change owed.
    private func settleOwed<Change: OwedChange>(_ sent: Change, serverNow: String?) throws -> Bool {
        try writer.write { db in
            guard var current = try Self.owed(db, as: Change.self) else { return false }
            try Self.setSetting(db, Change.readKey, "1")
            guard current == sent else {
                current.base = serverNow
                current.baseKnown = true
                try Self.setOwed(db, current)
                return false
            }
            try Self.setOwed(db, Change?.none)
            return true
        }
    }

    @discardableResult
    func settleAvatarChange(_ sent: OwedAvatarChange, serverNow: String?) throws -> Bool {
        try settleOwed(sent, serverNow: serverNow)
    }

    @discardableResult
    func settleNicknameChange(_ sent: OwedNicknameChange, serverNow: String?) throws -> Bool {
        try settleOwed(sent, serverNow: serverNow)
    }

    /// Drops `change` and puts what is shown back to `shown`, unless the
    /// user has changed it since.
    private func revertOwed<Change: OwedChange>(_ change: Change, shows shown: String?, for account: JID?) throws -> Bool {
        try writer.write { db in
            guard try Self.owed(db, as: Change.self) == change else { return false }
            try Self.setOwed(db, Change?.none)
            try Change.show(shown, db, account: account)
            return true
        }
    }

    @discardableResult
    func revertAvatarChange(_ change: OwedAvatarChange, shows shown: String?, for account: JID) throws -> Bool {
        try revertOwed(change, shows: shown, for: account)
    }

    @discardableResult
    func revertNicknameChange(_ change: OwedNicknameChange, shows shown: String?) throws -> Bool {
        try revertOwed(change, shows: shown, for: nil)
    }

    /// Whether our avatar and name are waiting to be sent.
    public struct ProfilePending: Equatable, Sendable {
        public var avatar: Bool
        public var nickname: Bool

        public init(avatar: Bool, nickname: Bool) {
            self.avatar = avatar
            self.nickname = nickname
        }
    }

    public func observeProfilePending() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<ProfilePending>>> {
        ValueObservation.tracking(regions: Self.settingTables) { db in
            ProfilePending(
                avatar: try Self.setting(db, .owedAvatarChange) != nil,
                nickname: try Self.setting(db, .owedNicknameChange) != nil,
            )
        }
        .removeDuplicates()
    }
}
