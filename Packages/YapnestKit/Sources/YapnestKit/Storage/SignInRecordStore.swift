import Foundation
@preconcurrency import Martin
import Security

/// The mechanism of the strongest sign-in that has worked for an account
/// (`SignInPinning`), which a sign-in is never allowed to fall below. It is
/// shared by the app and both extensions, as any of them may be the one a
/// downgrading server meets first.
public protocol SignInRecordStore: Sendable {
    func load() -> String?
    func save(_ mechanism: String?)
}

/// Forgets the record with the process; for tests and previews.
public final class MemorySignInRecordStore: SignInRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var mechanism: String?

    public init(_ mechanism: String? = nil) {
        self.mechanism = mechanism
    }

    public func load() -> String? { lock.withLock { mechanism } }
    public func save(_ mechanism: String?) { lock.withLock { self.mechanism = mechanism } }
}

/// Keeps the record in the keychain, one item per account.
public struct KeychainSignInRecordStore: SignInRecordStore {
    public static let service = "yapnest.signin-record"

    public var account: JID

    public init(account: JID) {
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.description,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ mechanism: String?) {
        SecItemDelete(query as CFDictionary)
        guard let mechanism else { return }
        var query = query
        query[kSecValueData as String] = Data(mechanism.utf8)
        // The notification extension signs in while the device is locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Every account's record, when signing out.
    public static func deleteAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }
}
