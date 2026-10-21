import CryptoKit
import Foundation

/// XEP-0454: files encrypted with AES-256-GCM before upload, the key and IV
/// carried in the `aesgcm://` URL's fragment inside the OMEMO message.
enum FileCrypto {
    struct Encrypted {
        var data: Data
        /// IV then key, hex, for the URL fragment.
        var fragment: String
    }

    enum Failure: Error {
        case badFragment
        case decryptionFailed
    }

    /// The size and SHA-256 of a file, read in pieces so a large one isn't loaded.
    static func sizeAndHash(of file: URL) throws -> (size: Int64, sha256: Data) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (size, Data(hasher.finalize()))
    }

    static func encrypt(_ data: Data) throws -> Encrypted {
        let key = SymmetricKey(size: .bits256)
        let iv = AES.GCM.Nonce()
        let box = try AES.GCM.seal(data, using: key, nonce: iv)
        let keyData = key.withUnsafeBytes { Data($0) }
        return Encrypted(data: Data(box.ciphertext) + Data(box.tag), fragment: (Data(iv) + keyData).hex)
    }

    /// Encrypts the file at `source` into `destination`: the ciphertext, then
    /// the tag, as `encrypt(_:)` returns them, and the fragment for the URL.
    /// The plaintext is mapped rather than read, and the ciphertext is written
    /// out and dropped before the tag, so no more than one copy of the file is
    /// ever held. Nothing is left at `destination` if it fails.
    static func encrypt(fileAt source: URL, to destination: URL) throws -> String {
        let key = SymmetricKey(size: .bits256)
        let iv = AES.GCM.Nonce()
        do {
            let plain = try Data(contentsOf: source, options: .mappedIfSafe)
            let box = try AES.GCM.seal(plain, using: key, nonce: iv)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.write(contentsOf: box.ciphertext)
            try handle.write(contentsOf: box.tag)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return (Data(iv) + key.withUnsafeBytes { Data($0) }).hex
    }

    /// Accepts the 12-byte IV of the spec and the 16-byte one older clients use.
    static func decrypt(_ data: Data, fragment: String) throws -> Data {
        guard let secret = Data(hex: fragment), secret.count == 44 || secret.count == 48 else { throw Failure.badFragment }
        let ivLength = secret.count - 32
        guard data.count >= 16 else { throw Failure.decryptionFailed }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: secret.prefix(ivLength)),
                ciphertext: data.dropLast(16),
                tag: data.suffix(16),
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: secret.suffix(32)))
        } catch {
            throw Failure.decryptionFailed
        }
    }

    /// `aesgcm://host/path#fragment` for an uploaded `https://host/path`.
    static func aesgcmURL(for url: URL, fragment: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "aesgcm"
        components.fragment = fragment
        return components.url
    }

    /// Where to download an `aesgcm://` URL, and its key. The spec means
    /// HTTPS; `insecure` allows plain HTTP for development servers.
    static func split(_ url: URL, insecure: Bool = false) -> (download: URL, fragment: String)? {
        guard url.scheme?.lowercased() == "aesgcm", var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment else { return nil }
        components.scheme = insecure ? "http" : "https"
        components.fragment = nil
        return components.url.map { ($0, fragment) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
