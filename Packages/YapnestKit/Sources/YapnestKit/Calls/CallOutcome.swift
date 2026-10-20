import Foundation
import GRDB

/// How a call ended, as the conversation shows it.
public enum CallOutcome: String, Codable, Sendable, DatabaseValueConvertible {
    case answered
    /// An incoming call nobody here answered.
    case missed
    case declined
    /// The caller gave up before an answer: our outgoing call, or one of ours
    /// that wasn't picked up.
    case cancelled
    case busy
    /// Connected, or on the way to it, and then the media failed.
    case failed

    /// How far a row's outcome can be trusted when a replay of the call
    /// proposes another: a replay refines what a lone `propose` implies, and
    /// never overrides what this device saw happen.
    var rank: Int {
        switch self {
        case .missed, .cancelled: 0
        case .declined, .busy, .answered: 1
        case .failed: 2
        }
    }
}

/// A call row's content: what happened and, if it was answered, for how long.
public struct CallSummary: Sendable, Hashable {
    public var outcome: CallOutcome
    public var direction: Message.Direction
    public var duration: TimeInterval?
    public var isVideo: Bool

    public init(outcome: CallOutcome, direction: Message.Direction, duration: TimeInterval?, isVideo: Bool = false) {
        self.outcome = outcome
        self.direction = direction
        self.duration = duration
        self.isVideo = isVideo
    }
}

extension Message {
    /// Set on the rows that stand for a call, which have no body.
    public var call: CallSummary? {
        callOutcome.map { CallSummary(outcome: $0, direction: direction, duration: callDuration, isVideo: callIsVideo) }
    }

    /// What a notification for a call row says.
    static var missedCallSummary: String { String(localized: "Missed call") }
}
