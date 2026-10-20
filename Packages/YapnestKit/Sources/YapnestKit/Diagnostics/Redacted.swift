import CryptoKit
import Foundation

/// An identifier (an address, a message id, a room) as a short keyed hash:
/// the same value gives the same id within this install, so lines can be
/// matched, but nothing outside it can tell what it was. The key is made
/// once per install, kept in the app group's defaults, and never logged or
/// exported.
public struct Redacted: Sendable, Equatable {
    public let hex: String

    public static func id(_ value: String) -> Redacted {
        id(value, key: installKey)
    }

    static func id(_ value: String, key: SymmetricKey) -> Redacted {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return Redacted(hex: Data(mac.prefix(4)).hex)
    }

    private static let defaultsKey = "yapnest.diagnostics.redactionKey"
    /// Makes the key now, so the extensions find it rather than each making
    /// their own on first use.
    public static func prepare() {
        _ = installKey
    }

    /// Two processes can make a key at once; whichever wrote last is kept, and
    /// both read it back.
    static let installKey: SymmetricKey = {
        let defaults = SharedContainer.defaults
        if let data = defaults.data(forKey: defaultsKey), data.count == 32 {
            return SymmetricKey(data: data)
        }
        defaults.set(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, forKey: defaultsKey)
        if let data = defaults.data(forKey: defaultsKey), data.count == 32 {
            return SymmetricKey(data: data)
        }
        return SymmetricKey(size: .bits256)
    }()
}
