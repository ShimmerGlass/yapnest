import Foundation
import Security

/// Stores account credentials in the keychain. With an access group, the
/// app and its extensions share them.
public struct CredentialStore: Sendable {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "yapnest.account", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private struct Stored: Codable {
        var jid: String
        var password: String
        var host: String?
        var port: Int?
        var disableTLS: Bool?
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "primary",
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() throws -> XMPPSession.Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard let jid = JID(stored.jid) else { return nil }
        return .init(jid: jid, password: stored.password, host: stored.host, port: stored.port, disableTLS: stored.disableTLS ?? false)
    }

    private func encoded(_ credentials: XMPPSession.Credentials) throws -> Data {
        try JSONEncoder().encode(Stored(
            jid: credentials.jid.description,
            password: credentials.password,
            host: credentials.host,
            port: credentials.port,
            disableTLS: credentials.disableTLS,
        ))
    }

    public func save(_ credentials: XMPPSession.Credentials) throws {
        let data = try encoded(credentials)
        try delete()
        var query = baseQuery
        query[kSecValueData as String] = data
        // Readable by the notification extension while the device is locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Replaces the stored credentials in place. Unlike `save`, which deletes
    /// first so the item lands in the current access group, a failure here
    /// leaves the old item: after a password change the device mustn't be
    /// left with no password at all. Falls back to `save` when nothing is stored.
    public func update(_ credentials: XMPPSession.Credentials) throws {
        let data = try encoded(credentials)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { return try save(credentials) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public var status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
