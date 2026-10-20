import Foundation
import GRDB
@preconcurrency import MartinOMEMO

/// Keeps the account's OMEMO keys, sessions and peer identities in its
/// database.
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
    private let account: String
    private let lock = NSLock()
    private var cachedKeyPair: SignalIdentityKeyPair?
    private var cachedRegistrationId: UInt32?
    /// The clock, so tests can move it.
    private let now: @Sendable () -> Date

    init(database: AppDatabase, account: JID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
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

    /// Creates this device's identity and device id on first use.
    func setUpIdentityIfNeeded(context: SignalContext) throws {
        guard keyPair() == nil else { return }
        guard let keyPair = SignalIdentityKeyPair.generateKeyPair(context: context), let data = keyPair.keyPair else {
            throw OMEMOError.keyGenerationFailed
        }
        let registrationId = context.generateRegistrationId()
        guard registrationId != 0 else { throw OMEMOError.keyGenerationFailed }
        try database.setSetting(.omemoIdentityKeyPair, data.base64EncodedString())
        try database.setSetting(.omemoRegistrationId, String(registrationId))
        lock.withLock {
            cachedKeyPair = nil
            cachedRegistrationId = nil
        }
    }

    func keyPair() -> SignalIdentityKeyPairProtocol? {
        lock.withLock {
            if cachedKeyPair == nil,
               let encoded = try? database.setting(.omemoIdentityKeyPair),
               let data = Data(base64Encoded: encoded) {
                cachedKeyPair = SignalIdentityKeyPair(fromKeyPairData: data)
            }
            return cachedKeyPair
        }
    }

    func localRegistrationId() -> UInt32 {
        lock.withLock {
            if cachedRegistrationId == nil {
                cachedRegistrationId = (try? database.setting(.omemoRegistrationId)).flatMap { UInt32($0) }
            }
            return cachedRegistrationId ?? 0
        }
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

    func loadPreKey(withId id: UInt32) -> Data? {
        read { db in try Data.fetchOne(db, sql: "SELECT data FROM omemoPreKey WHERE id = ?", arguments: [id]) } ?? nil
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

    func countSignedPreKeys() -> Int {
        (read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM omemoSignedPreKey") } ?? nil) ?? 0
    }

    func loadSignedPreKey(withId id: UInt32) -> Data? {
        read { db in try Data.fetchOne(db, sql: "SELECT data FROM omemoSignedPreKey WHERE id = ?", arguments: [id]) } ?? nil
    }

    func storeSignedPreKey(_ data: Data, withId id: UInt32) -> Bool {
        write { db in try db.execute(sql: "INSERT OR REPLACE INTO omemoSignedPreKey (id, data) VALUES (?, ?)", arguments: [id, data]) }
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
            let hasVerified = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM omemoIdentity WHERE name = ? AND status IN (?, ?))",
                                                arguments: [address.name, IdentityStatus.verifiedActive.rawValue, IdentityStatus.verifiedInactive.rawValue]) ?? false
            let status: IdentityStatus = hasVerified ? .undecidedActive : .trustedActive
            try db.execute(sql: "INSERT INTO omemoIdentity (name, deviceId, key, status, firstSeen) VALUES (?, ?, ?, ?, ?)",
                           arguments: [address.name, address.deviceId, key, status.rawValue, now()])
        }
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
    /// is met as new.
    func forget(deviceIds: [Int32], of name: String) {
        _ = write { db in
            for id in deviceIds {
                try db.execute(sql: "DELETE FROM omemoSession WHERE name = ? AND deviceId = ?", arguments: [name, id])
                try db.execute(sql: "DELETE FROM omemoIdentity WHERE name = ? AND deviceId = ?", arguments: [name, id])
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
        if address.name == account, UInt32(bitPattern: address.deviceId) == localRegistrationId() {
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
}
