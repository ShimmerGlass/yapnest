/// Lets a transfer's progress through only when it has moved half a percent,
/// and the end once: chunks arrive by the thousand, and every report redraws
/// the views that watch the transfers.
struct ProgressThrottle: Sendable {
    private var last = -1.0

    /// `value` if it is due to be reported, else nil.
    mutating func admit(_ value: Double) -> Double? {
        guard value - last >= 0.005 || (value >= 1 && last < 1) else { return nil }
        last = value
        return value
    }
}
