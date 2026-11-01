import Foundation
import YapnestKit

/// How a share that was written ends for the user. A send that wrote nothing
/// isn't one: the sheet stays up for another try.
enum ShareEnding: Equatable {
    /// The server has everything.
    case sent
    /// Yapnest, which is running and holds the session, has been told to send
    /// it now. Nothing has reached the server yet, so it isn't "sent".
    case handedToApp
    /// Written, to be sent by Yapnest when it next opens, and why not now.
    case queued(String)
    /// Written, but a message failed. It waits in Yapnest, where it can be
    /// retried.
    case failed(String)

    /// Nil when nothing was written, so that sending again is safe.
    init?(_ outcome: ShareSender.Outcome) {
        switch outcome {
        case .sent: self = .sent
        case .handedToApp: self = .handedToApp
        case .queued(let reason): self = .queued(reason)
        case .failedInApp(let reason): self = .failed(reason)
        case .failed: return nil
        }
    }

    /// How long the sheet stays up before closing by itself; nil if it waits
    /// for the user, who has a reason to read.
    var linger: Duration? {
        switch self {
        case .sent: .milliseconds(700)
        case .handedToApp: .milliseconds(1500)
        case .queued, .failed: nil
        }
    }
}
