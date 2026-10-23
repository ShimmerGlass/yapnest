import Foundation
import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

/// The numbers the UI tests read from the list's frame recorder. If these
/// are wrong, the UI tests pass over the glitches they exist to catch.
struct ScrollRecordTests {
    @Test func onlyAListThatIsToStayAtTheBottomCountsAsAway() {
        var record = ScrollRecord()
        record.geometry(distanceFromBottom: 0, distanceFromTop: 500, followsBottom: true, isPositioned: true, phase: .idle)
        // The user scrolled away, or the list isn't placed yet, or it's moving: not a glitch.
        record.geometry(distanceFromBottom: 300, distanceFromTop: 200, followsBottom: false, isPositioned: true, phase: .idle)
        record.geometry(distanceFromBottom: 400, distanceFromTop: 100, followsBottom: true, isPositioned: false, phase: .idle)
        record.geometry(distanceFromBottom: 250, distanceFromTop: 250, followsBottom: true, isPositioned: true, phase: .animating)
        #expect(record.maxAway == 0)
        // One frame that showed the wrong place.
        record.geometry(distanceFromBottom: -122, distanceFromTop: 622, followsBottom: true, isPositioned: true, phase: .idle)
        record.geometry(distanceFromBottom: 0, distanceFromTop: 500, followsBottom: true, isPositioned: true, phase: .idle)
        #expect(record.maxAway == 122)
        #expect(record.samples == 6)
        #expect(record.top == 500)
    }

    @Test func theReportBeforeTheListLandsIsntCounted() {
        var record = ScrollRecord()
        record.geometry(distanceFromBottom: -122, distanceFromTop: 0, followsBottom: true, isPositioned: true, phase: .idle)
        record.geometry(distanceFromBottom: 0, distanceFromTop: 2799, followsBottom: true, isPositioned: true, phase: .idle)
        record.geometry(distanceFromBottom: 0, distanceFromTop: 2799, followsBottom: true, isPositioned: true, phase: .idle)
        #expect(record.maxAway == 0)
        #expect(record.samples == 3)
        #expect(record.top == 2799)
    }

    @Test func aJumpAfterLandingIsCounted() {
        var record = ScrollRecord()
        record.geometry(distanceFromBottom: 0, distanceFromTop: 500, followsBottom: true, isPositioned: true, phase: .idle)
        record.geometry(distanceFromBottom: 120, distanceFromTop: 380, followsBottom: true, isPositioned: true, phase: .idle)
        #expect(record.maxAway == 120)
    }

    @Test func resetKeepsThatTheListLanded() {
        var record = ScrollRecord()
        record.geometry(distanceFromBottom: 0, distanceFromTop: 500, followsBottom: true, isPositioned: true, phase: .idle)
        record.reset()
        record.geometry(distanceFromBottom: 80, distanceFromTop: 420, followsBottom: true, isPositioned: true, phase: .idle)
        #expect(record.maxAway == 80)
    }

    @Test func olderRowsComingInMeasureHowFarTheAnchorMoved() {
        var record = ScrollRecord()
        record.rowsChanged(count: 500, firstID: 300, at: 0)
        record.anchorMeasured(id: 310, minY: 120, at: 1)
        record.geometry(distanceFromBottom: 900, distanceFromTop: 800, followsBottom: false, isPositioned: true, phase: .interacting)
        record.rowsChanged(count: 700, firstID: 100, at: 2)
        record.anchorMeasured(id: 310, minY: 2729, at: 2.02)
        #expect(record.prepends == 1)
        #expect(record.measuredPrepends == 1)
        #expect(record.maxPrependShift == 2609)
    }

    @Test func anAnchorThatStaysPutLeavesNoShift() {
        var record = ScrollRecord()
        record.rowsChanged(count: 500, firstID: 300, at: 0)
        record.anchorMeasured(id: 310, minY: 120, at: 1)
        record.rowsChanged(count: 700, firstID: 100, at: 2)
        // It reports only when it moves: the user scrolling later isn't the prepend's doing.
        record.anchorMeasured(id: 310, minY: 400, at: 3)
        // Nor is another row becoming the anchor.
        record.rowsChanged(count: 900, firstID: 50, at: 4)
        record.anchorMeasured(id: 120, minY: 50, at: 4.01)
        #expect(record.prepends == 2)
        #expect(record.maxPrependShift == 0)
    }

