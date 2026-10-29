import Foundation
import Security
import Testing
import YapnestKit

/// The OMEMO identity in the real keychain, which only a signed process can
/// reach: stays on this device, readable once it has been unlocked (by the
/// notification extension too), and gone on sign-out.
@Suite(.serialized)
struct IdentityKeychainTests {
    let store = KeychainIdentityKeyStore(account: JID("identity-test-\(UUID().uuidString.prefix(8))@example.org")!)

    @Test func savesReplacesAndForgets() throws {
        defer { KeychainIdentityKeyStore.deleteAll() }
        #expect(try store.load() == nil)
        let first = StoredIdentity(registrationId: 1, keyPair: Data([1, 2, 3]))
        try store.save(first)
        #expect(try store.load() == first)
        let second = StoredIdentity(registrationId: 2, keyPair: Data([4, 5, 6]))
        try store.save(second)
        #expect(try store.load() == second)

        KeychainIdentityKeyStore.deleteAll()
        #expect(try store.load() == nil)
    }

    /// An older build once moved its key over the one contacts knew, and
    /// nothing could bring that device back.
    @Test func aReplacedIdentityIsKeptAside() throws {
        defer { KeychainIdentityKeyStore.deleteAll() }
        let first = StoredIdentity(registrationId: 1, keyPair: Data([1]))
        try store.save(first)
        // Saving the same one again keeps nothing aside.
        try store.save(first)
        #expect(try store.superseded() == [])

        let identities = (2...5).map { StoredIdentity(registrationId: UInt32($0), keyPair: Data([UInt8($0)])) }
        for identity in identities { try store.save(identity) }
        #expect(try store.load() == identities.last)
        // Newest first, three at most.
        #expect(try store.superseded().map(\.registrationId) == [4, 3, 2])

        KeychainIdentityKeyStore.deleteAll()
        #expect(try store.superseded() == [])
    }

    @Test func staysOnThisDeviceAndOpensAfterTheFirstUnlock() throws {
        defer { KeychainIdentityKeyStore.deleteAll() }
        try store.save(StoredIdentity(registrationId: 1, keyPair: Data([1])))
        // Replacing it keeps the item, and so its accessibility.
        try store.save(StoredIdentity(registrationId: 2, keyPair: Data([2])))
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityKeyStore.service,
            kSecAttrAccount as String: store.account.description,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
    }
}
