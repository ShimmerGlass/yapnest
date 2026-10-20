import Foundation

/// What decides how a voice message recording ends, apart from the recorder
/// and the touch that drives it, so it can be tested without a microphone.
public enum VoiceRecordingRules {
    /// A press shorter than this was a tap, which starts a recording that
    /// stays on until it is sent or cancelled (a hold is released to send).
    public static let tapDuration: TimeInterval = 0.3
    /// Shorter recordings are an accident and are dropped.
    public static let minimumDuration: TimeInterval = 0.5
    /// A recording ends, and is sent, at this length.
    public static let maximumDuration: TimeInterval = 15 * 60
    /// Sliding this far toward the text's start cancels a held recording.
    public static let cancelDistance: Double = 80

    public enum Release: Equatable, Sendable {
        /// Keep recording until the user sends or cancels.
        case lock
        case send
        case cancel
    }

    /// What letting go of the button means, after a press of `pressDuration`.
    public static func release(pressDuration: TimeInterval, willCancel: Bool) -> Release {
        if willCancel { return .cancel }
        return pressDuration < tapDuration ? .lock : .send
    }

    /// Whether a recording of `duration` is long enough to be sent.
    public static func isSendable(_ duration: TimeInterval) -> Bool {
        duration >= minimumDuration
    }

    /// A meter reading in decibels (-160 silent, 0 full scale) as 0...1. Speech
    /// sits between -50 and -10, so the range below -50 is dropped.
    public static func meterLevel(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 50) / 50))
    }
}
