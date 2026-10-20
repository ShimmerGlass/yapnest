import Foundation
import Testing
import libsignal
@preconcurrency import MartinOMEMO
@testable import YapnestKit

/// Pins the reference counting of the fork's libsignal wrappers (Vendor/README.md, MartinOMEMO).
///
/// libsignal's types are opaque in Swift, but each one starts with `unsigned int ref_count`
/// (`signal_type_base` in `signal_protocol_internal.h`), so these tests read the first four bytes
/// through the pointer. That is acceptable here because the tests only observe, never write, and
/// the layout is fixed by the pinned libsignal checkout; a change to it would fail the counts
/// loudly rather than quietly.
struct OMEMOSignalMemoryTests {
    private func refCount(_ pointer: OpaquePointer) -> UInt32 {
        UnsafeRawPointer(pointer).load(as: UInt32.self)
    }

    /// A context the way `OMEMOEncryption` makes one. The store backs the callbacks only.
    private func makeContext() throws -> (SignalContext, SignalStorage, OMEMOStore) {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: JID("me@example.org")!)
        let storage = SignalStorage(sessionStore: store, preKeyStore: store, signedPreKeyStore: store, identityKeyStore: store, senderKeyStore: store)
        let context = try #require(SignalContext(withStorage: storage))
        return (context, storage, store)
    }

    /// The raw pointer inside a pre-key wrapper, which keeps it private.
    private func rawKey(_ wrapper: AnyObject, _ name: String) -> OpaquePointer? {
        Mirror(reflecting: wrapper).children.first { $0.label == name }?.value as? OpaquePointer
    }

    /// The pair holds one reference to each key. The wrapper's own `SignalIdentityKey` part takes a
    /// second one on the public key so that it can outlive the pair, so the public key counts 2 and
    /// the private key, which the pair alone keeps alive, counts 1.
    private func expectOwnedOnce(_ pair: SignalIdentityKeyPair, sourceLocation: SourceLocation = #_sourceLocation) {
        let raw = pair.keyPairPointer
        #expect(raw != nil, sourceLocation: sourceLocation)
        guard let raw else { return }
        #expect(refCount(raw) == 1, "pair", sourceLocation: sourceLocation)
        #expect(refCount(pair.publicKeyPointer) == 2, "public key", sourceLocation: sourceLocation)
        #expect(refCount(pair.privateKeyPointer) == 1, "private key", sourceLocation: sourceLocation)
    }

    @Test func identityPairOwnsExactlyOneReference() throws {
        let (context, _, _) = try makeContext()
        let first = try #require(SignalIdentityKeyPair.generateKeyPair(context: context))
        let data = try #require(first.keyPair)
        expectOwnedOnce(first)

        for _ in 0..<200 {
            // What OMEMOStore.keyPair() does with the stored bytes.
            let loaded = try #require(SignalIdentityKeyPair(fromKeyPairData: data))
            expectOwnedOnce(loaded)
            #expect(loaded.keyPair == data)
            #expect(loaded.publicKey == first.publicKey)
            #expect(loaded.privateKey == first.privateKey)

            // What setUpIdentityIfNeeded does on first use.
            let generated = try #require(SignalIdentityKeyPair.generateKeyPair(context: context))
            expectOwnedOnce(generated)

            // Rebuilt from the separate halves.
            let rebuilt = try #require(SignalIdentityKeyPair(publicKey: first.publicKey, privateKey: first.privateKey))
            expectOwnedOnce(rebuilt)
            #expect(rebuilt.keyPair == data)
        }
    }

    @Test func releasedWrappersGiveTheirReferencesBack() throws {
        let (context, _, _) = try makeContext()
        let owner = try #require(SignalIdentityKeyPair.generateKeyPair(context: context))
        let pair = try #require(owner.keyPairPointer)
        let publicKey = owner.publicKeyPointer
        #expect(refCount(pair) == 1)
        #expect(refCount(publicKey) == 2)

        // A second wrapper of the same pair takes references and gives them back on release.
        var second: SignalIdentityKeyPair? = SignalIdentityKeyPair(withKeyPair: pair)
        #expect(refCount(pair) == 2)
        #expect(refCount(publicKey) == 3)
        second = nil
        #expect(refCount(pair) == 1)
        #expect(refCount(publicKey) == 2)

        // A bare identity key, as the store makes for a remote device.
        var bare: SignalIdentityKey? = SignalIdentityKey(publicKeyPointer: publicKey)
        #expect(refCount(publicKey) == 3)
        bare = nil
        #expect(refCount(publicKey) == 2)

        // One built from bytes owns the decoded key alone, so there is nothing left to observe;
        // a pointer we hold keeps the key readable and shows its single reference.
        var fromBytes: SignalIdentityKey? = SignalIdentityKey(publicKey: owner.publicKey)
        let decoded = try #require(fromBytes?.publicKeyPointer)
        signal_type_ref(decoded)
        #expect(refCount(decoded) == 2)
        fromBytes = nil
        #expect(refCount(decoded) == 1)
        signal_type_unref(decoded)
        _ = second
        _ = bare
    }

    @Test func preKeysAreOwnedOnceWhenGeneratedAndLoaded() throws {
        let (context, _, _) = try makeContext()
        for batch in 0..<20 {
            let keys = context.generatePreKeys(withStartingPreKeyId: UInt32(1 + batch * 10), count: 10)
            #expect(keys.count == 10)
            for key in keys {
                // The generated list is freed, leaving the wrapper as the only owner.
                let raw = try #require(rawKey(key, "preKey"))
                #expect(refCount(raw) == 1)
                let data = try #require(key.serializedData)
                for _ in 0..<5 {
                    let loaded = try #require(SignalPreKey(fromSerializedData: data))
                    let loadedRaw = try #require(rawKey(loaded, "preKey"))
                    #expect(refCount(loadedRaw) == 1)
                    #expect(loaded.preKeyId == key.preKeyId)
                    #expect(loaded.serializedData == data)
                }
                #expect(refCount(raw) == 1)
            }
        }
    }

    @Test func signedPreKeysAreOwnedOnce() throws {
        let (context, _, _) = try makeContext()
        let identity = try #require(SignalIdentityKeyPair.generateKeyPair(context: context))
        for round in 0..<20 {
            let signed = try #require(context.generateSignedPreKey(withIdentity: identity, signedPreKeyId: UInt32(round + 1)))
            let raw = try #require(rawKey(signed, "signedPreKey"))
            #expect(refCount(raw) == 1)
            // Signing reads the identity pair without keeping it.
            expectOwnedOnce(identity)

            let data = try #require(signed.serializedData)
            let loaded = try #require(SignalSignedPreKey(fromSerializedData: data))
            #expect(refCount(try #require(rawKey(loaded, "signedPreKey"))) == 1)
            #expect(loaded.signature == signed.signature)
        }
    }

    @Test func keysReadFromManyThreadsAtOnce() throws {
        let (context, _, _) = try makeContext()
        for _ in 0..<50 {
            let pair = try #require(SignalIdentityKeyPair.generateKeyPair(context: context))
            let expected = (pair.publicKey, pair.privateKey, pair.keyPair)
            let mismatches = Mismatches()
            // The accessors used to fill lazy caches without a lock. Only reads: libsignal's
            // reference counts are not atomic, so taking references here would race by design.
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let read = (pair.publicKey, pair.privateKey, pair.keyPair)
                if read != expected || pair.keyPairPointer == nil || pair.publicKeyPointer != pair.publicKeyPointer {
                    mismatches.add()
                }
            }
            #expect(mismatches.count == 0)
            #expect(expected.0 != nil && expected.1 != nil && expected.2 != nil)
            expectOwnedOnce(pair)
        }
    }
}

private final class Mismatches: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
