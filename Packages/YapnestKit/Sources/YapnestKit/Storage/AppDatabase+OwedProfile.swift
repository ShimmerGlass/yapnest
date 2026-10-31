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

/// What our avatar and name are waiting to send. They are kept as settings
/// rather than a table: there is at most one of each, and a newer change
/// replaces the older one while keeping its base.
extension AppDatabase {
    private static func owed<Change: Decodable>(_ db: Database, _ key: SettingKey, as _: Change.Type) throws -> Change? {
        try setting(db, key).flatMap { try? JSONDecoder().decode(Change.self, from: Data($0.utf8)) }
    }

    private static func setOwed(_ db: Database, _ key: SettingKey, _ change: (some Encodable)?) throws {
        try setSetting(db, key, try change.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) })
    }

    func owedAvatarChange() throws -> OwedAvatarChange? {
        try reader.read { try Self.owed($0, .owedAvatarChange, as: OwedAvatarChange.self) }
    }

    func owedNicknameChange() throws -> OwedNicknameChange? {
        try reader.read { try Self.owed($0, .owedNicknameChange, as: OwedNicknameChange.self) }
    }

    /// The server's value as it was known when a change was made.
    struct OwedBase: Equatable, Sendable {
        var value: String?
        var known: Bool
    }

    /// Records the change and shows it at once, in one transaction. The base
    /// is kept from the change it replaces, or is `base` when given (a retry
    /// of a refused change, whose picture is no longer shown), or is the
    /// avatar shown now. That is unknown when none is shown and this install
    /// hasn't read ours from the server.
    func queueAvatarChange(_ image: OwedAvatarChange.Image?, for account: JID, base given: OwedBase? = nil) throws {
        try writer.write { db in
            let base: OwedBase
            if let previous = try Self.owed(db, .owedAvatarChange, as: OwedAvatarChange.self) {
                base = OwedBase(value: previous.base, known: previous.baseKnown)
            } else if let given {
                base = given
            } else {
                let shown = try Contact.fetchOne(db, key: account)?.avatarHash
                let read = try Self.setting(db, .ownAvatarRead) != nil
                base = OwedBase(value: shown, known: shown != nil || read)
            }
            try Self.setOwed(db, .owedAvatarChange, OwedAvatarChange(image: image, base: base.value, baseKnown: base.known))
            try Self.updateContact(db, account) { $0.avatarHash = image?.hash }
        }
    }

    func queueNicknameChange(_ value: String?, base given: OwedBase? = nil) throws {
        try writer.write { db in
            let base: OwedBase
            if let previous = try Self.owed(db, .owedNicknameChange, as: OwedNicknameChange.self) {
                base = OwedBase(value: previous.base, known: previous.baseKnown)
            } else if let given {
                base = given
            } else {
                let shown = try Self.setting(db, .nickname)
                let read = try Self.setting(db, .ownNicknameRead) != nil
                base = OwedBase(value: shown, known: shown != nil || read)
            }
            try Self.setOwed(db, .owedNicknameChange, OwedNicknameChange(value: value, base: base.value, baseKnown: base.known))
            try Self.setSetting(db, .nickname, value)
        }
    }

    /// Records that this install has our own avatar or name as the server
    /// holds it, even if that is none.
    func markOwnAvatarRead() throws { try setSetting(.ownAvatarRead, "1") }
    func markOwnNicknameRead() throws { try setSetting(.ownNicknameRead, "1") }

    /// Ends the owing of `sent`, which the server has answered. A change made
    /// meanwhile stays, now based on what the server holds from `sent`.
    /// Returns whether `sent` was still the change owed.
    @discardableResult
    func settleAvatarChange(_ sent: OwedAvatarChange, serverNow: String?) throws -> Bool {
        try writer.write { db in
            guard var current = try Self.owed(db, .owedAvatarChange, as: OwedAvatarChange.self) else { return false }
            try Self.setSetting(db, .ownAvatarRead, "1")
            guard current == sent else {
                current.base = serverNow
                current.baseKnown = true
                try Self.setOwed(db, .owedAvatarChange, current)
                return false
            }
            try Self.setOwed(db, .owedAvatarChange, OwedAvatarChange?.none)
            return true
        }
    }

    @discardableResult
    func settleNicknameChange(_ sent: OwedNicknameChange, serverNow: String?) throws -> Bool {
        try writer.write { db in
            guard var current = try Self.owed(db, .owedNicknameChange, as: OwedNicknameChange.self) else { return false }
            try Self.setSetting(db, .ownNicknameRead, "1")
            guard current == sent else {
                current.base = serverNow
                current.baseKnown = true
                try Self.setOwed(db, .owedNicknameChange, current)
                return false
            }
            try Self.setOwed(db, .owedNicknameChange, OwedNicknameChange?.none)
            return true
        }
    }

    /// Drops `change` and puts the avatar shown back to `shown`, unless the
    /// user has changed it since.
    @discardableResult
    func revertAvatarChange(_ change: OwedAvatarChange, shows shown: String?, for account: JID) throws -> Bool {
        try writer.write { db in
            guard try Self.owed(db, .owedAvatarChange, as: OwedAvatarChange.self) == change else { return false }
            try Self.setOwed(db, .owedAvatarChange, OwedAvatarChange?.none)
            try Self.updateContact(db, account) { $0.avatarHash = shown }
            return true
        }
    }

    @discardableResult
    func revertNicknameChange(_ change: OwedNicknameChange, shows shown: String?) throws -> Bool {
        try writer.write { db in
            guard try Self.owed(db, .owedNicknameChange, as: OwedNicknameChange.self) == change else { return false }
            try Self.setOwed(db, .owedNicknameChange, OwedNicknameChange?.none)
            try Self.setSetting(db, .nickname, shown)
            return true
        }
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
        ValueObservation.tracking { db in
            ProfilePending(
                avatar: try Self.setting(db, .owedAvatarChange) != nil,
                nickname: try Self.setting(db, .owedNicknameChange) != nil,
            )
        }
        .removeDuplicates()
    }
}
