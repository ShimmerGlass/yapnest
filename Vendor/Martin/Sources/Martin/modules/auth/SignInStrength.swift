//
// SignInStrength.swift
//
// Not part of upstream Martin. See Vendor/README.md.
//

import Foundation

/// How well a mechanism protects the sign-in against someone who sits in the
/// connection with a certificate the device trusts.
public enum SignInTier: Int, Comparable, Sendable {
    /// PLAIN: the password itself is sent.
    case plain = 0;
    /// SCRAM without channel binding, and HT-SHA-256-NONE: no secret is sent,
    /// but the proof can be relayed to the real server.
    case scram = 1;
    /// SCRAM-*-PLUS and HT-SHA-256-EXPR/ENDP: the proof covers this TLS
    /// connection, so it is of no use on any other.
    case bound = 2;

    /// Nil for a mechanism that isn't used to sign in an account (ANONYMOUS).
    public init?(mechanism: String) {
        switch mechanism {
        case "PLAIN":
            self = .plain;
        case "SCRAM-SHA-256", "SCRAM-SHA-1", HTMechanism.sha256None:
            self = .scram;
        case "SCRAM-SHA-256-PLUS", "SCRAM-SHA-1-PLUS", HTMechanism.sha256Expr, HTMechanism.sha256Endp:
            self = .bound;
        default:
            return nil;
        }
    }

    public static func < (lhs: SignInTier, rhs: SignInTier) -> Bool {
        return lhs.rawValue < rhs.rawValue;
    }
}

/// A sign-in that was refused because it would be weaker than one that
/// worked before. The server, or someone in between, may be hiding the
/// stronger mechanisms.
public struct WeakerSignInError: Error, LocalizedError, Equatable {
    /// The mechanism of the strongest sign-in that worked.
    public let recorded: String;
    /// The mechanism this sign-in would have used.
    public let offered: String;

    public var errorDescription: String? {
        return "The server offered a weaker way to sign in than before (\(offered) instead of \(recorded)), so Yapnest didn't send your password. Someone may be intercepting the connection.";
    }
}

/// Never signing in weaker than before, per account: the mechanism of the
/// strongest successful sign-in is kept (`recorded`), trusting the first.
public enum SignInPinning {

    /// The error to stop with when `chosen` is below the recorded mechanism.
    public static func refusal(chosen: String, recorded: String?) -> WeakerSignInError? {
        guard let recorded, let recordedTier = SignInTier(mechanism: recorded), let chosenTier = SignInTier(mechanism: chosen), chosenTier < recordedTier else {
            return nil;
        }
        return WeakerSignInError(recorded: recorded, offered: chosen);
    }

    /// The mechanism to record after `succeeded` signed in; nil if the record
    /// stays as it is, as the tier only ever rises.
    public static func recording(succeeded: String, recorded: String?) -> String? {
        guard let tier = SignInTier(mechanism: succeeded) else {
            return nil;
        }
        if let recorded, let recordedTier = SignInTier(mechanism: recorded), recordedTier >= tier {
            return nil;
        }
        return succeeded;
    }
}
