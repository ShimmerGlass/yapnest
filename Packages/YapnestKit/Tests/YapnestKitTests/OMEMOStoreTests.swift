import CryptoKit
import Foundation
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

struct OMEMOStoreTests {
    let me = JID("me@example.org")!
    let bob = "bob@example.org"

    private func key(_ byte: UInt8) -> Data { Data([0x05] + Array(repeating: byte, count: 32)) }

    @Test func blindTrustUntilVerification() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me)
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

    @Test func rejectsChangedOrCompromisedKeys() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me)
        let phone = SignalAddress(name: bob, deviceId: 1)
        #expect(store.save(identity: phone, publicKeyData: key(1)))
        #expect(!store.isTrusted(identity: phone, publicKeyData: key(9)))
        #expect(!store.save(identity: phone, publicKeyData: key(9)))

        #expect(store.setStatus(.compromisedActive, forIdentity: phone))
        #expect(!store.isTrusted(identity: phone, publicKeyData: key(1)))
    }

    @Test func onlyTrustedActiveDevicesWithSessionsAreUsable() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me)
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

    @Test func usedPreKeysSurviveUntilFlushed() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me)
        #expect(store.storePreKey(Data([1]), withId: 1))
        #expect(store.storePreKey(Data([2]), withId: 2))
        #expect(store.currentPreKeyId() == 2)

        #expect(store.deletePreKey(withId: 1))
        #expect(store.loadPreKey(withId: 1) == Data([1]), "archived messages may still need it")
        #expect(store.flushDeletedPreKeys())
        #expect(store.loadPreKey(withId: 1) == nil)
        #expect(!store.flushDeletedPreKeys())
    }

    @Test func identityIsCreatedOnceAndPersists() throws {
        let database = try AppDatabase.inMemory()
        let first = try OMEMOEncryption(database: database, account: me)
        let id = first.deviceId
        #expect(id != 0)
        let second = try OMEMOEncryption(database: database, account: me)
        #expect(second.deviceId == id)
        #expect(second.store.keyPair()?.publicKey == first.store.keyPair()?.publicKey)
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
