import CryptoKit
import Foundation
import Security
@preconcurrency import MartinOMEMO
import libsignal
import Testing
@testable import YapnestKit

struct OMEMOStoreTests {
    let me = JID("me@example.org")!
    let bob = "bob@example.org"

    private func key(_ byte: UInt8) -> Data { Data([0x05] + Array(repeating: byte, count: 32)) }

    @Test func blindTrustUntilVerification() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let phone = SignalAddress(name: bob, deviceId: 1)
        #expect(store.isTrusted(identity: phone, publicKeyData: key(1)), "unknown keys are trusted on first use")
        #expect(store.save(identity: phone, publicKeyData: key(1)))
        #expect(store.identities(forName: bob).first?.status == .trustedActive)

        // Once one device is verified, new devices wait for a decision.
        #expect(store.setStatus(.verifiedActive, forIdentity: phone))
        let laptop = SignalAddress(name: bob, deviceId: 2)
        #expect(store.save(identity: laptop, publicKeyData: key(2)))
        #expect(store.identities(forName: bob).first { $0.address.deviceId == 2 }?.status == .undecidedActive)
        // Undecided keys can still be read from, just not encrypted to.
        #expect(store.isTrusted(identity: laptop, publicKeyData: key(2)))
    }

    @Test func aForgottenCompromisedDeviceStaysCompromisedWhenItReturns() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let own = SignalAddress(name: me.description, deviceId: 2)
        #expect(store.save(identity: own, publicKeyData: key(2)))
        _ = store.storeSessionRecord(Data([1]), forAddress: own)
        #expect(store.setStatus(.compromisedActive, forIdentity: own))

        store.forget(deviceIds: [2], of: me.description)
        #expect(!store.containsSessionRecord(forAddress: own))
        _ = store.save(identity: own, publicKeyData: key(2))

        #expect(!store.isTrusted(identity: own, publicKeyData: key(2)))
        #expect(store.status(forName: me.description, deviceId: 2)?.trust == .compromised)
    }

    @Test func rejectsChangedOrCompromisedKeys() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let phone = SignalAddress(name: bob, deviceId: 1)
        #expect(store.save(identity: phone, publicKeyData: key(1)))
        #expect(!store.isTrusted(identity: phone, publicKeyData: key(9)))
        #expect(!store.save(identity: phone, publicKeyData: key(9)))

        #expect(store.setStatus(.compromisedActive, forIdentity: phone))
        #expect(!store.isTrusted(identity: phone, publicKeyData: key(1)))
    }

    @Test func onlyTrustedActiveDevicesWithSessionsAreUsable() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        for id: Int32 in 1...3 {
            let address = SignalAddress(name: bob, deviceId: id)
            #expect(store.save(identity: address, publicKeyData: key(UInt8(id))))
            #expect(store.storeSessionRecord(Data([UInt8(id)]), forAddress: address))
        }
        #expect(store.setStatus(active: false, forIdentity: SignalAddress(name: bob, deviceId: 2)))
        #expect(store.setStatus(.undecidedActive, forIdentity: SignalAddress(name: bob, deviceId: 3)))
        #expect(store.allDevices(for: bob, activeAndTrusted: true) == [1])
        #expect(Set(store.allDevices(for: bob, activeAndTrusted: false)) == [1, 2, 3])
    }

    /// Another sender may have picked the same key, so it stays readable until the flush, but isn't offered again.
    @Test func usedPreKeysWaitForTheFlushAndAreThenRemoved() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        #expect(store.storePreKey(Data([1]), withId: 1))
        #expect(store.storePreKey(Data([2]), withId: 2))
        #expect(store.currentPreKeyId() == 2)

        #expect(store.deletePreKey(withId: 1))
        #expect(store.loadPreKey(withId: 1) == Data([1]))
        #expect(store.isPreKeyDeleted(withId: 1))
        #expect(!store.isPreKeyDeleted(withId: 2))
        #expect(store.loadPreKey(withId: 2) == Data([2]))
        #expect(store.flushDeletedPreKeys())
        #expect(store.loadPreKey(withId: 1) == nil)
        #expect(!store.containsPreKey(withId: 1))
        #expect(!store.isPreKeyDeleted(withId: 1))
        #expect(!store.flushDeletedPreKeys())
    }

    @Test func identityIsCreatedOnceAndPersists() throws {
        let database = try AppDatabase.inMemory(), keys = MemoryIdentityKeyStore()
        let first = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        let id = first.deviceId
        #expect(id != 0)
        let second = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        #expect(second.deviceId == id)
        #expect(second.store.keyPair()?.publicKey == first.store.keyPair()?.publicKey)
    }

    // MARK: Identity outside the database

    @Test func theKeyPairIsNeverWrittenToTheDatabase() throws {
        let database = try AppDatabase.inMemory(), keys = MemoryIdentityKeyStore()
        let omemo = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        #expect(try database.setting(.omemoIdentityKeyPair) == nil)
        let stored = try #require(try keys.load())
        #expect(stored.registrationId == omemo.deviceId)
        #expect(stored.keyPair == (omemo.store.keyPair() as? SignalIdentityKeyPair)?.keyPair)
    }

    /// An install from before keeps its device: the key moves out of the
    /// database, and the same device id and key carry on.
    @Test func aKeyInTheDatabaseMovesToTheKeychain() throws {
        let database = try AppDatabase.inMemory()
        let old = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let pair = try #require((old.store.keyPair() as? SignalIdentityKeyPair)?.keyPair)
        try database.setSetting(.omemoIdentityKeyPair, pair.base64EncodedString())
        #expect(old.store.storeSessionRecord(Data([1]), forAddress: SignalAddress(name: bob, deviceId: 7)))

        let keys = MemoryIdentityKeyStore()
        let upgraded = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        #expect(upgraded.deviceId == old.deviceId)
        #expect(upgraded.store.keyPair()?.publicKey == old.store.keyPair()?.publicKey)
        #expect(try keys.load() == StoredIdentity(registrationId: old.deviceId, keyPair: pair))
        #expect(try database.setting(.omemoIdentityKeyPair) == nil)
        #expect(upgraded.store.sessionRecord(forAddress: SignalAddress(name: bob, deviceId: 7)) == Data([1]), "a move isn't a restore")
    }

    /// The moved key leaves no copy in the files a backup takes: its page is
    /// zeroed, and the file's older copy of the page is overwritten.
    @Test func aMovedKeyLeavesNoTraceInTheDatabaseFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "db.sqlite")
        let database = try AppDatabase.open(at: url)
        let old = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let pair = try #require((old.store.keyPair() as? SignalIdentityKeyPair)?.keyPair)
        let encoded = pair.base64EncodedString()
        try database.setSetting(.omemoIdentityKeyPair, encoded)
        try database.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        let files = ["", "-wal"].map { URL(filePath: url.path + $0) }
        #expect(files.contains { (try? Data(contentsOf: $0))?.range(of: Data(encoded.utf8)) != nil }, "the key starts out on disk")

        _ = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        for file in files {
            #expect((try? Data(contentsOf: file))?.range(of: Data(encoded.utf8)) == nil, "\(file.lastPathComponent) still holds the key")
        }
    }

    /// Build 7 installed over build 10's data found no key in the database
    /// and made another device; build 10 then moved that key over the
    /// keychain's and became a new device on the old one's sessions, and
    /// contacts who weren't subscribed to us never encrypted to it. The
    /// keychain's device, which contacts know, carries on instead, and the
    /// older build's is noted for removal from the list.
    @Test func aDeviceAnOlderBuildMadeGivesWayToTheKeychainsOne() throws {
        let database = try AppDatabase.inMemory(), keys = MemoryIdentityKeyStore()
        let kept = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        let bobsDevice = SignalAddress(name: bob, deviceId: 7)
        #expect(kept.store.storeSessionRecord(Data([1]), forAddress: bobsDevice))
        let keptSigned = try Self.signedPreKey(1, by: kept)
        #expect(kept.store.storeSignedPreKey(keptSigned, withId: 1))
        // What build 7 left: its own key and id in the database, and a signed
        // prekey signed with that key under the next id.
        let older = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let olderPair = try #require((older.store.keyPair() as? SignalIdentityKeyPair)?.keyPair)
        try database.setSetting(.omemoIdentityKeyPair, olderPair.base64EncodedString())
        try database.setSetting(.omemoRegistrationId, String(older.deviceId))
        #expect(kept.store.storeSignedPreKey(try Self.signedPreKey(2, by: older), withId: 2))

        let upgraded = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        #expect(upgraded.deviceId == kept.deviceId)
        #expect(upgraded.store.keyPair()?.publicKey == kept.store.keyPair()?.publicKey)
        #expect(try keys.load()?.registrationId == kept.deviceId)
        #expect(try database.setting(.omemoRegistrationId) == String(kept.deviceId))
        #expect(try database.setting(.omemoIdentityKeyPair) == nil)
        #expect(upgraded.store.sessionRecord(forAddress: bobsDevice) == Data([1]), "the kept device's sessions stay")
        #expect(upgraded.store.loadSignedPreKey(withId: 1) == keptSigned, "for sessions started from the kept device's bundle")
        // The older build's, signed with its key, is no longer the newest,
        // which is what the bundle publishes.
        #expect(upgraded.store.countSignedPreKeys() == 3)
        let newest = try #require(upgraded.store.loadSignedPreKey(withId: 3).flatMap { SignalSignedPreKey(fromSerializedData: $0) })
        let keptPair = try #require(kept.store.keyPair() as? SignalIdentityKeyPair)
        #expect(Self.verifies(newest, by: keptPair))
        #expect(upgraded.store.replacedDeviceIds() == [Int32(bitPattern: older.deviceId)])
    }

    /// The keychain outlives a deleted app. A build from before the keychain,
    /// installed afresh after that, made the device in use; the key left
    /// from the install before isn't anyone's device now, so it gives way.
    @Test func aKeyLeftByADeletedInstallGivesWayToTheDevicesOwn() throws {
        let keys = MemoryIdentityKeyStore()
        _ = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: keys)
        let database = try AppDatabase.inMemory()
        let fresh = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let freshPair = try #require((fresh.store.keyPair() as? SignalIdentityKeyPair)?.keyPair)
        try database.setSetting(.omemoIdentityKeyPair, freshPair.base64EncodedString())
        #expect(fresh.store.storeSignedPreKey(try Self.signedPreKey(1, by: fresh), withId: 1))

        let upgraded = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        #expect(upgraded.deviceId == fresh.deviceId)
        #expect(try keys.load() == StoredIdentity(registrationId: fresh.deviceId, keyPair: freshPair))
        #expect(upgraded.store.replacedDeviceIds().isEmpty)
    }

    /// A signed prekey as `owner`'s registration makes it.
    private static func signedPreKey(_ id: UInt32, by owner: OMEMOEncryption) throws -> Data {
        let pair = try #require(owner.store.keyPair())
        return try #require(owner.module.signalContext.generateSignedPreKey(withIdentity: pair, signedPreKeyId: id)?.serializedData)
    }

    /// Whether `signed` is signed with `identity`'s key, which a contact
    /// checks before starting a session from the bundle that has it.
    private static func verifies(_ signed: SignalSignedPreKey, by identity: SignalIdentityKeyPair) -> Bool {
        guard let message = signed.publicKeyData, let keyData = identity.publicKey,
              let key = SignalIdentityKey.publicKey(from: keyData) else { return false }
        let signature = signed.signature
        return message.withUnsafeBytes { m in
            signature.withUnsafeBytes { s in
                curve_verify_signature(key, m.baseAddress!.assumingMemoryBound(to: UInt8.self), message.count, s.baseAddress!.assumingMemoryBound(to: UInt8.self), signature.count)
            }
        } == 1
    }

    /// A move cut short after the keychain took the key, with the key still
    /// in the database, is finished, not taken for another device.
    @Test func aMoveCutShortIsFinished() throws {
        let database = try AppDatabase.inMemory(), keys = MemoryIdentityKeyStore()
        let omemo = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        let pair = try #require((omemo.store.keyPair() as? SignalIdentityKeyPair)?.keyPair)
        try database.setSetting(.omemoIdentityKeyPair, pair.base64EncodedString())
        #expect(omemo.store.storeSignedPreKey(Data([3]), withId: 1))

        let again = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        #expect(again.deviceId == omemo.deviceId)
        #expect(try database.setting(.omemoIdentityKeyPair) == nil)
        #expect(again.store.loadSignedPreKey(withId: 1) == Data([3]))
        #expect(again.store.replacedDeviceIds().isEmpty)
    }

    /// A key that can't be moved, with no device id beside it, is erased all the same.
    @Test func aKeyThatCantBeMovedIsErasedAnyway() throws {
        let database = try AppDatabase.inMemory()
        try database.setSetting(.omemoIdentityKeyPair, Data(repeating: 7, count: 33).base64EncodedString())
        _ = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        #expect(try database.setting(.omemoIdentityKeyPair) == nil)
    }

    /// A database restored from a backup, without the keychain that held its
    /// key: a new device, its predecessor's sessions and prekeys gone, the
    /// user's trust in contacts' devices kept.
    @Test func aDatabaseWithoutItsKeyBecomesANewDevice() throws {
        let database = try AppDatabase.inMemory()
        let old = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let bobsDevice = SignalAddress(name: bob, deviceId: 7)
        #expect(old.store.storeSessionRecord(Data([1]), forAddress: bobsDevice))
        #expect(old.store.storePreKey(Data([2]), withId: 1))
        #expect(old.store.storeSignedPreKey(Data([3]), withId: 1))
        #expect(old.store.save(identity: bobsDevice, publicKeyData: key(0x07)))

        let restored = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        #expect(restored.deviceId != old.deviceId)
        #expect(restored.store.keyPair()?.publicKey != old.store.keyPair()?.publicKey)
        #expect(restored.store.sessionRecord(forAddress: bobsDevice) == nil)
        #expect(restored.store.loadPreKey(withId: 1) == nil)
        #expect(restored.store.loadSignedPreKey(withId: 1) == nil)
        #expect(restored.store.isTrusted(identity: bobsDevice, publicKeyData: key(0x07)))
    }

    /// The app and an extension setting up a new database at the same moment,
    /// each over its own connection as in two processes, end up as one
    /// device: the key in the keychain and the id in the database match.
    @Test func twoProcessesSettingUpAtOnceMakeOneDevice() async throws {
        for _ in 0..<20 {
            let root = FileManager.default.temporaryDirectory.appending(path: "race-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appending(path: "db.sqlite")
            let keys = MemoryIdentityKeyStore()
            let (app, nse) = (try AppDatabase.open(at: url), try AppDatabase.open(at: url))
            async let first = Task.detached { [me] in try OMEMOEncryption(database: app, account: me, identityKeys: keys).deviceId }.value
            async let second = Task.detached { [me] in try OMEMOEncryption(database: nse, account: me, identityKeys: keys).deviceId }.value
            let (a, b) = try await (first, second)
            #expect(a == b)
            #expect(try keys.load()?.registrationId == a)
            #expect(try app.setting(.omemoRegistrationId) == String(a))
        }
    }

    /// A session over an install's database, given no store, keeps the
    /// identity in the keychain rather than in memory, where it would be a
    /// new device at every launch.
    @Test func aSessionOnDiskDefaultsToTheKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let onDisk = try AppDatabase.open(at: root.appending(path: "db.sqlite"))
        #expect(XMPPSession.identityKeys(for: me, in: onDisk) is KeychainIdentityKeyStore)
        let inMemory = try AppDatabase.inMemory()
        #expect(XMPPSession.identityKeys(for: me, in: inMemory) as? MemoryIdentityKeyStore === inMemory.localIdentityKeys)
    }

    /// A key left in the keychain by an earlier install doesn't go with a
    /// new database's device.
    @Test func aStaleKeyIsReplacedForANewDatabase() throws {
        let keys = MemoryIdentityKeyStore()
        let earlier = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: keys)
        let fresh = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: keys)
        #expect(fresh.store.keyPair()?.publicKey != earlier.store.keyPair()?.publicKey)
        #expect(try keys.load()?.registrationId == fresh.deviceId)
    }

    /// A keychain that can't be read, as before the first unlock, isn't a
    /// missing key: nothing is wiped or replaced.
    @Test func anUnreadableKeychainLeavesTheDeviceAlone() throws {
        let database = try AppDatabase.inMemory(), keys = MemoryIdentityKeyStore()
        let omemo = try OMEMOEncryption(database: database, account: me, identityKeys: keys)
        let bobsDevice = SignalAddress(name: bob, deviceId: 7)
        #expect(omemo.store.storeSessionRecord(Data([1]), forAddress: bobsDevice))
        let identity = try keys.load()

        #expect(throws: KeychainError.self) { try OMEMOEncryption(database: database, account: me, identityKeys: LockedIdentityKeyStore()) }
        #expect(try database.setting(.omemoRegistrationId) == String(omemo.deviceId))
        #expect(omemo.store.sessionRecord(forAddress: bobsDevice) == Data([1]))
        #expect(try keys.load() == identity)
    }

    @Test func fingerprintDropsTypeByte() {
        #expect(OMEMOStore.fingerprint(of: key(0xab)) == String(repeating: "ab", count: 32))
    }
}

