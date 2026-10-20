import Foundation

/// Which APNs environment a device token belongs to. The token is only valid
/// there, and the relay has to push to the same one.
public enum PushEnvironment: Equatable, Sendable {
    case sandbox
    case production

    /// Reads the environment from an embedded provisioning profile. The
    /// signing decides it, not the build configuration: the scheme runs
    /// Release, but signed for development, so iOS hands out sandbox tokens
    /// that a `#if DEBUG` check would call production.
    ///
    /// Builds from the App Store or TestFlight carry no profile, and are
    /// always production. A profile without the key is treated the same, as
    /// the safer guess for a build that isn't a development one.
    public static func from(profile: Data?) -> PushEnvironment {
        guard let profile else { return .production }
        guard let value = apsEnvironment(in: profile) else { return .production }
        return value == "development" ? .sandbox : .production
    }

    /// The value of the profile's push entitlement, or nil if it's missing or
    /// the profile can't be read.
    public static func apsEnvironment(in profile: Data) -> String? {
        // The profile is a CMS envelope around an XML plist. The plist is
        // stored as is, so it can be cut out without verifying the signature.
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return nil }
        // iOS profiles name it `aps-environment`, Mac ones prefix it.
        return (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
    }
}
