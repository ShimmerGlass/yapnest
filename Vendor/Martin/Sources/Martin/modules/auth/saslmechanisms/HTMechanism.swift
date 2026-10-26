//
// HTMechanism.swift
//
// Yapnest's addition to Martin, under the same license.
//

import Foundation

/**
 SASL HT-SHA-256-NONE, -EXPR and -ENDP (draft-schmaus-kitten-sasl-ht), which
 sign in with a token from XEP-0484 FAST instead of the password. Both
 proofs cover the channel binding data (tls-exporter for EXPR,
 tls-server-end-point for ENDP), so one captured by a party that relays the
 connection with a certificate of its own can't be replayed. NONE has none,
 and is only as safe as the connection.
 */
open class HTMechanism: SaslMechanism {

    public static let sha256None = "HT-SHA-256-NONE";
    public static let sha256Expr = "HT-SHA-256-EXPR";
    public static let sha256Endp = "HT-SHA-256-ENDP";

    /// The variants Yapnest speaks, strongest first.
    public static let variants = [sha256Expr, sha256Endp, sha256None];

    public let name: String;
    public private(set) var status: SaslMechanismStatus = .new;

    private let token: String;
    private let bindings: ChannelBindings?;

    /// - parameter bindings: the connection's; read from the context when nil.
    public init(token: String, mechanism: String = HTMechanism.sha256None, bindings: ChannelBindings? = nil) {
        self.token = token;
        self.name = mechanism;
        self.bindings = bindings;
    }

    /// What a variant puts after the label; empty for NONE, nil when the
    /// connection has none of what it needs or it isn't a variant.
    public static func bindingData(for mechanism: String, in bindings: ChannelBindings) -> Data? {
        switch mechanism {
        case sha256None:
            return Data();
        case sha256Expr:
            return bindings.exporter;
        case sha256Endp:
            return bindings.serverEndPoint;
        default:
            return nil;
        }
    }

    /// The strongest of the variants `offered` that this connection can bind.
    public static func strongest(in offered: [String], bindings: ChannelBindings) -> String? {
        return variants.first(where: { offered.contains($0) && bindingData(for: $0, in: bindings) != nil });
    }

    /// The HMAC of the label and the binding data, keyed with the token.
    static func proof(label: String, token: String, bindingData: Data) -> [UInt8] {
        var data = Array(label.utf8) + Array(bindingData);
        return Digest.sha256.hmac(keyData: Data(token.utf8), data: &data);
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
            let data = try bindingData(context);
            // authcid NUL HMAC(token, "Initiator" || cb-data).
            var message = Data(username.utf8);
            message.append(0);
            message.append(contentsOf: Self.proof(label: "Initiator", token: token, bindingData: data));
            status = .completedExpected;
            return message.base64EncodedString();
        case .completedExpected:
            // The server proves it knew the token too, for this connection.
            guard let input, let received = Data(base64Encoded: input),
                  received == Data(Self.proof(label: "Responder", token: token, bindingData: try bindingData(context))) else {
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
        return context.mayTransmitSecrets && Self.bindingData(for: name, in: bindings ?? context.channelBindings) != nil;
    }

    private func bindingData(_ context: Context) throws -> Data {
        guard let data = Self.bindingData(for: name, in: bindings ?? context.channelBindings) else {
            throw ClientSaslException.genericError(msg: "This connection can't be bound for \(name)");
        }
        return data;
    }
}