    @Test func rowsComingInWhileTheListCoastsAreCountedButNotMeasured() {
        var record = ScrollRecord()
        record.rowsChanged(count: 500, firstID: 300, at: 0)
        record.anchorMeasured(id: 310, minY: 120, at: 1)
        record.geometry(distanceFromBottom: 900, distanceFromTop: 800, followsBottom: false, isPositioned: true, phase: .decelerating)
        record.rowsChanged(count: 700, firstID: 100, at: 2)
        record.anchorMeasured(id: 310, minY: 600, at: 2.02)
        #expect(record.prepends == 1)
        #expect(record.measuredPrepends == 0)
        #expect(record.maxPrependShift == 0)
    }

    @Test func theFirstRowsAndATrimArentPrepends() {
        var record = ScrollRecord()
        record.anchorMeasured(id: 310, minY: 120, at: 0)
        record.rowsChanged(count: 500, firstID: 300, at: 0)
        // Cut back to the newest: fewer rows, a newer first one.
        record.rowsChanged(count: 300, firstID: 500, at: 1)
        #expect(record.prepends == 0)
        #expect(record.rows == 300)
    }

    @Test func resetStartsAgainButKeepsWhatTheListIs() {
        var record = ScrollRecord()
        record.rowsChanged(count: 7, firstID: 1, at: 0)
        record.visibleChanged(count: 2)
        record.geometry(distanceFromBottom: 50, distanceFromTop: 0, followsBottom: true, isPositioned: true, phase: .idle)
        record.reset()
        #expect(record.samples == 0)
        #expect(record.maxAway == 0)
        #expect(record.rows == 7)
        #expect(record.visible == 2)
        #expect(record.summary == "samples=0 maxAway=0.0 prepends=0 measuredPrepends=0 maxPrependShift=0.0 rows=7 visible=2 top=0 latestTaps=0 endNudges=0 titleChanges=0 headerSqueezes=0")
    }

    @Test func countsTapsOnTheScrollToLatestButtonUntilReset() {
        var record = ScrollRecord()
        record.latestTapped()
        record.latestTapped()
        #expect(record.latestTaps == 2)
        #expect(record.summary.contains("latestTaps=2"))
        record.reset()
        #expect(record.latestTaps == 0)
    }

    @Test func countsMarginNudgesUntilReset() {
        var record = ScrollRecord()
        record.nudged()
        record.nudged()
        #expect(record.endNudges == 2)
        #expect(record.summary.contains("endNudges=2"))
        record.reset()
        #expect(record.endNudges == 0)
    }

    @Test func aRowWhoseFrameOverlapsTheViewCountsWhenTheScrollViewStaysSilent() {
        var record = ScrollRecord()
        record.geometry(distanceFromBottom: 0, distanceFromTop: 0, viewHeight: 800, followsBottom: true, isPositioned: true, phase: .idle)
        record.visibleChanged(count: 0)
        #expect(record.visible == 0)
        // A tall row filling the view, and ones above and below it.
        record.rowFramed(id: 1, minY: -3000, maxY: 1500)
        record.rowFramed(id: 2, minY: -5000, maxY: -3000)
        record.rowFramed(id: 3, minY: 800, maxY: 900)
        #expect(record.visible == 1)
        // The scroll view's own count is not lowered by it.
        record.visibleChanged(count: 4)
        #expect(record.visible == 4)
        // A row the stack let go no longer counts.
        record.visibleChanged(count: 0)
        record.rowFramed(id: 1, minY: nil)
        #expect(record.visible == 0)
    }

    @Test func builtRowsOffTheScreenDoNotCountAsVisible() {
        var record = ScrollRecord()
        record.geometry(distanceFromBottom: 0, distanceFromTop: 0, viewHeight: 800, followsBottom: true, isPositioned: true, phase: .idle)
        record.rowFramed(id: 1, minY: 900, maxY: 1000)
        record.rowFramed(id: 2, minY: -200, maxY: 0)
        #expect(record.visible == 0)
    }
}
