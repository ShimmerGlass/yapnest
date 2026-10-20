//
// HTMechanism.swift
//
// Yapnest's addition to Martin, under the same license.
//

import Foundation

/**
 SASL HT-SHA-256-NONE (draft-schmaus-kitten-sasl-ht), which signs in with a
 token from XEP-0484 FAST instead of the password. Without channel binding,
 so usable on any stream the token can safely travel over.
 */
open class HTMechanism: SaslMechanism {

    public static let sha256None = "HT-SHA-256-NONE";

    public let name = HTMechanism.sha256None;
    public private(set) var status: SaslMechanismStatus = .new;

    private let token: String;

    public init(token: String) {
        self.token = token;
    }

    public func reset(scopes: Set<ResetableScope>) {
        if scopes.contains(.stream) {
            status = .new;
        }
    }

    open func evaluateChallenge(_ input: String?, context: Context) throws -> String? {
        switch status {
        case .new:
            guard let username = context.userBareJid.localPart else {
                throw ClientSaslException.genericError(msg: "No username to sign in with");
            }
            // authcid NUL HMAC(token, "Initiator" || cb-data), cb-data empty.
            var message = Data(username.utf8);
            message.append(0);
            message.append(contentsOf: hmac("Initiator"));
            status = .completedExpected;
            return message.base64EncodedString();
        case .completedExpected:
            // The server proves it knew the token too.
            guard let input, let received = Data(base64Encoded: input), received == Data(hmac("Responder")) else {
                throw ClientSaslException.invalidServerSignature;
            }
            status = .completed;
            return nil;
        case .completed:
            guard input == nil else {
                throw ClientSaslException.genericError(msg: "Client in illegal state - already authorized!");
            }
            return nil;
        }
    }

    open func isAllowedToUse(_ context: Context) -> Bool {
        return context.mayTransmitSecrets;
    }

    private func hmac(_ label: String) -> [UInt8] {
        var data = Array(label.utf8);
        return Digest.sha256.hmac(keyData: Data(token.utf8), data: &data);
    }
}
