import Foundation
import SwiftUI
import Testing
@testable import Yapnest

/// One recognizer over the list finds the bubble under the pointer from the
/// frames the built rows report.
@MainActor
struct BubbleHoverTests {
    private let first = BubbleHover.Frame(bubble: CGRect(x: 112, y: 0, width: 200, height: 40), rowMinX: 100)
    private let second = BubbleHover.Frame(bubble: CGRect(x: 20, y: 50, width: 100, height: 40), rowMinX: 0)

    @Test func aPointInsideABubbleHitsItAcrossTheRow() {
        var hover = BubbleHover()
        hover.set(first, for: 1)
        hover.set(second, for: 2)
        #expect(hover.hit(at: CGPoint(x: 150, y: 20)) == 1)
        #expect(hover.hit(at: CGPoint(x: 30, y: 60)) == 2)
        #expect(first.span == 12...212)
    }

    @Test func aPointBetweenBubblesHitsNothing() {
        var hover = BubbleHover()
        hover.set(first, for: 1)
        hover.set(second, for: 2)
        #expect(hover.hit(at: CGPoint(x: 150, y: 45)) == nil)
    }

    @Test func aRemovedFrameStopsMatching() {
        var hover = BubbleHover()
        hover.set(first, for: 1)
        hover.set(nil, for: 1)
        #expect(hover.hit(at: CGPoint(x: 150, y: 20)) == nil)
    }

    /// A sent bubble sits on the right, so its bar starts at the bubble's left
    /// edge and sticks out past it by the corner's radius; a received one's
    /// ends that far past its right edge. Where the pointer came in doesn't
    /// move it.
    @Test func theBarLinesUpWithTheBubblesSideFacingTheMiddle() {
        let sent = BubbleHover.barMinX(width: 200, rowWidth: 800, bubble: 400...788, isOutgoing: true, hang: 14, margin: 12)
        #expect(sent == 386)
        let received = BubbleHover.barMinX(width: 200, rowWidth: 800, bubble: 12...400, isOutgoing: false, hang: 14, margin: 12)
        #expect(received == 214)
    }

    /// A bubble narrower than the bar pushes it back inside the row, past
    /// the bubble's outer side.
    @Test func theBarOfANarrowBubbleStaysInsideTheRow() {
        let sent = BubbleHover.barMinX(width: 200, rowWidth: 800, bubble: 700...788, isOutgoing: true, hang: 14, margin: 12)
        #expect(sent == 588)
        let received = BubbleHover.barMinX(width: 200, rowWidth: 800, bubble: 12...100, isOutgoing: false, hang: 14, margin: 12)
        #expect(received == 12)
    }

    @Test func enteringABubbleShowsTheBarByItsEdges() throws {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        model.bubbleFrameChanged(first, for: 1)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        #expect(model.hoveredBubble == 1)
        #expect(model.hoveredRow == 1)
        #expect(model.hoverState(for: 1).bubbleSpan == 12...212)
        model.pointerMoved(to: CGPoint(x: 150, y: 45))
        #expect(model.hoveredBubble == nil)
        #expect(model.hoveredRow == 1)
    }

    /// A reaction or an edit can widen the bubble under a shown bar, which
    /// has to keep to its edge.
    @Test func theShownBarFollowsItsBubbleWidening() throws {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        model.bubbleFrameChanged(first, for: 1)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        model.bubbleFrameChanged(BubbleHover.Frame(bubble: CGRect(x: 112, y: 0, width: 300, height: 40), rowMinX: 100), for: 1)
        #expect(model.hoverState(for: 1).bubbleSpan == 12...312)
    }

    @Test func aMoveAfterTheMenuOpenedSaysItClosed() throws {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: .hoverMenuClosed, object: model, queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        model.hoverMenuOpen = true
        model.pointerMoved(to: CGPoint(x: 0, y: 0))
        #expect(!model.hoverMenuOpen)
        #expect(closed == 1)
        model.pointerMoved(to: CGPoint(x: 1, y: 1))
        #expect(closed == 1)
    }

    @Test func scrollingHidesTheBarUntilThePointerMoves() throws {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        model.bubbleFrameChanged(first, for: 1)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        model.scrollPhase = .interacting
        model.scrollPhaseChangedForHover(.interacting)
        #expect(model.hoveredBubble == nil)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        #expect(model.hoveredBubble == nil)
        model.scrollPhase = .idle
        model.scrollPhaseChangedForHover(.idle)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        #expect(model.hoveredBubble == 1)
    }

    /// The Mac's tracker pauses SwiftUI's hover recognizers while the list
    /// moves, so it's told once when scrolling starts and once when it stops.
    @Test func theTrackerIsToldWhenScrollingStartsAndStops() throws {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        var told: [Bool] = []
        model.scrollingChanged = { told.append($0) }
        model.scrollPhaseChangedForHover(.interacting)
        model.scrollPhaseChangedForHover(.decelerating)
        model.scrollPhaseChangedForHover(.idle)
        model.scrollPhaseChangedForHover(.idle)
        #expect(told == [true, false])
    }
}
