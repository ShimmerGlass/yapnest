import Foundation

/// When the Mac shows us away. It never suspends the app, so what says the
/// user has gone is the keyboard and mouse going quiet, or the screen locking.
public enum IdleRules {
    /// Without input for this long, the user has stepped away.
    public static let awayAfter: TimeInterval = 10 * 60
    /// How often to look while the user is here: going away a little late
    /// doesn't matter.
    public static let presentInterval: TimeInterval = 15
    /// How often while away, so the first touch of the mouse brings us back.
    public static let awayInterval: TimeInterval = 2

    public static func isAway(idle: TimeInterval, screenLocked: Bool) -> Bool {
        screenLocked || idle >= awayAfter
    }

    public static func interval(away: Bool) -> TimeInterval {
        away ? awayInterval : presentInterval
    }
}
