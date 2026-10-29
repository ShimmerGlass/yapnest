import SwiftUI
import UIKit
import YapnestKit

extension Message.Status {
    /// Signal's delivery icons: sending, sent, delivered, read. Looked up
    /// once, as every footer and chat list row asks on each redraw.
    var indicator: UIImage? {
        switch self {
        case .pending: Self.sending
        case .sent, .received: Self.sent
        case .delivered: Self.delivered
        case .displayed: Self.read
        case .failed: Self.failed
        }
    }

    private static let sending = UIImage(named: "message_status_sending")
    private static let sent = UIImage(named: "message_status_sent")
    private static let delivered = UIImage(named: "message_status_delivered")
    private static let read = UIImage(named: "message_status_read")
    private static let failed = UIImage(systemName: "exclamationmark.circle.fill")
}

extension Message {
    struct Security: Equatable {
        var symbol: String
        /// Nil: the footer's text color.
        var color: Color?
        var title: String
        /// About the sender's device, under the title.
        var detail: String?

        /// Both, on one line.
        var fullTitle: String { detail.map { "\(title) · \($0)" } ?? title }

    }

    /// How a message was protected in transit.
    var security: Security {
        switch encryption {
        case .none:
            return Security(symbol: "lock.slash.fill", color: .red, title: String(localized: "Not encrypted"))
        case .omemoUndecryptable:
            return Security(symbol: "lock.trianglebadge.exclamationmark.fill", color: .red, title: String(localized: "Couldn't decrypt"))
        case .omemo:
            switch omemoTrust {
            case .verified:
                if direction == .outgoing {
                    return Security(symbol: "lock.badge.checkmark.fill", color: nil, title: String(localized: "Encrypted for verified devices"))
                }
                return Security(symbol: "lock.badge.checkmark.fill", color: nil, title: String(localized: "Encrypted"), detail: String(localized: "Verified device"))
            case .undecided, .compromised:
                return Security(symbol: "lock.fill", color: .orange, title: String(localized: "Encrypted"), detail: String(localized: "Untrusted device"))
            case nil where direction == .incoming:
                // The sending device wasn't known, so nothing vouches for it.
                return Security(symbol: "lock.fill", color: .orange, title: String(localized: "Encrypted"), detail: String(localized: "Unknown device"))
            case .trusted, nil:
                let detail = direction == .outgoing ? nil : String(localized: "Unverified device")
                return Security(symbol: "lock.fill", color: nil, title: String(localized: "Encrypted"), detail: detail)
            }
        }
    }
}

extension UIFont {
    var bold: UIFont { with(traits: .traitBold) }
}
