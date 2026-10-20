import Foundation

/// A contact's availability, combined over all their connected devices.
public enum ContactPresence: Int, Sendable, Comparable {
    case offline
    /// Do not disturb.
    case busy
    /// Away or extended away.
    case away
    case online

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