struct CryptoKitAESGCMTests {
    let engine = CryptoKitAESGCM()
    let key = Data(repeating: 7, count: 16)
    let plaintext = Data("hello 🔐".utf8)

    @Test func roundTrip() {
        let iv = Data(repeating: 1, count: 12)
        var ciphertext = Data(), tag = Data(), output = Data()
        #expect(engine.encrypt(iv: iv, key: key, message: plaintext, output: &ciphertext, tag: &tag))
        #expect(tag.count == 16)
        #expect(engine.decrypt(iv: iv, key: key, encoded: ciphertext, auth: tag, output: &output))
        #expect(output == plaintext)

        var tampered = ciphertext
        tampered[0] ^= 1
        #expect(!engine.decrypt(iv: iv, key: key, encoded: tampered, auth: tag, output: &output))
    }

    /// Older clients used 16-byte IVs and put the tag after the payload.
    @Test func legacyIVAndAppendedTag() throws {
        let iv = Data(repeating: 2, count: 16)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        var output = Data()
        #expect(engine.decrypt(iv: iv, key: key, encoded: box.ciphertext + box.tag, auth: nil, output: &output))
        #expect(output == plaintext)
    }
}

struct TrustTests {
    @Test func verifyingOneDeviceEndsBlindTrustForTheOthers() throws {
        let bob = JID("bob@example.org")!
        let session = try makeSession(JID("me@example.org")!)
        for id: Int32 in 1...2 {
            _ = session.omemoStoreForTesting.save(identity: SignalAddress(name: bob.description, deviceId: id), publicKeyData: Data([0x05] + Array(repeating: UInt8(id), count: 32)))
        }
        #expect(session.devices(of: bob).map(\.trust) == [.trusted, .trusted])

        session.setTrust(.verified, for: try #require(session.devices(of: bob).first { $0.id == 1 }))
        let trust = Dictionary(uniqueKeysWithValues: session.devices(of: bob).map { ($0.id, $0.trust) })
        #expect(trust == [1: .verified, 2: .undecided])
    }

    @Test func demotedDevicesAreTheTrustedOnesVerifyingLeavesOut() throws {
        let bob = JID("bob@example.org")!
        let session = try makeSession(JID("me@example.org")!)
        for id: Int32 in 1...3 {
            _ = session.omemoStoreForTesting.save(identity: SignalAddress(name: bob.description, deviceId: id), publicKeyData: Data([0x05] + Array(repeating: UInt8(id), count: 32)))
        }
        let first = try #require(session.devices(of: bob).first { $0.id == 1 })
        #expect(Set(session.devicesDemoted(bySetting: .verified, for: first).map(\.id)) == [2, 3])
        #expect(session.devicesDemoted(bySetting: .trusted, for: first).isEmpty)

        session.setTrust(.verified, for: first)
        // Nothing left to demote: the others are undecided already.
        #expect(session.devicesDemoted(bySetting: .verified, for: first).isEmpty)
    }

    @Test func markingCompromisedEndsItsSession() throws {
        let bob = JID("bob@example.org")!
        let session = try makeSession(JID("me@example.org")!)
        let store = session.omemoStoreForTesting
        for id: Int32 in 1...2 {
            let address = SignalAddress(name: bob.description, deviceId: id)
            _ = store.save(identity: address, publicKeyData: Data([0x05] + Array(repeating: UInt8(id), count: 32)))
            _ = store.storeSessionRecord(Data([1]), forAddress: address)
        }
        session.setTrust(.compromised, for: try #require(session.devices(of: bob).first { $0.id == 1 }))
        #expect(!store.containsSessionRecord(forAddress: SignalAddress(name: bob.description, deviceId: 1)))
        #expect(store.containsSessionRecord(forAddress: SignalAddress(name: bob.description, deviceId: 2)))
    }
}

/// A keychain before the device's first unlock.
private struct LockedIdentityKeyStore: IdentityKeyStore {
    func load() throws -> StoredIdentity? { throw KeychainError(status: errSecInteractionNotAllowed) }
    func save(_ identity: StoredIdentity) throws { throw KeychainError(status: errSecInteractionNotAllowed) }
}
