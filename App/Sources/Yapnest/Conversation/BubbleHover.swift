import CoreGraphics

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
    }

    /// The name of the list stack's coordinate space.
    static let space = "messageListStack"

    private var frames: [Int64: Frame] = [:]

    mutating func set(_ frame: Frame?, for id: Int64) {
        frames[id] = frame
    }

    /// The row whose bubble holds the point, and the point's x across that row.
    func hit(at point: CGPoint) -> (id: Int64, barX: CGFloat)? {
        for (id, frame) in frames where frame.bubble.contains(point) {
            return (id, point.x - frame.rowMinX)
        }
        return nil
    }
}
