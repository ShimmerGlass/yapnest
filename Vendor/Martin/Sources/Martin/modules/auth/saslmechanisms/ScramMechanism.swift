//
// ScramMechanism.swift
//
// TigaseSwift
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//
import Foundation

/**
 Mechanism implements SASL SCRAM authentication mechanism
 */
open class ScramMechanism: SaslMechanism {

    public static let SCRAM_SALTED_PASSWORD_CACHE = "SCRAM_SALTED_PASSWORD_CACHE";
    
    fileprivate static let ALPHABET = [Character]("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789");
    
    fileprivate static let SERVER_FIRST_MESSAGE = try! NSRegularExpression(pattern: "^(m=[^\\000=]+,)?r=([\\x21-\\x2B\\x2D-\\x7E]+),s=([a-zA-Z0-9/+=]+),i=(\\d+)(?:,.*)?$", options: NSRegularExpression.Options(rawValue: 0));
    /// Well above what servers use (ejabberd 4096, Prosody 10000).
    fileprivate static let MAX_ITERATIONS = 1_000_000;
    fileprivate static let SERVER_LAST_MESSAGE = try! NSRegularExpression(pattern: "^(?:e=([^,]+)|v=([a-zA-Z0-9/+=]+)(?:,.*)?)$", options: NSRegularExpression.Options(rawValue: 0));

    public static func ScramSha256(plus: Bool = false) -> ScramMechanism {
        var data = "Client Key".data(using: String.Encoding.utf8)!;
        var clientKey = Array<UInt8>(repeating: 0, count: data.count);
        (data as NSData).getBytes(&clientKey, length: data.count);
        data = "Server Key".data(using: String.Encoding.utf8)!;
        var serverKey = Array<UInt8>(repeating: 0, count: data.count);
        (data as NSData).getBytes(&serverKey, length: data.count);
        return ScramMechanism(mechanismName: plus ? "SCRAM-SHA-256-PLUS" : "SCRAM-SHA-256", algorithm: Digest.sha256, clientKey: clientKey, serverKey: serverKey, plus: plus);
    }

    public static func ScramSha1(plus: Bool = false) -> ScramMechanism {
        var data = "Client Key".data(using: String.Encoding.utf8)!;
        var clientKey = Array<UInt8>(repeating: 0, count: data.count);
        (data as NSData).getBytes(&clientKey, length: data.count);
        data = "Server Key".data(using: String.Encoding.utf8)!;
        var serverKey = Array<UInt8>(repeating: 0, count: data.count);
        (data as NSData).getBytes(&serverKey, length: data.count);
        return ScramMechanism(mechanismName: plus ? "SCRAM-SHA-1-PLUS" : "SCRAM-SHA-1", algorithm: Digest.sha1, clientKey: clientKey, serverKey: serverKey, plus: plus);
    }
        
    /// Name of mechanism
    public let name: String;
    public private(set) var status: SaslMechanismStatus = .new {
        didSet {
            if status == .new {
                saslData = nil;
            }
        }
    }
    
    fileprivate let algorithm: Digest;
    /// Whether this is the -PLUS variant, which binds the proof to the TLS connection.
    public let plus: Bool;
    
    fileprivate let clientKeyData: [UInt8];
    fileprivate let serverKeyData: [UInt8];
    private var saslData: Data?;
    
    public init(mechanismName: String, algorithm: Digest, clientKey: [UInt8], serverKey: [UInt8], plus: Bool = false) {
        self.name = mechanismName;
        self.plus = plus;
        self.algorithm = algorithm;
        self.clientKeyData = clientKey;
        self.serverKeyData = serverKey;
    }
    
    public func reset(scopes: Set<ResetableScope>) {
        if scopes.contains(.stream) {
            status = .new;
        }
    }

