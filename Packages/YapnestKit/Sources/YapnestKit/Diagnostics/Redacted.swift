import CryptoKit
import Foundation
import os

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
        return Redacted(hex: mac.prefix(4).map { String(format: "%02x", $0) }.joined())
    }

    private static let defaultsKey = "yapnest.diagnostics.redactionKey"
    private static let cached = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)

    static var installKey: SymmetricKey {
        cached.withLock { cached in
            if let cached { return cached }
            let defaults = SharedContainer.defaults
            let key: SymmetricKey
            if let data = defaults.data(forKey: defaultsKey), data.count == 32 {
                key = SymmetricKey(data: data)
            } else {
                key = SymmetricKey(size: .bits256)
                defaults.set(key.withUnsafeBytes { Data($0) }, forKey: defaultsKey)
            }
            cached = key
            return key
        }
    }
}
