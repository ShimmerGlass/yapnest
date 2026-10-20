import CryptoKit
import Foundation
@preconcurrency import MartinOMEMO

/// AES-GCM for OMEMO payloads, on CryptoKit.
struct CryptoKitAESGCM: AES_GCM_Engine {
    static let tagLength = 16

    func encrypt(iv: Data, key: Data, message: Data, output: UnsafeMutablePointer<Data>?, tag: UnsafeMutablePointer<Data>?) -> Bool {
        do {
            let box = try AES.GCM.seal(message, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
            // CryptoKit returns slices of one buffer; callers index from 0.
            output?.pointee = Data(box.ciphertext)
            tag?.pointee = Data(box.tag)
            return true
        } catch {
            return false
        }
    }

    /// `tag` is nil for messages from old clients that appended it to the
    /// payload instead of the key. Some of those also used 16-byte IVs.
    func decrypt(iv: Data, key: Data, encoded: Data, auth tag: Data?, output: UnsafeMutablePointer<Data>?) -> Bool {
        let ciphertext: Data
        let authTag: Data
        if let tag {
            ciphertext = encoded
            authTag = tag
        } else {
            guard encoded.count >= Self.tagLength else { return false }
            ciphertext = encoded.prefix(encoded.count - Self.tagLength)
            authTag = encoded.suffix(Self.tagLength)
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: authTag)
            output?.pointee = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return true
        } catch {
            return false
        }
    }
}