    open func evaluateChallenge(_ input: String?, context: Context) throws -> String? {
        guard status != .completed else {
            guard input == nil else {
                throw ClientSaslException.genericError(msg: "Client in illegal state - already authorized!");
            }
            return nil;
        }
        
        let data = getData();
    
        switch context.connectionConfiguration.credentials {
        case .password(let password, let authenticationName, let saltedPasswordCache):
            switch data.stage {
            case 0:
                data.conce = randomString();

                guard let binding = Self.gs2Header(plus: plus, bindings: context.channelBindings, serverTypes: context.serverChannelBindingTypes, serverOffersPlus: context.serverOffersChannelBinding) else {
                    throw ClientSaslException.genericError(msg: "No channel binding the server takes");
                }
                data.cb = binding.header;
                data.cbData = binding.data;
                let sb = data.cb;

                data.clientFirstMessageBare = "n=" + Self.saslName(context.userBareJid.localPart!) + "," + "r=" + data.conce!;
                data.stage += 1;
                
                return (sb + data.clientFirstMessageBare!).data(using: String.Encoding.utf8)?.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0));
            case 1:
                guard input != nil else {
                    throw ClientSaslException.badChallenge(msg: "Received empty challenge!");
                }
                let msgBytes = Foundation.Data(base64Encoded: input!, options: NSData.Base64DecodingOptions(rawValue: 0));
                
                guard msgBytes != nil else {
                    throw ClientSaslException.badChallenge(msg: "Failed to decode challenge!");
                }
                guard let msg = String(data: msgBytes!, encoding: String.Encoding.utf8) else {
                    throw ClientSaslException.badChallenge(msg: "Challenge isn't UTF-8!");
                }
                let r = ScramMechanism.SERVER_FIRST_MESSAGE.matches(in: msg, options: NSRegularExpression.MatchingOptions.withoutAnchoringBounds, range: NSMakeRange(0, (msg as NSString).length));
                
                guard r.count == 1 && r[0].numberOfRanges >= 5  else {
                    throw ClientSaslException.badChallenge(msg: "Failed to parse challenge!");
                }
                let msgNS = msg as NSString;
                let m = r[0];
                _ = groupPartOfString(m, group: 1, str: msgNS);
                guard let nonce = groupPartOfString(m, group: 2, str: msgNS) else {
                    throw ClientSaslException.badChallenge(msg: "Missing nonce");
                }

                guard let saltStr = groupPartOfString(m, group: 3, str: msgNS) else {
                    throw ClientSaslException.badChallenge(msg: "Missing salt");
                }

                guard let salt = Foundation.Data(base64Encoded: saltStr, options: NSData.Base64DecodingOptions(rawValue: 0)) else {
                    throw ClientSaslException.badChallenge(msg: "Invalid encoding of salt");
                }
                // The server picks the count, so it must not be able to pick one
                // that traps the loop (0) or pins the CPU for minutes.
                guard let iterations = Int(groupPartOfString(m, group: 4, str: msgNS) ?? ""), iterations >= 1, iterations <= ScramMechanism.MAX_ITERATIONS else {
                    throw ClientSaslException.badChallenge(msg: "Invalid number of iterations");
                }

                guard nonce.hasPrefix(data.conce!) else {
                    throw ClientSaslException.wrongNonce;
                }

                let c = (Foundation.Data(data.cb.utf8) + data.cbData).base64EncodedString();
                
                var clientFinalMessage = "c=" + c + "," + "r=" + nonce;
                let part = "," + msg + ",";
                data.authMessage = data.clientFirstMessageBare! + part + clientFinalMessage;
                
                let saltedCacheId = saltedPasswordCache?.generateId(algorithm: algorithm, salt: salt, iterations: iterations);
                if saltedCacheId != nil {
                    data.saltedPassword = saltedPasswordCache?.getSaltedPassword(for: context, id: saltedCacheId!);
                }
                if data.saltedPassword == nil {
                    data.saltedCacheId = saltedCacheId;
                    data.saltedPassword = hi(password: normalize(password), salt: salt, iterations: iterations);
                }
                var clientKeyData = self.clientKeyData;
                var clientKey = algorithm.hmac(key: &data.saltedPassword!, data: &clientKeyData);
                var storedKey = algorithm.digest(bytes: &clientKey, length: clientKey.count);
                
                var clientSignature = algorithm.hmac(key: &storedKey, data: data.authMessage!.data(using: String.Encoding.utf8)!);
                var clientProof = xor(clientKey, &clientSignature);
                
                clientFinalMessage += "," + "p=" + Foundation.Data(bytes: &clientProof, count: clientProof.count).base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0));

                data.stage += 1;
                status = .completedExpected;
                return clientFinalMessage.data(using: String.Encoding.utf8)?.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0));
            case 2:
                guard input != nil else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.badChallenge(msg: "Received empty challenge!");
                }

                let msgBytes = Foundation.Data(base64Encoded: input!, options: NSData.Base64DecodingOptions(rawValue: 0));
                
                guard msgBytes != nil else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.badChallenge(msg: "Failed to decode challenge!");
                }
                guard let msg = String(data: msgBytes!, encoding: String.Encoding.utf8) else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.badChallenge(msg: "Challenge isn't UTF-8!");
                }
                let r = ScramMechanism.SERVER_LAST_MESSAGE.matches(in: msg, options: NSRegularExpression.MatchingOptions.withoutAnchoringBounds, range: NSMakeRange(0, (msg as NSString).length));
                
                guard r.count == 1 && r[0].numberOfRanges >= 3  else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.badChallenge(msg: "Failed to parse challenge!");
                }
                let msgNS = msg as NSString;
                let m = r[0];
                _ = groupPartOfString(m, group: 1, str: msgNS);
                guard let v = groupPartOfString(m, group: 2, str: msgNS) else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.badChallenge(msg: "Invalid value of 'v'");
                }
                
                var serverKeyData = self.serverKeyData;
                var serverKey = algorithm.hmac(key: &data.saltedPassword!, data: &serverKeyData);
                var serverSignature = algorithm.hmac(key: &serverKey, data: data.authMessage!.data(using: String.Encoding.utf8)!);
                
                let value = Foundation.Data(base64Encoded: v, options: NSData.Base64DecodingOptions(rawValue: 0));
                guard value != nil && (value! == Foundation.Data(bytes: &serverSignature, count: serverSignature.count)) else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.invalidServerSignature;
                }
                
                data.stage += 1;
                if let saltedCacheId = data.saltedCacheId, let saltedPassword = data.saltedPassword {
                    saltedPasswordCache?.store(for: context, id: saltedCacheId, saltedPassword: saltedPassword);
                }
                status = .completed;
                
                // releasing data object
                self.saslData = nil;
                return nil;
            default:
                guard status == .completed && input == nil else {
                    saltedPasswordCache?.clearCache(for: context);
                    throw ClientSaslException.genericError(msg: "Client in illegal state! stage = \(data.stage)");
                }
                // let's assume this is ok as session is authenticated
                return nil;
            }

        default:
            throw ClientSaslException.genericError(msg: "Invalid credentials type for authorization!");
        }
                
    }
    
    open func isAllowedToUse(_ context: Context) -> Bool {
        switch context.connectionConfiguration.credentials {
        case .password(_, _, _):
            // -PLUS needs a binding type both sides have, which needs TLS.
            return !plus || context.channelBindings.choose(from: context.serverChannelBindingTypes) != nil;
        default:
            return false;
        }
    }

    /// The GS2 header and the binding data that follow it in `c=`; nil for
    /// -PLUS without a type both sides have.
    static func gs2Header(plus: Bool, bindings: ChannelBindings, serverTypes: [String], serverOffersPlus: Bool) -> (header: String, data: Foundation.Data)? {
        if plus {
            guard let chosen = bindings.choose(from: serverTypes) else {
                return nil;
            }
            return ("p=" + chosen.type + ",,", chosen.data);
        }
        // We could bind but the server offered no -PLUS. "y" tells a server
        // that can bind to refuse us: someone in between took the -PLUS
        // mechanisms out of its list.
        if !bindings.isEmpty && !serverOffersPlus {
            return ("y,,", Foundation.Data());
        }
        return ("n,,", Foundation.Data());
    }

    /// RFC 5802's saslname: "," and "=" would end or confuse the attribute.
    static func saslName(_ name: String) -> String {
        return name.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C");
    }
    
    func hi(password: Foundation.Data, salt: Foundation.Data, iterations: Int) -> [UInt8] {
        let k = password;
        var z = Array<UInt8>(repeating: 0, count: salt.count);
        (salt as NSData).getBytes(&z, length: salt.count);
        z.append(contentsOf: [ 0, 0, 0, 1]);
        
        var u = algorithm.hmac(keyData: k, data: &z);
        var result = u;
        
        for _ in  1..<iterations {
            u = algorithm.hmac(keyData: k, data: &u);
            for j in 0..<u.count {
                result[j] ^= u[j];
            }
        }
        
        return result;
    }
    
    func normalize(_ str: String) -> Foundation.Data {
        return str.data(using: String.Encoding.utf8)!;
    }
    
    func getData() -> Data {
        guard let data = saslData else {
            let data = Data();
            self.saslData = data;
            return data;
        }
        return data;
    }
    
    func randomString() -> String {
        // Drawn from the whole alphabet: picking by the length (20) used only A to T.
        let length = 32;
        return String((0..<length).map { _ in ScramMechanism.ALPHABET[Int(arc4random_uniform(UInt32(ScramMechanism.ALPHABET.count)))] });
    }
    
    func xor (_ a: [UInt8], _ b: inout [UInt8]) -> [UInt8] {
        var r = a;
        for i in 0..<r.count {
            r[i] ^= b[i];
        }
        return r;
    }
    
    func groupPartOfString(_ m: NSTextCheckingResult, group: Int, str: NSString) -> String? {
        guard group < m.numberOfRanges else {
            return nil;
        }
        
        let r = m.range(at: group);
        guard r.length != 0 else {
            return "";
        }
        
        return str.substring(with: r);
    }
    
    class Data {
        var authMessage: String?;
        var cb: String = "n,,";
        /// The channel binding's data, after the GS2 header in `c=`.
        var cbData = Foundation.Data();
        var clientFirstMessageBare: String?;
        var conce: String?;
        var saltedCacheId: String?;
        var saltedPassword: [UInt8]?;
        var stage: Int = 0;
    }
}
