//
// SignalIdentityKeyPair.swift
//
// TigaseSwift OMEMO
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import libsignal

/// Owns one `ratchet_identity_key_pair`. Everything is computed at init and never changes, so
/// libsignal's callbacks, publishing and fingerprints can read it from any thread.
open class SignalIdentityKeyPair: SignalIdentityKey, SignalIdentityKeyPairProtocol {
    
    private let ratchetKeyPair: OpaquePointer;
    // Borrowed from the pair, which keeps it alive.
    public let privateKeyPointer: OpaquePointer;
    public let privateKey: Data?;
    public let keyPair: Data?;
    
    public var keyPairPointer: OpaquePointer? {
        return ratchetKeyPair;
    }
    
    public convenience init?(publicKey: Data?, privateKey: Data?) {
        guard let publicKey = publicKey, let privateKey = privateKey else {
            return nil;
        }
        
        guard let privateKeyPointer = privateKey.withUnsafeBytes({ (bytes) -> OpaquePointer? in
            var tmp: OpaquePointer?;
            guard curve_decode_private_point(&tmp, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), privateKey.count, nil) >= 0 else {
                return nil;
            }
            return tmp;
        }) else {
            return nil;
        }
        
        guard let publicKeyPointer = SignalIdentityKey.publicKey(from: publicKey) else {
            signal_type_unref(privateKeyPointer);
            return nil;
        }
        
        // The pair takes its own references to both keys.
        var pair: OpaquePointer?;
        let result = ratchet_identity_key_pair_create(&pair, publicKeyPointer, privateKeyPointer);
        signal_type_unref(publicKeyPointer);
        signal_type_unref(privateKeyPointer);
        guard result >= 0 && pair != nil else {
            return nil;
        }
        self.init(withKeyPair: pair!);
        signal_type_unref(pair);
    }
    
    /// Takes its own reference to `keyPair`; the caller keeps theirs.
    public init(withKeyPair keyPair: OpaquePointer) {
        signal_type_ref(keyPair);
        ratchetKeyPair = keyPair;
        privateKeyPointer = ratchet_identity_key_pair_get_private(keyPair);
        
        var buffer: OpaquePointer?;
        if ec_private_key_serialize(&buffer, privateKeyPointer) == 0 && buffer != nil {
            privateKey = Data(bytes: signal_buffer_data(buffer), count: signal_buffer_len(buffer));
            signal_buffer_bzero_free(buffer);
        } else {
            privateKey = nil;
        }
        
        buffer = nil;
        if ratchet_identity_key_pair_serialize(&buffer, keyPair) == 0 && buffer != nil {
            self.keyPair = Data(bytes: signal_buffer_data(buffer), count: signal_buffer_len(buffer));
            signal_buffer_bzero_free(buffer);
        } else {
            self.keyPair = nil;
        }
        super.init(publicKeyPointer: ratchet_identity_key_pair_get_public(keyPair));
    }
    
    public convenience init?(fromKeyPairData data: Data) {
        guard let keyPair = data.withUnsafeBytes({ (bytes) -> OpaquePointer? in
            var tmp: OpaquePointer?;
            guard ratchet_identity_key_pair_deserialize(&tmp, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, nil) >= 0 && tmp != nil else {
                return nil;
            }
            return tmp;
        }) else {
            return nil;
        }
        self.init(withKeyPair: keyPair);
        // Deserializing handed us a reference that init doesn't take over.
        signal_type_unref(keyPair);
    }
    
    deinit {
        signal_type_unref(ratchetKeyPair);
    }
    
    public static func generateKeyPair(context: SignalContext) -> SignalIdentityKeyPair? {
        var keyPair: OpaquePointer? = nil;
        let result = signal_protocol_key_helper_generate_identity_key_pair(&keyPair, context.globalContext);
        guard result >= 0 && keyPair != nil else {
            return nil;
        }
        defer {
            signal_type_unref(keyPair);
        }
        return SignalIdentityKeyPair(withKeyPair: keyPair!);
    }
    
    override open func serialized() -> Data {
        return keyPair!;
    }
}
