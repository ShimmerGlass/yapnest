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
}

/// A new name, or taking it back, that the server doesn't have yet.
struct OwedNicknameChange: Codable, Equatable, Sendable {
    /// Nil takes the name back.
    var value: String?
    /// The name the server had, as far as we knew, when the first change not
    /// yet sent was made.
    var base: String?
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

    /// Records the change and shows it at once, in one transaction. The base
    /// is kept from the change it replaces, or is the avatar shown now.
    func queueAvatarChange(_ image: OwedAvatarChange.Image?, for account: JID) throws {
        try writer.write { db in
            let base = try Self.owed(db, .owedAvatarChange, as: OwedAvatarChange.self).map(\.base)
                ?? Contact.fetchOne(db, key: account)?.avatarHash
            try Self.setOwed(db, .owedAvatarChange, OwedAvatarChange(image: image, base: base))
            try Self.updateContact(db, account) { $0.avatarHash = image?.hash }
        }
    }

    func queueNicknameChange(_ value: String?) throws {
        try writer.write { db in
            let base = try Self.owed(db, .owedNicknameChange, as: OwedNicknameChange.self).map(\.base)
                ?? Self.setting(db, .nickname)
            try Self.setOwed(db, .owedNicknameChange, OwedNicknameChange(value: value, base: base))
            try Self.setSetting(db, .nickname, value)
        }
    }

    /// Ends the owing of `sent`, which the server has answered. A change made
    /// meanwhile stays, now based on what the server holds from `sent`.
    /// Returns whether `sent` was still the change owed.
    @discardableResult
    func settleAvatarChange(_ sent: OwedAvatarChange, serverNow: String?) throws -> Bool {
        try writer.write { db in
            guard var current = try Self.owed(db, .owedAvatarChange, as: OwedAvatarChange.self) else { return false }
            guard current == sent else {
                current.base = serverNow
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
            guard current == sent else {
                current.base = serverNow
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
