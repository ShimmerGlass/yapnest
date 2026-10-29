import Foundation
import GRDB
@preconcurrency import MartinOMEMO
import libsignal

/// Keeps the account's OMEMO keys, sessions and peer identities in its
/// database, except this device's identity key pair, which is in
/// `identityKeys`: see `StoredIdentity`.
///
/// libsignal calls these synchronously from inside its own lock, on whatever
/// queue is encrypting or decrypting; every call is a short database
/// transaction, so it must never run inside another one. A send is the
/// exception: see `batchingSessions`.
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
    /// The context whose lock libsignal holds while it uses these sessions.
    /// Weak, as the context keeps the storage that keeps this store.
    weak var signalContext: SignalContext?
    /// The sessions of the send under way: see `batchingSessions`. Guarded
    /// by `lock`, and only ever set by the thread holding the context's lock.
    private var batch: SessionBatch?

    private struct SessionBatch {
        /// As read when the send began.
        var loaded: [SignalAddress: Data] = [:]
        /// As libsignal left them, to be written when it ends.
        var stored: [SignalAddress: Data] = [:]

        func record(for address: SignalAddress) -> Data? { stored[address] ?? loaded[address] }
    }

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
        var registrationId = try AppDatabase.setting(db, .omemoRegistrationId).flatMap { UInt32($0) }
        var erased = false
        if let legacy = try AppDatabase.setting(db, .omemoIdentityKeyPair) {
            let kept = try identityKeys.load()
            // It leaves the database once the keychain holds it. One that
            // can't be moved goes all the same: a new device is made below.
            if let kept, kept.keyPair != Data(base64Encoded: legacy), try Self.hasSignedPreKey(of: kept, in: db) {
                // A build from before the keychain, installed over a later
                // one, found no key in the database and made a device of its
                // own. The keychain's is the one contacts know, and a contact
                // who isn't subscribed to us never hears of another, so it
                // stays and the older build's goes. Only if this database
                // signed with it: the keychain outlives a deleted app, and a
                // key from an install before that is no one's device now.
                try replaceDevice(registrationId, with: kept, in: db, context: context)
                registrationId = kept.registrationId
            } else if let registrationId, let data = Data(base64Encoded: legacy) {
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

    /// Puts `kept` back in place of the device an older build made in the
    /// database, and notes that device for the session to take off the
    /// account's list. The sessions stay: most are the kept device's, and
    /// the few the other one set up are repaired by whoever holds them.
    private func replaceDevice(_ replaced: UInt32?, with kept: StoredIdentity, in db: Database, context: SignalContext) throws {
        // Its signed prekey is signed with its own key and has the highest
        // id, which the bundle publishes: every contact would refuse it. One
        // signed with the kept key goes above it. The kept device's own stay
        // for the sessions started from its bundle meanwhile, unless the older
        // build, which counted rows for the next id, wrote over one; a
        // message built on that one is repaired. The other's go with the old
        // ones once their grace is over.
        let newest = try Self.newestSignedPreKeyId(in: db)
        guard let pair = SignalIdentityKeyPair(fromKeyPairData: kept.keyPair),
              let signed = context.generateSignedPreKey(withIdentity: pair, signedPreKeyId: UInt32(newest + 1), timestamp: now()),
              let data = signed.serializedData else { throw OMEMOError.keyGenerationFailed }
        try Self.storeSignedPreKey(data, withId: signed.preKeyId, at: now(), in: db)
        try AppDatabase.setSetting(db, .omemoRegistrationId, String(kept.registrationId))
        guard let replaced, replaced != kept.registrationId else { return }
        let id = Int32(bitPattern: replaced)
        try Self.setReplacedDeviceIds(try Self.replacedDeviceIds(in: db) + [id], in: db)
        DiagLog.notice(.omemo, "Device made by an older build replaced by the keychain's", .id("device", Redacted.id(String(id))))
    }

    /// Whether any signed prekey in the database is signed with `identity`'s
    /// key, which only that device's own registrations make.
    private static func hasSignedPreKey(of identity: StoredIdentity, in db: Database) throws -> Bool {
        guard let publicKey = SignalIdentityKeyPair(fromKeyPairData: identity.keyPair)?.publicKey,
              let key = SignalIdentityKey.publicKey(from: publicKey) else { return false }
        return try Data.fetchAll(db, sql: "SELECT data FROM omemoSignedPreKey").contains { data in
            guard let signed = SignalSignedPreKey(fromSerializedData: data), let message = signed.publicKeyData else { return false }
            let signature = signed.signature
            return message.withUnsafeBytes { m in
                signature.withUnsafeBytes { s in
                    curve_verify_signature(key, m.baseAddress!.assumingMemoryBound(to: UInt8.self), message.count, s.baseAddress!.assumingMemoryBound(to: UInt8.self), signature.count)
                }
            } == 1
        }
    }

    private static func replacedDeviceIds(in db: Database) throws -> [Int32] {
        (try AppDatabase.setting(db, .omemoReplacedDeviceIds) ?? "").split(separator: ",").compactMap { UInt32($0).map { Int32(bitPattern: $0) } }
    }

    private static func setReplacedDeviceIds(_ ids: [Int32], in db: Database) throws {
        try AppDatabase.setSetting(db, .omemoReplacedDeviceIds, ids.isEmpty ? nil : ids.map { String(UInt32(bitPattern: $0)) }.joined(separator: ","))
    }

    /// The devices `replaceDevice` gave up, not yet off the account's list.
    func replacedDeviceIds() -> [Int32] {
        read { db in try Self.replacedDeviceIds(in: db) } ?? []
    }

    /// Forgets `ids` as replaced devices, and what was kept of them as our
    /// account's other devices.
    func forgetReplaced(_ ids: [Int32]) {
        forget(deviceIds: ids, of: account)
        _ = write { db in
            try Self.setReplacedDeviceIds(try Self.replacedDeviceIds(in: db).filter { !ids.contains($0) }, in: db)
        }
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

    /// Runs `encode`, which encrypts one message for `addresses`, as one step:
    /// their sessions are read in one transaction before, and what libsignal
    /// stores of them is written in one after, rather than a transaction for
    /// each load and store of each device, which for a group came to hundreds.
    ///
    /// It all happens holding the lock libsignal takes for each call, so no
    /// decrypt or other send can use these sessions in between and see them
    /// as they were, and nothing else that writes sessions (see
    /// `serialized`) can come between the read and the write.
    ///
    /// - Returns: false when the sessions couldn't be written. The message
    ///   must then not go out: it was encrypted with keys that weren't kept,
    ///   and the next message would use them again.
    func batchingSessions(for addresses: [SignalAddress], _ encode: () -> Void) -> Bool {
        serialized {
            let wanted = Array(Set(addresses))
            var loaded: [SignalAddress: Data] = [:]
            _ = read { db in
                let pairs = Array(repeating: "(?, ?)", count: wanted.count).joined(separator: ", ")
                let arguments = StatementArguments(wanted.flatMap { [$0.name, $0.deviceId] as [(any DatabaseValueConvertible)?] })
                for row in try Row.fetchAll(db, sql: "SELECT name, deviceId, data FROM omemoSession WHERE (name, deviceId) IN (VALUES \(pairs))", arguments: arguments) {
                    loaded[SignalAddress(name: row["name"], deviceId: row["deviceId"])] = row["data"]
                }
            }
            lock.withLock { batch = SessionBatch(loaded: loaded) }
            encode()
            let stored = lock.withLock {
                defer { batch = nil }
                return batch?.stored ?? [:]
            }
            guard !stored.isEmpty else { return true }
            return write { db in
                for (address, data) in stored {
                    try Self.storeSession(data, for: address, in: db)
                }
            }
        }
    }

    /// Runs `body` holding the lock libsignal takes for each call, so that a
    /// change to sessions made outside libsignal can't land in the middle of
    /// a send's batch and be overwritten by it. Taken before any database
    /// lock, as libsignal's calls do. The lock is recursive, so libsignal's
    /// own calls, which hold it already, go straight through.
    private func serialized<T>(_ body: () -> T) -> T {
        guard let signalContext else { return body() }
        return signalContext.withLock(body)
    }

    private func batched(_ body: (inout SessionBatch) -> Void) -> Bool {
        lock.withLock {
            guard batch != nil else { return false }
            body(&batch!)
            return true
        }
    }

    private func batchedRecord(for address: SignalAddress) -> Data? {
        lock.withLock { batch?.record(for: address) }
    }

    private static func storeSession(_ data: Data, for address: SignalAddress, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO omemoSession (name, deviceId, data) VALUES (?, ?, ?)
            ON CONFLICT(name, deviceId) DO UPDATE SET data = excluded.data
            """, arguments: [address.name, address.deviceId, data])
    }

    func sessionRecord(forAddress address: SignalAddress) -> Data? {
        if let record = batchedRecord(for: address) { return record }
        return read { db in
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
        if batched({ $0.stored[address] = data }) { return true }
        return write { db in try Self.storeSession(data, for: address, in: db) }
    }

    func containsSessionRecord(forAddress address: SignalAddress) -> Bool {
        if batchedRecord(for: address) != nil { return true }
        return read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM omemoSession WHERE name = ? AND deviceId = ?)", arguments: [address.name, address.deviceId])
        } == true
    }

    func deleteSessionRecord(forAddress address: SignalAddress) -> Bool {
        serialized {
            _ = batched { $0.loaded[address] = nil; $0.stored[address] = nil }
            return write { db in
                try db.execute(sql: "DELETE FROM omemoSession WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId])
            }
        }
    }

    func deleteAllSessions(for name: String) -> Bool {
        serialized {
            _ = batched { batch in
                batch.loaded = batch.loaded.filter { $0.key.name != name }
                batch.stored = batch.stored.filter { $0.key.name != name }
            }
            return write { db in try db.execute(sql: "DELETE FROM omemoSession WHERE name = ?", arguments: [name]) }
        }
    }

    // MARK: Prekeys

    func currentPreKeyId() -> UInt32 {
        (read { db in try UInt32.fetchOne(db, sql: "SELECT MAX(id) FROM omemoPreKey") } ?? nil) ?? 0
    }

    /// A prekey libsignal has deleted stays readable until
    /// `flushDeletedPreKeys`, which runs at the end of the catch-up that used
    /// it, on a reset or disconnect, and at the next start for one an
    /// extension left. Two people who fetched the same bundle can pick the
    /// same prekey, and the second's messages would otherwise never decrypt.
    /// It is never published again meanwhile (`isPreKeyDeleted`).
    func loadPreKey(withId id: UInt32) -> Data? {
        read { db in try Data.fetchOne(db, sql: "SELECT data FROM omemoPreKey WHERE id = ?", arguments: [id]) } ?? nil
    }

    func isPreKeyDeleted(withId id: UInt32) -> Bool {
        read { db in try Bool.fetchOne(db, sql: "SELECT isDeleted FROM omemoPreKey WHERE id = ?", arguments: [id]) } == true
    }

    func storePreKey(_ data: Data, withId id: UInt32) -> Bool {
        write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO omemoPreKey (id, data, isDeleted) VALUES (?, ?, 0)", arguments: [id, data])
        }
    }

    func containsPreKey(withId id: UInt32) -> Bool {
        read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM omemoPreKey WHERE id = ?)", arguments: [id]) } == true
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
        read { db in try Self.newestSignedPreKeyId(in: db) } ?? 0
    }

    private static func newestSignedPreKeyId(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT MAX(id) FROM omemoSignedPreKey") ?? 0
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
        write { db in try Self.storeSignedPreKey(data, withId: id, at: now(), in: db) }
    }

    private static func storeSignedPreKey(_ data: Data, withId id: UInt32, at date: Date, in db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO omemoSignedPreKey (id, data, createdAt) VALUES (?, ?, ?)", arguments: [id, data, date])
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
                guard stored == key else {
                    DiagLog.notice(.omemo, "Different key for a known device refused", .id("device", Redacted.id(String(address.deviceId))), .bool("ownAccount", address.name == account))
                    throw OMEMOError.identityChanged
                }
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
        // Asked on every message read, and nearly always a no-op: look on a
        // reader first, and take the write lock only for a change.
        func changed(_ db: Database) throws -> Int? {
            guard let raw = try Int.fetchOne(db, sql: "SELECT status FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [address.name, address.deviceId]),
                  let status = IdentityStatus(rawValue: raw) else { return nil }
            let updated = active ? status.toActive() : status.toInactive()
            return updated == status ? nil : updated.rawValue
        }
        // A reader that fails goes on to the writer, which reports it.
        if read({ db in try changed(db) == nil }) == true { return true }
        return write { db in
            guard let updated = try changed(db) else { return }
            try db.execute(sql: "UPDATE omemoIdentity SET status = ? WHERE name = ? AND deviceId = ?",
                           arguments: [updated, address.name, address.deviceId])
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
        let local = Int32(bitPattern: localRegistrationId())
        let unique = ids.filter { seen.insert($0).inserted }
        let own = name == account && seen.contains(local) ? [local] : []
        var known: [Int32] = [], unknown: [Int32] = []
        for id in unique where id != local || own.isEmpty {
            if usage[id] != nil { known.append(id) } else { unknown.append(id) }
        }
        var active: [Int32] = [], quiet: [Int32] = []
        for id in known.sorted(by: { recency($0) > recency($1) }) {
            if usage[id]!.isInactive(now: now) { quiet.append(id) } else { active.append(id) }
        }
        let kept = Array((own + active + unknown + quiet).prefix(Self.deviceLimit))
        DiagLog.info(.omemo, "Device list cut", .int("listed", ids.count), .int("kept", kept.count))
        return kept
    }

    func usage(forName name: String) -> [Int32: Usage] {
        read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT deviceId, firstSeen, lastUsed FROM omemoIdentity WHERE name = ?", arguments: [name])
            return Dictionary(uniqueKeysWithValues: rows.map { row in (row["deviceId"] as Int32, usage(row)) })
        } ?? [:]
    }

    private func usage(_ row: Row) -> Usage {
        // A row from before the column has no day; it starts now.
        Usage(firstSeen: (row["firstSeen"] as Date?) ?? now(), lastUsed: row["lastUsed"])
    }

    /// What deciding which devices of one name a message goes to takes.
    struct SendState {
        var statuses: [Int32: IdentityStatus] = [:]
        var usage: [Int32: Usage] = [:]
        var sessions: Set<Int32> = []
    }

    /// `SendState` of each of `names`, in one read for all of them rather than
    /// a few for every device. A name with nothing stored has an empty one.
    func sendState(forNames names: [String]) -> [String: SendState] {
        guard !names.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: names.count)
        return read { db in
            var states: [String: SendState] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT name, deviceId, status, firstSeen, lastUsed FROM omemoIdentity WHERE name IN (\(marks))", arguments: StatementArguments(names)) {
                let name: String = row["name"], deviceId: Int32 = row["deviceId"]
                states[name, default: SendState()].statuses[deviceId] = IdentityStatus(rawValue: row["status"]) ?? .undecidedActive
                states[name, default: SendState()].usage[deviceId] = usage(row)
            }
            for row in try Row.fetchAll(db, sql: "SELECT name, deviceId FROM omemoSession WHERE name IN (\(marks))", arguments: StatementArguments(names)) {
                states[row["name"], default: SendState()].sessions.insert(row["deviceId"])
            }
            return states
        } ?? [:]
    }

    /// Drops everything about these devices of `name`. One that turns up again
    /// is met as new, except a compromised one: its row stays, so removing a
    /// device the user blocked doesn't let it come back trusted.
    func forget(deviceIds: [Int32], of name: String) {
        serialized {
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
    }

    /// `devices` of `name` without the inactive ones, unless that leaves none:
    /// a contact whose devices have all gone quiet is more likely away than
    /// gone, and a message should stay readable somewhere.
    func excludingInactive(_ devices: [Int32], usage: [Int32: Usage]) -> [Int32] {
        let active = withoutInactive(devices, usage: usage)
        return active.isEmpty ? devices : active
    }

    private func withoutInactive(_ devices: [Int32], usage: [Int32: Usage]) -> [Int32] {
        let now = now()
        return devices.filter { usage[$0].map { !$0.isInactive(now: now) } ?? true }
    }

    /// Our own devices to encrypt to: the usable ones that haven't gone
    /// quiet. Unlike a contact's, they may all be left out, since we hold
    /// the plaintext ourselves.
    func ownDevicesToEncryptTo() -> [Int32] {
        withoutInactive(allDevices(for: account, activeAndTrusted: true), usage: usage(forName: account))
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
