import Foundation
import GRDB
@preconcurrency import MartinOMEMO

/// One OMEMO device of a contact (or of our own account), for display.
public struct OMEMODevice: Sendable, Hashable, Identifiable {
    public enum Trust: String, Sendable, Hashable, Codable, DatabaseValueConvertible {
        /// Not encrypted to until the user decides.
        case undecided
        /// Trusted without verification.
        case trusted
        /// Fingerprint compared out of band.
        case verified
        /// Never encrypted to, and its messages are shown as undecryptable.
        case compromised

        init(_ status: IdentityStatus) {
            switch status.trust {
            case .undecided: self = .undecided
            case .trusted: self = .trusted
            case .verified: self = .verified
            case .compromised: self = .compromised
            }
        }

        var signal: MartinOMEMO.Trust {
            switch self {
            case .undecided: .undecided
            case .trusted: .trusted
            case .verified: .verified
            case .compromised: .compromised
            }
        }
    }

    /// A fingerprint in groups of eight, the way other OMEMO clients show it.
    public static func grouped(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 8).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: 8, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
            return String(fingerprint[start..<end])
        }
        .joined(separator: " ")
    }

    public var jid: JID
    public var id: Int32
    public var fingerprint: String
    public var trust: Trust
    /// Whether the device is still in the account's published device list.
    public var isActive: Bool
    /// When we first knew of the device.
    public var firstSeen: Date
    /// When it last sent us anything, even a message we couldn't read. Nil
    /// if it never has, as far as we recorded.
    public var lastUsed: Date?

    /// How long a device may go without sending anything before we stop
    /// encrypting to it, and offer to remove our own such devices.
    public static let inactivityThreshold: TimeInterval = 90 * 24 * 60 * 60

    /// Whether the device has gone quiet: its last message, or if it never
    /// sent one, the day we first knew of it, is over the threshold ago. A
    /// device we only just learned of is never inactive.
    public static func isInactive(firstSeen: Date, lastUsed: Date?, now: Date) -> Bool {
        (lastUsed ?? firstSeen) < now.addingTimeInterval(-inactivityThreshold)
    }

    /// Whether the device is inactive. Any message from it makes it active again.
    public func isInactive(now: Date = Date()) -> Bool {
        Self.isInactive(firstSeen: firstSeen, lastUsed: lastUsed, now: now)
    }
}
