import Foundation
import UserNotifications

/// What the app does when a silent push wakes it in the background: the same
/// catch-up the notification extension runs, then posting what it found, as
/// there is no relay alert to replace.
public enum BackgroundPush {
    /// What iOS is told, as `UIBackgroundFetchResult`.
    public enum Result: Sendable, Equatable, CaseIterable, DiagEnum {
        case newData, noData, failed

        public var description: String {
            switch self {
            case .newData: "newData"
            case .noData: "noData"
            case .failed: "failed"
            }
        }
    }

    /// Under the 30 seconds iOS gives, with room to post what was found.
    public static let budget: TimeInterval = 18

    /// `.busy` and `.appIsRunning` mean someone else is doing the work. A
    /// catch-up that didn't finish and found nothing new is a failure rather
    /// than "no data": the push may have announced a message that isn't here.
    static func result(for outcome: NotificationFetcher.Outcome) -> Result {
        switch outcome {
        case .notifications(let new, let edited, _): new.isEmpty && edited.isEmpty ? .noData : .newData
        case .incomplete(let edited, _): edited.isEmpty ? .failed : .newData
        case .appIsRunning, .busy: .noData
        case .failed: .failed
        }
    }

    /// The notifications to show loudly. Muted ones, and what isn't a message
    /// (a reaction, a key exchange), stay silent, and with nothing new there
    /// is nothing.
    static func loud(in outcome: NotificationFetcher.Outcome) -> [MessageNotification] {
        guard case .notifications(let new, _, _) = outcome else { return [] }
        return new.filter { !$0.isQuiet }
    }

    /// Catches up as the signed-in account and posts what's new. `.noData` if
    /// there's no account. The session lock is held for the catch-up only and
    /// the app lock never, so an extension woken for a real message after
    /// this finds the app not running and runs normally.
    public static func run(timeout: TimeInterval = budget) async -> Result {
        guard let fetcher = NotificationFetcher.current(role: "background") else { return .noData }
        let outcome = await fetcher.fetch(timeout: timeout)
        await post(outcome, avatars: AccountDirectory(url: fetcher.directory).avatars)
        let result = result(for: outcome)
        DiagLog.info(.push, "Background push handled", .value("result", result))
        return result
    }

    private static func post(_ outcome: NotificationFetcher.Outcome, avatars: AvatarStore) async {
        let center = UNUserNotificationCenter.current()
        switch outcome {
        case .notifications(let new, let edited, let badge):
            _ = await MessageNotification.settleFetched(new, edited: edited, badge: badge, avatars: avatars)
            for notification in loud(in: outcome) {
                try? await center.add(await notification.request(badge: badge, avatars: avatars))
            }
            if !new.isEmpty { try? await center.setBadgeCount(badge) }
        case .incomplete(let edited, let badge):
            await MessageNotification.replaceDelivered(edited, badge: badge, avatars: avatars)
        case .appIsRunning, .busy, .failed:
            break
        }
    }
}
