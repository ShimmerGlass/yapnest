import Foundation
@preconcurrency import Martin
import Security

/// Where a session keeps its XEP-0484 FAST token, which signs in without
/// the password. Each client (the app, the notification extension, the
/// share extension) has its own, so one rotating its token never invalidates
/// another's.
public protocol FastTokenStore: Sendable {
    func load() -> Sasl2Module.FastToken?
    func save(_ token: Sasl2Module.FastToken?)
}

/// Forgets the token with the process; for tests and previews.
public final class MemoryFastTokenStore: FastTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: Sasl2Module.FastToken?

    public init() {}

    public func load() -> Sasl2Module.FastToken? { lock.withLock { token } }
    public func save(_ token: Sasl2Module.FastToken?) { lock.withLock { self.token = token } }
}

/// Keeps tokens in the keychain, one item per client, alongside the
/// account's credentials.
public struct KeychainFastTokenStore: FastTokenStore {
    public static let service = "yapnest.fast"

    /// Which client's token: the session's user-agent id.
    public var client: String

    public init(client: String) {
        self.client = client
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: client,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() -> Sasl2Module.FastToken? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Sasl2Module.FastToken.self, from: data)
    }

    public func save(_ token: Sasl2Module.FastToken?) {
        SecItemDelete(query as CFDictionary)
        guard let token, let data = try? JSONEncoder().encode(token) else { return }
        var query = query
        query[kSecValueData as String] = data
        // The notification extension signs in while the device is locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Every client's token, when signing out.
    public static func deleteAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }
}
