import Foundation
import GRDB
@preconcurrency import MartinOMEMO

/// Keeps the account's OMEMO keys, sessions and peer identities in its
/// database, except this device's identity key pair, which is in
/// `identityKeys`: see `StoredIdentity`.
///
/// libsignal calls these synchronously from inside its own lock, on whatever
/// queue is encrypting or decrypting; every call is a short database
/// transaction, so it must never run inside another one.
///
/// Trust is "blind trust before verification": new devices are trusted until
/// the user verifies one of that JID's keys, after which further new devices
/// stay undecided and receive nothing until the user decides.
final class OMEMOStore: SignalSessionStoreProtocol, SignalPreKeyStoreProtocol, SignalSignedPreKeyStoreProtocol,
    SignalIdentityKeyStoreProtocol, SignalSenderKeyStoreProtocol, @unchecked Sendable {
    private let database: AppDatabase
    private let identityKeys: any IdentityKeyStore
    private let account: String
    private let lock = NSLock()
    private var cachedKeyPair: SignalIdentityKeyPair?
    private var cachedRegistrationId: UInt32?
    /// The clock, so tests can move it.
    private let now: @Sendable () -> Date

    init(database: AppDatabase, account: JID, identityKeys: any IdentityKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.identityKeys = identityKeys
        self.account = account.description
        self.now = now
    }

    private func read<T>(_ body: (Database) throws -> T) -> T? {
        do { return try database.reader.read(body) } catch { return nil }
    }

    private func write(_ body: (Database) throws -> Void) -> Bool {
        do {
            try database.writer.write(body)
            return true
        } catch {
            return false
        }
    }

    // MARK: Local identity

    /// Finds this device's identity, or makes one: on first use, and when
    /// the database names a device whose key isn't here, which is a backup
    /// restored on another device, or onto this one after the keychain was
    /// cleared. That device's sessions and prekeys are useless without its
    /// key, so they go, and this becomes a new device; what the user decided
    /// about contacts' devices stays. A keychain that can't be read throws
    /// rather than start over.
    ///
    /// All in one immediate transaction, whose lock the app and the
    /// extensions take in turn: two processes making a device at once would
    /// leave the key of one beside the device id of the other.
    func setUpIdentityIfNeeded(context: SignalContext) throws {
        let identity = try database.writer.writeWithoutTransaction { db -> StoredIdentity in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            defer { try? db.execute(sql: "PRAGMA secure_delete = OFF") }
            var found: StoredIdentity?
            var erasedLegacyKey = false
            try db.inTransaction(.immediate) {
                (found, erasedLegacyKey) = try findOrMakeIdentity(in: db, context: context)
                return .commit
            }
            // The key's page is zeroed in the WAL; the checkpoint copies it over
            // the file's, which holds the key until then. Readers in other
            // processes can hold it back, and the next checkpoint finishes it.
            if erasedLegacyKey { _ = try? db.checkpoint(.truncate) }
            guard let found else { throw OMEMOError.keyGenerationFailed }
            return found
        }
        use(identity)
    }

    /// The decision, inside the transaction. Also says whether a key kept in
    /// the database by a version from before was erased from it.
    private func findOrMakeIdentity(in db: Database, context: SignalContext) throws -> (StoredIdentity, erasedLegacyKey: Bool) {
        let registrationId = try AppDatabase.setting(db, .omemoRegistrationId).flatMap { UInt32($0) }
        var erased = false
        if let legacy = try AppDatabase.setting(db, .omemoIdentityKeyPair) {
            // It leaves the database once the keychain holds it. One that
            // can't be moved goes all the same: a new device is made below.
            if let registrationId, let data = Data(base64Encoded: legacy) {
                let moved = StoredIdentity(registrationId: registrationId, keyPair: data)
                try identityKeys.save(moved)
                guard try identityKeys.load() == moved else { throw OMEMOError.identityNotStored }
            }
            try AppDatabase.setSetting(db, .omemoIdentityKeyPair, nil)
            erased = true
        }
        if let registrationId, let stored = try identityKeys.load(), stored.registrationId == registrationId {
            return (stored, erased)
        }
        guard let keyPair = SignalIdentityKeyPair.generateKeyPair(context: context), let data = keyPair.keyPair else {
            throw OMEMOError.keyGenerationFailed
        }
        let newId = context.generateRegistrationId()
        guard newId != 0 else { throw OMEMOError.keyGenerationFailed }
        let identity = StoredIdentity(registrationId: newId, keyPair: data)
        // The key first: should the transaction fail after it, the database
        // still names the old device, which has no key here, and this runs again.
        try identityKeys.save(identity)
        if registrationId != nil {
            try db.execute(sql: "DELETE FROM omemoSession")
            try db.execute(sql: "DELETE FROM omemoPreKey")
            try db.execute(sql: "DELETE FROM omemoSignedPreKey")
        }
        try AppDatabase.setSetting(db, .omemoRegistrationId, String(newId))
        return (identity, erased)
    }

    private func use(_ identity: StoredIdentity) {
        lock.withLock {
            cachedKeyPair = SignalIdentityKeyPair(fromKeyPairData: identity.keyPair)
            cachedRegistrationId = identity.registrationId
        }
    }

    func keyPair() -> SignalIdentityKeyPairProtocol? {
        lock.withLock { cachedKeyPair }
    }

    /// This device's id, found with its key by `setUpIdentityIfNeeded`.
    func localRegistrationId() -> UInt32 {
        lock.withLock { cachedRegistrationId ?? 0 }
    }

    // MARK: Sessions

    func sessionRecord(forAddress address: SignalAddress) -> Data? {
        read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM omemoSession WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId])
        } ?? nil
    }

    func allDevices(for name: String, activeAndTrusted: Bool) -> [Int32] {
        read { db in
            if activeAndTrusted {
                let usable = [IdentityStatus.trustedActive, .verifiedActive].map(\.rawValue)
                return try Int32.fetchAll(db, sql: """
                    SELECT s.deviceId FROM omemoSession s
                    JOIN omemoIdentity i ON i.name = s.name AND i.deviceId = s.deviceId
                    WHERE s.name = ? AND i.status IN (\(usable.map(String.init).joined(separator: ",")))
                    """, arguments: [name])
            }
            return try Int32.fetchAll(db, sql: "SELECT deviceId FROM omemoSession WHERE name = ?", arguments: [name])
        } ?? []
    }

    func storeSessionRecord(_ data: Data, forAddress address: SignalAddress) -> Bool {
        write { db in
            try db.execute(sql: """
                INSERT INTO omemoSession (name, deviceId, data) VALUES (?, ?, ?)
                ON CONFLICT(name, deviceId) DO UPDATE SET data = excluded.data
                """, arguments: [address.name, address.deviceId, data])
        }
    }

    func containsSessionRecord(forAddress address: SignalAddress) -> Bool {
        read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM omemoSession WHERE name = ? AND deviceId = ?)", arguments: [address.name, address.deviceId])
        } == true
    }

    func deleteSessionRecord(forAddress address: SignalAddress) -> Bool {
        write { db in
            try db.execute(sql: "DELETE FROM omemoSession WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId])
        }
    }

    func deleteAllSessions(for name: String) -> Bool {
        write { db in try db.execute(sql: "DELETE FROM omemoSession WHERE name = ?", arguments: [name]) }
    }

    // MARK: Prekeys

    func currentPreKeyId() -> UInt32 {
        (read { db in try UInt32.fetchOne(db, sql: "SELECT MAX(id) FROM omemoPreKey") } ?? nil) ?? 0
    }

    /// A prekey libsignal has deleted is gone, though its row stays until
    /// `flushDeletedPreKeys`: that waits for a catch-up to end, and for an
    /// extension that dies first it may never come. Several messages built
    /// from one prekey still decrypt, as libsignal sets the session up from
    /// the first and recognizes the rest by their base key without loading it.
    func loadPreKey(withId id: UInt32) -> Data? {
        read { db in try Data.fetchOne(db, sql: "SELECT data FROM omemoPreKey WHERE id = ? AND isDeleted = 0", arguments: [id]) } ?? nil
    }

    func storePreKey(_ data: Data, withId id: UInt32) -> Bool {
        write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO omemoPreKey (id, data, isDeleted) VALUES (?, ?, 0)", arguments: [id, data])
        }
    }

    func containsPreKey(withId id: UInt32) -> Bool {
        read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM omemoPreKey WHERE id = ? AND isDeleted = 0)", arguments: [id]) } == true
    }

    func deletePreKey(withId id: UInt32) -> Bool {
        write { db in try db.execute(sql: "UPDATE omemoPreKey SET isDeleted = 1 WHERE id = ?", arguments: [id]) }
    }

    func flushDeletedPreKeys() -> Bool {
        var flushed = false
        _ = write { db in
            try db.execute(sql: "DELETE FROM omemoPreKey WHERE isDeleted = 1")
            flushed = db.changesCount > 0
        }
        return flushed
    }

    // MARK: Signed prekeys

    /// How long a signed prekey is published before the next one replaces it.
    static let signedPreKeyLifetime: TimeInterval = 7 * 24 * 3600
    /// How long a replaced one stays, for sessions started from the bundle it
    /// was in. Counted from when it was replaced.
    static let signedPreKeyGrace: TimeInterval = 28 * 24 * 3600

    /// The id of the newest one, which the module takes as its count to pick
    /// the next id. Not a count: old ones are deleted, and ids must not repeat.
    func countSignedPreKeys() -> Int {
        (read { db in try Int.fetchOne(db, sql: "SELECT MAX(id) FROM omemoSignedPreKey") } ?? nil) ?? 0
    }

    /// Whether the newest signed prekey has been published for its lifetime.
    /// Also deletes the replaced ones that have outlived the grace period.
    func signedPreKeyRotationDue() -> Bool {
        let now = now()
        let dates = read { db in
            try Row.fetchAll(db, sql: "SELECT id, createdAt FROM omemoSignedPreKey ORDER BY id")
                .map { ($0["id"] as Int64, ($0["createdAt"] as Date?) ?? now) }
        } ?? []
        // A key is replaced when the next one is made.
        let expired = dates.indices.dropLast().filter { now.timeIntervalSince(dates[$0 + 1].1) >= Self.signedPreKeyGrace }.map { dates[$0].0 }
        if !expired.isEmpty {
            _ = write { db in
                for id in expired { try db.execute(sql: "DELETE FROM omemoSignedPreKey WHERE id = ?", arguments: [id]) }
            }
        }
        return dates.last.map { now.timeIntervalSince($0.1) >= Self.signedPreKeyLifetime } ?? false
    }

    func loadSignedPreKey(withId id: UInt32) -> Data? {
        read { db in try Data.fetchOne(db, sql: "SELECT data FROM omemoSignedPreKey WHERE id = ?", arguments: [id]) } ?? nil
    }

    func storeSignedPreKey(_ data: Data, withId id: UInt32) -> Bool {
        write { db in try db.execute(sql: "INSERT OR REPLACE INTO omemoSignedPreKey (id, data, createdAt) VALUES (?, ?, ?)", arguments: [id, data, now()]) }
    }

    func containsSignedPreKey(withId id: UInt32) -> Bool {
        read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM omemoSignedPreKey WHERE id = ?)", arguments: [id]) } == true
    }

    func deleteSignedPreKey(withId id: UInt32) -> Bool {
        write { db in try db.execute(sql: "DELETE FROM omemoSignedPreKey WHERE id = ?", arguments: [id]) }
    }

    // MARK: Peer identities

    func save(identity: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        save(identity: identity, publicKeyData: key?.serialized())
    }

    func save(identity address: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let key = publicKeyData else { return false }
        return write { db in
            if let stored = try Data.fetchOne(db, sql: "SELECT key FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId]) {
                // A device's identity never changes; isTrusted refuses a different one.
                guard stored == key else { throw OMEMOError.identityChanged }
                return
            }
            let seen = try Row.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM omemoIdentity WHERE name = ? AND status IN (?, ?)) AS hasVerified,
                       EXISTS (SELECT 1 FROM omemoIdentity WHERE name = ?) AS hadDevices
                """, arguments: [address.name, IdentityStatus.verifiedActive.rawValue, IdentityStatus.verifiedInactive.rawValue, address.name])
            let hasVerified: Bool = seen?["hasVerified"] ?? false, hadDevices: Bool = seen?["hadDevices"] ?? false
            let status: IdentityStatus = hasVerified ? .undecidedActive : .trustedActive
            let date = now()
            try db.execute(sql: "INSERT INTO omemoIdentity (name, deviceId, key, status, firstSeen) VALUES (?, ?, ?, ?, ?)",
                           arguments: [address.name, address.deviceId, key, status.rawValue, date])
            guard !isLocalDevice(address) else { return }
            // Whatever its status, the device now gets or may get our messages; the user hears of it.
            // A side effect must never cost the session its device: if the
            // notice can't be written, only it is rolled back.
            do {
                try db.inSavepoint {
                    try AppDatabase.noteNewDevice(
                        db, name: address.name, deviceId: address.deviceId, fingerprint: Self.fingerprint(of: key),
                        isOwn: address.name == account, hadDevices: hadDevices, at: date,
                    )
                    return .commit
                }
            } catch {
                DiagLog.error(.omemo, "New device not recorded", .error(error))
            }
        }
    }

    /// This install's own device, whose identity is the key pair rather than a row.
    private func isLocalDevice(_ address: SignalAddress) -> Bool {
        address.name == account && UInt32(bitPattern: address.deviceId) == localRegistrationId()
    }

    func isTrusted(identity: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        isTrusted(identity: identity, publicKeyData: key?.serialized())
    }

    /// Whether libsignal may use this key at all: it must match what we saw
    /// before and not be marked compromised. Undecided keys pass, so their
    /// messages can still be read; they just aren't encrypted to.
    func isTrusted(identity address: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let key = publicKeyData else { return false }
        guard let row = read({ db in
            try Row.fetchOne(db, sql: "SELECT key, status FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId])
        }) else { return false }
        guard let row else { return true }
        let status = IdentityStatus(rawValue: row["status"]) ?? .undecidedActive
        return (row["key"] as Data) == key && status.trust != .compromised
    }

    func setStatus(_ status: IdentityStatus, forIdentity address: SignalAddress) -> Bool {
        write { db in
            try db.execute(sql: "UPDATE omemoIdentity SET status = ? WHERE name = ? AND deviceId = ?",
                           arguments: [status.rawValue, address.name, address.deviceId])
        }
    }

    func setStatus(active: Bool, forIdentity address: SignalAddress) -> Bool {
        write { db in
            guard let raw = try Int.fetchOne(db, sql: "SELECT status FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId]),
                  let status = IdentityStatus(rawValue: raw) else { return }
            let updated = active ? status.toActive() : status.toInactive()
            guard updated != status else { return }
            try db.execute(sql: "UPDATE omemoIdentity SET status = ? WHERE name = ? AND deviceId = ?",
                           arguments: [updated.rawValue, address.name, address.deviceId])
        }
    }

    func identities(forName name: String) -> [Identity] {
        read { db in
            try Row.fetchAll(db, sql: "SELECT deviceId, key, status FROM omemoIdentity WHERE name = ? ORDER BY deviceId", arguments: [name]).map { row in
                let key: Data = row["key"]
                return Identity(
                    address: SignalAddress(name: name, deviceId: row["deviceId"]),
                    status: IdentityStatus(rawValue: row["status"]) ?? .undecidedActive,
                    fingerprint: Self.fingerprint(of: key),
                    key: key,
                    own: name == account,
                )
            }
        } ?? []
    }

    func status(forName name: String, deviceId: Int32) -> IdentityStatus? {
        read { db in
            try Int.fetchOne(db, sql: "SELECT status FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [name, deviceId])
        }.flatMap { $0 }.map { IdentityStatus(rawValue: $0) ?? .undecidedActive }
    }

    // MARK: Usage

    struct Usage: Equatable {
        var firstSeen: Date
        var lastUsed: Date?

        func isInactive(now: Date) -> Bool {
            OMEMODevice.isInactive(firstSeen: firstSeen, lastUsed: lastUsed, now: now)
        }
    }

    /// Records that `deviceId` of `name` sent something at `date`. Only
    /// ever moves forward, so paging through old history can't undo it, and
    /// never into the future, so a wrong date can't keep a device alive. A
    /// device we have no identity for yet isn't recorded; it has no row, and
    /// isn't listed or encrypted to until a session creates one.
    func noteUsed(name: String, deviceId: Int32, at date: Date) {
        let date = min(date, now())
        _ = write { db in
            try db.execute(sql: """
                UPDATE omemoIdentity SET lastUsed = ?
                WHERE name = ? AND deviceId = ? AND (lastUsed IS NULL OR lastUsed < ?)
                """, arguments: [date, name, deviceId, date])
        }
    }

    /// The most devices of one JID we build sessions for.
    static let deviceLimit = 64

    /// `ids`, a device list as read from the server, cut to `deviceLimit`. A
    /// list that long is more likely an attack than a person's devices, and
    /// each device costs a bundle fetch and a stanza that bounces. Kept in
    /// this order: devices we know that are in use, most recent first; then
    /// ones we have never seen, in the list's order, so a new device takes
    /// the place of a stale one; then known devices gone quiet. This
    /// install's own device is never cut.
    func limited(_ ids: [Int32], of name: String) -> [Int32] {
        guard ids.count > Self.deviceLimit else { return ids }
        let usage = usage(forName: name), now = now()
        func recency(_ id: Int32) -> Date { usage[id].map { $0.lastUsed ?? $0.firstSeen } ?? .distantPast }
        var seen = Set<Int32>()
        let unique = ids.filter { seen.insert($0).inserted }
        let known = unique.filter { usage[$0] != nil }.sorted { recency($0) > recency($1) }
        let active = known.filter { !usage[$0]!.isInactive(now: now) }
        let quiet = known.filter { usage[$0]!.isInactive(now: now) }
        let unknown = unique.filter { usage[$0] == nil }
        let local = Int32(bitPattern: localRegistrationId())
        let own = name == account && unique.contains(local) ? [local] : []
        var taken = Set<Int32>()
        let kept = Array((own + active + unknown + quiet).filter { taken.insert($0).inserted }.prefix(Self.deviceLimit))
        DiagLog.info(.omemo, "Device list cut", .int("listed", ids.count), .int("kept", kept.count))
        return kept
    }

    func usage(forName name: String) -> [Int32: Usage] {
        read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT deviceId, firstSeen, lastUsed FROM omemoIdentity WHERE name = ?", arguments: [name])
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                // A row from before the column has no day; it starts now.
                (row["deviceId"] as Int32, Usage(firstSeen: (row["firstSeen"] as Date?) ?? now(), lastUsed: row["lastUsed"]))
            })
        } ?? [:]
    }

    /// Drops everything about these devices of `name`. One that turns up again
    /// is met as new, except a compromised one: its row stays, so removing a
    /// device the user blocked doesn't let it come back trusted.
    func forget(deviceIds: [Int32], of name: String) {
        _ = write { db in
            for id in deviceIds {
                try db.execute(sql: "DELETE FROM omemoSession WHERE name = ? AND deviceId = ?", arguments: [name, id])
                // Gone from the account, so there's nothing left to warn about.
                if name == account { try db.execute(sql: "DELETE FROM deviceNotice WHERE deviceId = ?", arguments: [id]) }
                try db.execute(sql: "DELETE FROM omemoIdentity WHERE name = ? AND deviceId = ? AND status NOT IN (?, ?)",
                               arguments: [name, id, IdentityStatus.compromisedActive.rawValue, IdentityStatus.compromisedInactive.rawValue])
            }
        }
    }

    /// `devices` of `name` without the inactive ones, unless that leaves none:
    /// a contact whose devices have all gone quiet is more likely away than
    /// gone, and a message should stay readable somewhere.
    func excludingInactive(_ devices: [Int32], of name: String) -> [Int32] {
        let active = withoutInactive(devices, of: name)
        return active.isEmpty ? devices : active
    }

    private func withoutInactive(_ devices: [Int32], of name: String) -> [Int32] {
        let usage = usage(forName: name), now = now()
        return devices.filter { usage[$0].map { !$0.isInactive(now: now) } ?? true }
    }

    /// Our own devices to encrypt to: the usable ones that haven't gone
    /// quiet. Unlike a contact's, they may all be left out, since we hold
    /// the plaintext ourselves.
    func ownDevicesToEncryptTo() -> [Int32] {
        withoutInactive(allDevices(for: account, activeAndTrusted: true), of: account)
    }

    func identityFingerprint(forAddress address: SignalAddress) -> String? {
        if isLocalDevice(address) {
            return keyPair()?.publicKey.map(Self.fingerprint)
        }
        return read { db in
            try Data.fetchOne(db, sql: "SELECT key FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId])
        }?.map(Self.fingerprint)
    }

    /// Hex of the Curve25519 key, without libsignal's leading type byte; the
    /// form other clients show.
    static func fingerprint(of key: Data) -> String {
        let bytes = key.count == 33 ? key.dropFirst() : key[...]
        return bytes.hex
    }

    // MARK: Sender keys (group sessions; unused by OMEMO 0.3)

    func storeSenderKey(_ key: Data, address: SignalAddress?, groupId: String?) -> Bool { false }
    func loadSenderKey(forAddress address: SignalAddress?, groupId: String?) -> Data? { nil }
}

extension AppDatabase {
    /// A trusted device of `account` with a session, as a development
    /// fixture's account would have after hearing from it.
    public func addOMEMODeviceForFixture(of account: JID, id: Int32, keyByte: UInt8, firstSeen: Date, lastUsed: Date?) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO omemoIdentity (name, deviceId, key, status, firstSeen, lastUsed) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [account.description, id, Data([0x05] + Array(repeating: keyByte, count: 32)), IdentityStatus.trustedActive.rawValue, firstSeen, lastUsed])
            try db.execute(sql: "INSERT INTO omemoSession (name, deviceId, data) VALUES (?, ?, ?)", arguments: [account.description, id, Data([keyByte])])
        }
    }
}

enum OMEMOError: Error {
    case keyGenerationFailed
    case identityChanged
    /// The keychain took the identity but gave back something else.
    case identityNotStored
}
