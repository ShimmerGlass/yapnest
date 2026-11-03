import CoreGraphics
import Observation

/// Where the built rows' bubbles are, so one pointer recognizer can tell which
/// the pointer is on. Per-row hover handlers made SwiftUI hit-test every row
/// on each pointer move and scroll frame, which took tenths of a second at a
/// time on a long chat.
struct BubbleHover {
    struct Frame: Equatable {
        /// The bubble, in the list stack's space.
        var bubble: CGRect
        /// Where the row's full-width container starts in that space, which
        /// the hover bar is laid out in.
        var rowMinX: CGFloat

        /// The bubble's left and right edges across its row.
        var span: ClosedRange<CGFloat> { (bubble.minX - rowMinX)...(bubble.maxX - rowMinX) }
    }

    /// The name of the list stack's coordinate space.
    static let space = "messageListStack"

    private var frames: [Int64: Frame] = [:]
    /// The shown hover bar, in the same space, and the row it belongs to.
    /// It sticks up over the row above, so the pointer on its way to a
    /// button can be on that row's bubble too.
    private var bar: (id: Int64, frame: CGRect)?

    mutating func set(_ frame: Frame?, for id: Int64) {
        frames[id] = frame
    }

    /// The row's bar was drawn there, or went (`nil`).
    mutating func setBar(_ frame: CGRect?, for id: Int64) {
        if let frame {
            bar = (id, frame)
        } else if bar?.id == id {
            bar = nil
        }
    }

    func frame(of id: Int64) -> Frame? { frames[id] }

    /// The row whose bubble holds the point. The bar is drawn over the
    /// bubbles and wins over them: the one under it would otherwise take the
    /// hover, and the bar would go before it could be clicked.
    func hit(at point: CGPoint) -> Int64? {
        if let bar, bar.frame.contains(point) { return bar.id }
        return frames.first { $0.value.bubble.contains(point) }?.key
    }

    /// Where the hover bar's left edge goes across a row `rowWidth` wide. It
    /// lines up with the bubble's side that faces the middle of the list, so
    /// it stands in the same place on every message from that side whatever
    /// the pointer did, and sticks out past it by `hang` so its corner clears
    /// the bubble's rounded one. It stays `margin` inside the row.
    static func barMinX(width: CGFloat, rowWidth: CGFloat, bubble: ClosedRange<CGFloat>, isOutgoing: Bool, hang: CGFloat, margin: CGFloat) -> CGFloat {
        let x = isOutgoing ? bubble.lowerBound - hang : bubble.upperBound + hang - width
        return min(max(x, margin), rowWidth - margin - width)
    }
}

/// What one row needs to know about the pointer. A box of its own per row, so
/// a move from one bubble to another redraws those two rows and not every
/// row the list has built.
@Observable
final class RowHover {
    /// The pointer is on this row's bubble now.
    var isBubbleHovered = false
    /// This row was the last one entered, which is the only one to show its bar.
    var isRowHovered = false
    /// The bubble's left and right edges across the row, which the bar is
    /// placed by. Kept only for the row that shows its bar.
    var bubbleSpan: ClosedRange<CGFloat> = 0...0
}
