import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Yapnest

/// A hover touches the boxes of the rows it leaves and enters, so the rows
/// that stay put are not drawn again.
@MainActor
struct RowHoverTests {
    private final class Flag: @unchecked Sendable { var value = false }

    private let first = BubbleHover.Frame(bubble: CGRect(x: 112, y: 0, width: 200, height: 40), rowMinX: 100)
    private let second = BubbleHover.Frame(bubble: CGRect(x: 20, y: 50, width: 100, height: 40), rowMinX: 0)
    private let third = BubbleHover.Frame(bubble: CGRect(x: 20, y: 100, width: 100, height: 40), rowMinX: 0)

    private func model() throws -> (ConversationFixture, ConversationModel) {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        model.bubbleFrameChanged(first, for: 1)
        model.bubbleFrameChanged(second, for: 2)
        model.bubbleFrameChanged(third, for: 3)
        return (fixture, model)
    }

    @Test func movingBetweenBubblesTouchesOnlyThoseRows() throws {
        let (fixture, model) = try model()
        let one = model.hoverState(for: 1), two = model.hoverState(for: 2), three = model.hoverState(for: 3)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        #expect(one.isBubbleHovered && one.isRowHovered)
        #expect(one.bubbleSpan == 12...212)

        let thirdChanged = Flag()
        withObservationTracking {
            _ = three.isBubbleHovered
            _ = three.isRowHovered
            _ = three.bubbleSpan
        } onChange: { thirdChanged.value = true }

        model.pointerMoved(to: CGPoint(x: 30, y: 60))
        #expect(!one.isBubbleHovered && !one.isRowHovered)
        #expect(two.isBubbleHovered && two.isRowHovered)
        #expect(!three.isBubbleHovered && !three.isRowHovered)
        #expect(!thirdChanged.value)
        _ = fixture
    }

    @Test func leavingABubbleKeepsItsRowButNotItsBubble() throws {
        let (_, model) = try model()
        let one = model.hoverState(for: 1)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        model.pointerMoved(to: CGPoint(x: 150, y: 45))
        #expect(!one.isBubbleHovered)
        #expect(one.isRowHovered)
    }

    @Test func scrollingClearsOnlyTheHoveredRowsBubble() throws {
        let (_, model) = try model()
        let one = model.hoverState(for: 1), two = model.hoverState(for: 2)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        let secondChanged = Flag()
        withObservationTracking {
            _ = two.isBubbleHovered
            _ = two.isRowHovered
        } onChange: { secondChanged.value = true }
        model.scrollPhase = .interacting
        model.scrollPhaseChangedForHover(.interacting)
        #expect(!one.isBubbleHovered)
        #expect(!secondChanged.value)
    }

    @Test func aStillPointerHoversTheBubbleUnderItWhenScrollingEnds() throws {
        let (_, model) = try model()
        let one = model.hoverState(for: 1)
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        model.scrollPhase = .interacting
        model.scrollPhaseChangedForHover(.interacting)
        #expect(!one.isBubbleHovered)
        model.scrollPhase = .idle
        model.scrollPhaseChangedForHover(.idle)
        #expect(one.isBubbleHovered)
        #expect(model.hoveredBubble == 1)
    }

    @Test func theTrackersPointerWinsOverTheLastOneSeen() throws {
        let (_, model) = try model()
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        model.scrollPhase = .interacting
        model.scrollPhaseChangedForHover(.interacting)
        model.currentPointer = { CGPoint(x: 30, y: 60) }
        model.scrollPhase = .idle
        model.scrollPhaseChangedForHover(.idle)
        #expect(model.hoveredBubble == 2)
    }

    @Test func aPointerThatLeftHoversNothingWhenScrollingEnds() throws {
        let (_, model) = try model()
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        model.pointerMoved(to: nil)
        model.scrollPhase = .interacting
        model.scrollPhaseChangedForHover(.interacting)
        model.scrollPhase = .idle
        model.scrollPhaseChangedForHover(.idle)
        #expect(model.hoveredBubble == nil)
    }

    @Test func aBoxMadeLateKnowsWhoIsHovered() throws {
        let (_, model) = try model()
        model.pointerMoved(to: CGPoint(x: 150, y: 20))
        let late = model.hoverState(for: 1)
        #expect(late.isBubbleHovered && late.isRowHovered)
    }

    @Test func boxesOfRowsNoLongerPresentAreDropped() async throws {
        let fixture = try ConversationFixture(isFlipped: false)
        let model = fixture.model!
        try fixture.add("one")
        await fixture.start()
        let kept = model.hoverState(for: model.rows[0].id)
        let gone = model.hoverState(for: 99_999)
        #expect(model.hoverState(for: 99_999) === gone)
        try fixture.add("two")
        await eventually("two rows") { model.rows.count == 2 }
        #expect(model.hoverState(for: model.rows[0].id) === kept)
        #expect(model.hoverState(for: 99_999) !== gone)
    }

    @Test func linksAreDrawnInTheLinkStyleAndOtherTextInTheDefaultColour() {
        let url = URL(string: "https://example.com")!
        let text = NSMutableAttributedString(string: "see link now", attributes: [.font: UIFont.systemFont(ofSize: 14)])
        text.addAttribute(.link, value: url, range: NSRange(location: 4, length: 4))
        for outgoing in [false, true] {
            let display = SelectableTextStyle.displayText(text, isOutgoing: outgoing)
            #expect(display.string == text.string)
            let plain = display.attributes(at: 0, effectiveRange: nil)
            #expect(plain[.foregroundColor] as? UIColor == (outgoing ? .white : .label))
            #expect(plain[.underlineStyle] == nil)
            let link = display.attributes(at: 5, effectiveRange: nil)
            #expect(link[.foregroundColor] as? UIColor == (outgoing ? .white : SelectableTextStyle.receivedAccent))
            #expect(link[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
            #expect(link[.font] as? UIFont == UIFont.systemFont(ofSize: 14))
            // Drawn, a link run would be the system's blue whatever its colour.
            #expect(link[.link] == nil)
        }
    }
}
