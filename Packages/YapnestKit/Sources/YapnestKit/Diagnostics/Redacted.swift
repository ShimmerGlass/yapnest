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

    static let defaultsKey = "yapnest.diagnostics.redactionKey"
    /// Makes the key now, so the extensions find it rather than each making
    /// their own on first use.
    public static func prepare() {
        _ = installKey
    }

    /// The app and both extensions share one key, in a file of the app group.
    /// Whoever gets there first publishes it whole and the rest read that one.
    static let installKey: SymmetricKey = loadKey(in: SharedContainer.url, defaults: SharedContainer.defaults)

    static let keyFileName = "redaction.key"

    /// Reads the key from `directory`, making it if there is none. An install
    /// that kept its key in `defaults` before the file existed carries that
    /// key over, so the ids it logged stay the same.
    static func loadKey(in directory: URL, defaults: UserDefaults) -> SymmetricKey {
        let file = directory.appending(path: keyFileName)
        if let key = readKey(file) { return key }
        let candidate = defaults.data(forKey: defaultsKey).flatMap { $0.count == 32 ? $0 : nil }
            ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Linking a finished file into place fails if one is already there,
        // and no one can read it half written, as they could if the key were
        // written to its own name.
        let temporary = directory.appending(path: keyFileName + "." + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temporary) }
        if (try? candidate.write(to: temporary)) != nil {
            _ = link(temporary.path, file.path)
        }
        return readKey(file) ?? SymmetricKey(data: candidate)
    }

    private static func readKey(_ file: URL) -> SymmetricKey? {
        guard let data = try? Data(contentsOf: file), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
