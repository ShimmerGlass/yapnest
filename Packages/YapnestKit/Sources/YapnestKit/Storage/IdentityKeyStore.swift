import Foundation
import Security

/// This device's OMEMO identity key pair, with the device id it was made
/// for. It's kept out of the database, which device backups include: a
/// backup restored on another phone would carry the private key away from
/// this one, and make that phone this device, with sessions gone back in time.
public struct StoredIdentity: Codable, Equatable, Sendable {
    public var registrationId: UInt32
    public var keyPair: Data

    public init(registrationId: UInt32, keyPair: Data) {
        self.registrationId = registrationId
        self.keyPair = keyPair
    }
}

/// Where the identity is kept. `load` returns nil only when there is none:
/// a keychain that can't be read throws, so that nothing takes it as gone.
public protocol IdentityKeyStore: Sendable {
    func load() throws -> StoredIdentity?
    func save(_ identity: StoredIdentity) throws
}

/// Forgets the identity with the process, for tests and previews. Sessions
/// that stand for the same device share one.
public final class MemoryIdentityKeyStore: IdentityKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: StoredIdentity?

    public init() {}

    public func load() throws -> StoredIdentity? { lock.withLock { identity } }
    public func save(_ identity: StoredIdentity) throws { lock.withLock { self.identity = identity } }
}

/// Keeps the identity in the keychain, one item per account, on this device
/// only, readable by the extensions once the device has been unlocked.
public struct KeychainIdentityKeyStore: IdentityKeyStore {
    public static let service = "yapnest.omemo"

    public var account: JID

    public init(account: JID) {
        self.account = account
    }

    /// Every account's item; with `kSecAttrAccount`, one account's.
    private static var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private var query: [String: Any] {
        Self.serviceQuery.merging([kSecAttrAccount as String: account.description]) { $1 }
    }

    public func load() throws -> StoredIdentity? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(StoredIdentity.self, from: data)
    }

    public func save(_ identity: StoredIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query
        add[kSecValueData as String] = data
        // The notification extension decrypts while the device is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    /// Every account's identity, when signing out.
    public static func deleteAll() {
        SecItemDelete(serviceQuery as CFDictionary)
    }
}
