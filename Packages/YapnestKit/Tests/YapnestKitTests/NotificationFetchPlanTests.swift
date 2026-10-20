import Foundation
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

struct NotificationFetchPlanTests {
    private let start = Date(timeIntervalSince1970: 1000)

    private func plan(lastCatchUp: Date = .distantPast, waited: TimeInterval) -> NotificationFetcher.Plan {
        NotificationFetcher.plan(arrived: start, lastCatchUp: lastCatchUp, now: start.addingTimeInterval(waited), timeout: 20)
    }

    @Test func aPushThatDidntWaitGetsTheWholeTime() {
        #expect(plan(waited: 0) == .catchUp(lockWait: 3, timeout: 17))
    }

    @Test func aQueuedPushGetsWhatIsLeftOfItsOwnDeadline() {
        #expect(plan(waited: 10) == .catchUp(lockWait: 3, timeout: 7))
    }

    @Test func aPushWithTooLittleLeftOnlyClaims() {
        #expect(plan(waited: 16.5) == .claimOnly)
        #expect(plan(waited: 25) == .claimOnly)
        #expect(plan(waited: 16) == .catchUp(lockWait: 3, timeout: 1))
    }

    @Test func theLockWaitNeverOutlastsWhatIsLeft() {
        // Only possible with a short timeout, but the rule holds anyway.
        let short = NotificationFetcher.plan(arrived: start, lastCatchUp: .distantPast, now: start, timeout: 4)
        #expect(short == .catchUp(lockWait: 3, timeout: 1))
        if case .catchUp(let wait, let timeout) = plan(waited: 12) { #expect(wait + timeout <= 8) } else { Issue.record("expected a catch-up") }
    }

    @Test func aPushOlderThanTheLatestCatchUpOnlyClaims() {
        #expect(plan(lastCatchUp: start.addingTimeInterval(1), waited: 2) == .claimOnly)
        #expect(plan(lastCatchUp: start.addingTimeInterval(-1), waited: 2) != .claimOnly)
    }
}

/// What the extension asks of a room's archive.
struct NotificationPageQueryTests {
    private func query(_ page: XMPPSession.NotificationPage) -> (max: String?, before: Element?, after: String?, index: String?) {
        let set = page.query.element
        return (set.findChild(name: "max")?.value, set.findChild(name: "before"), set.findChild(name: "after")?.value, set.findChild(name: "index")?.value)
    }

    @Test func aRoomNeverReadAsksForItsNewestMessages() {
        let query = query(.newest)
        #expect(query.max == "50")
        // An empty `before` is how RSM asks for the last page.
        #expect(query.before != nil)
        #expect(query.after == nil)
    }

    @Test func aCursorAsksForWhatCameAfterIt() {
        let query = query(.after("r7"))
        #expect(query.max == "50")
        #expect(query.after == "r7")
        #expect(query.before == nil)
    }

    @Test func readingForwardFromADateAsksForTheFirstPageAfterIt() {
        // Not the newest page: a busy room's earlier messages would be skipped.
        let query = query(.forward)
        #expect(query.max == "50")
        #expect(query.before == nil)
        #expect(query.after == nil)
    }
}
