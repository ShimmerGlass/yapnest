import Foundation
import Testing
import UserNotifications
@testable import YapnestKit

struct NotificationOutcomeTests {
    private let note = MessageNotification(
        messageId: 1, peer: JID("alice@example.org")!, title: "Alice", body: "hi", timestamp: Date(),
    )

    @Test func aCatchUpThatFinishedWithNothingNewStaysQuiet() {
        let outcome = NotificationFetcher.outcome(new: [], edited: [], badge: 2, caughtUp: true)
        #expect(outcome == .notifications([], edited: [], badge: 2))
    }

    @Test func aCatchUpThatDidntFinishAndFoundNothingNewIsIncomplete() {
        let outcome = NotificationFetcher.outcome(new: [], edited: [note], badge: 2, caughtUp: false)
        #expect(outcome == .incomplete(edited: [note], badge: 2))
    }

    @Test func whatAnUnfinishedCatchUpStoredIsStillShown() {
        let outcome = NotificationFetcher.outcome(new: [note], edited: [], badge: 1, caughtUp: false)
        #expect(outcome == .notifications([note], edited: [], badge: 1))
    }

    @Test func theRelaysAlertIsMarkedAsAPlaceholderWithoutChangingTheOriginal() {
        let relay = UNMutableNotificationContent()
        relay.body = "New message"

        let copy = relay.placeholderCopy(badge: 3)

        #expect(copy.userInfo[MessageNotification.placeholderKey] as? Bool == true)
        #expect(copy.body == "New message")
        #expect(copy.badge == 3)
        #expect(relay.userInfo[MessageNotification.placeholderKey] == nil)
    }
}
