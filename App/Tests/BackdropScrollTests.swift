import SwiftUI
import Testing
@testable import Yapnest

/// The backdrop follows the user's scrolling only. Opening a chat on the Mac
/// scrolled the unflipped list to its end, and the backdrop jumped with it.
@MainActor
struct BackdropScrollTests {
    private func reading(_ offset: CGFloat, height: CGFloat = 5000) -> BackdropScroll.Reading {
        BackdropScroll.Reading(offset: offset, contentHeight: height)
    }

    @Test func theUsersScrollMovesIt() {
        let scroll = BackdropScroll(isFlipped: false)
        scroll.scrolled(reading(100))
        scroll.phaseChanged(.interacting)
        scroll.scrolled(reading(140))
        scroll.phaseChanged(.decelerating)
        scroll.scrolled(reading(150))
        #expect(scroll.shift == 50)
    }

    @Test func aScrollTheListMakesItselfLeavesItWhereItIs() {
        let scroll = BackdropScroll(isFlipped: false)
        scroll.scrolled(reading(0))
        scroll.scrolled(reading(4200))
        scroll.phaseChanged(.animating)
        scroll.scrolled(reading(3000))
        #expect(scroll.shift == 0)
    }

    @Test func olderRowsArrivingAboveWhileTheUserScrollsDontJumpIt() {
        let scroll = BackdropScroll(isFlipped: false)
        scroll.phaseChanged(.interacting)
        scroll.scrolled(reading(400))
        scroll.scrolled(reading(1600, height: 6200))
        scroll.scrolled(reading(1590, height: 6200))
        #expect(scroll.shift == -10)
    }

    /// Rows measured past the end as they come into view change the content's
    /// height in most frames of a scroll. Skipping those frames left the
    /// backdrop still through most of one.
    @Test func rowsMeasuredBelowWhileTheUserScrollsStillMoveIt() {
        let scroll = BackdropScroll(isFlipped: false)
        scroll.phaseChanged(.interacting)
        scroll.scrolled(reading(400))
        scroll.scrolled(reading(420, height: 5300))
        scroll.scrolled(reading(445, height: 5250))
        #expect(scroll.shift == 45)
    }

    @Test func theScrollToEndButtonsScrollMovesItAndOnlyThatOne() {
        let scroll = BackdropScroll(isFlipped: false)
        scroll.scrolled(reading(1000))
        scroll.followsNextAnimation = true
        scroll.phaseChanged(.animating)
        scroll.scrolled(reading(4000))
        scroll.phaseChanged(.idle)
        scroll.phaseChanged(.animating)
        scroll.scrolled(reading(4300))
        #expect(scroll.shift == 3000)
    }
}
