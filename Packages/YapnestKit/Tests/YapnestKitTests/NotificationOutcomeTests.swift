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

    // MARK: A silent push in the app

    private var muted: MessageNotification {
        var copy = note
        copy.isQuiet = true
        return copy
    }

    @Test func aWakeThatFoundNothingNewAnswersNoDataAndPostsNothing() {
        let outcome = NotificationFetcher.Outcome.notifications([], edited: [], badge: 2)

        #expect(BackgroundPush.result(for: outcome) == .noData)
        #expect(BackgroundPush.loud(in: outcome).isEmpty)
    }

    @Test func aWakeThatFoundMessagesAnswersNewDataAndPostsTheLoudOnes() {
        let outcome = NotificationFetcher.Outcome.notifications([note, muted], edited: [], badge: 1)

        #expect(BackgroundPush.result(for: outcome) == .newData)
        #expect(BackgroundPush.loud(in: outcome) == [note])
    }

    @Test func onlyMutedMessagesAreNewDataButPostNothingLoud() {
        let outcome = NotificationFetcher.Outcome.notifications([muted], edited: [], badge: 1)

        #expect(BackgroundPush.result(for: outcome) == .newData)
        #expect(BackgroundPush.loud(in: outcome).isEmpty)
    }

    @Test func aCorrectionAloneIsNewDataButPostsNoNewNotification() {
        let outcome = NotificationFetcher.Outcome.notifications([], edited: [note], badge: 1)

        #expect(BackgroundPush.result(for: outcome) == .newData)
        #expect(BackgroundPush.loud(in: outcome).isEmpty)
    }

    @Test func anUnfinishedCatchUpThatFoundNothingFails() {
        #expect(BackgroundPush.result(for: .incomplete(edited: [], badge: 1)) == .failed)
        #expect(BackgroundPush.result(for: .incomplete(edited: [note], badge: 1)) == .newData)
        #expect(BackgroundPush.loud(in: .incomplete(edited: [note], badge: 1)).isEmpty)
    }

    @Test func anotherProcessDoingTheWorkOrAFailureMapToNoDataAndFailed() {
        #expect(BackgroundPush.result(for: .appIsRunning) == .noData)
        #expect(BackgroundPush.result(for: .busy) == .noData)
        #expect(BackgroundPush.result(for: .failed("x")) == .failed)
        #expect(BackgroundPush.loud(in: .busy).isEmpty)
    }
}
