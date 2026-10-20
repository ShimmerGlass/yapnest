import CoreGraphics
import Foundation

/// Which texts the composer holds and which of them still has to be written
/// as the chat's draft. Only what the user types is typing: text the model
/// puts in itself (a restored draft, an edit put away, the clear after a
/// send) goes through `restore` or `typed` without telling the contact.
public struct DraftTracker: Sendable, Equatable {
    /// What the composer holds, apart from an edit's text.
    public private(set) var composerText = ""
    /// What was last noted for saving.
    public private(set) var draftText = ""
    /// Whether `draftText` still has to be written.
    public private(set) var isDirty = false

    public init() {}

    /// The composer's text changed to `text`. An edit's text isn't a draft;
    /// what was there before it stays. True when a save should be scheduled.
    @discardableResult
    public mutating func typed(_ text: String, editing: Bool) -> Bool {
        guard !editing else { return false }
        composerText = text
        return note()
    }

    /// Notes `composerText` as the draft to save.
    @discardableResult
    public mutating func note() -> Bool {
        guard composerText != draftText else { return false }
        draftText = composerText
        isDirty = true
        return true
    }

    /// A stored draft was put in the composer. It's already stored, so it
    /// isn't saved again.
    public mutating func restore(_ text: String) {
        composerText = text
        draftText = text
    }

    /// The text to write now, if the draft changed since the last write.
    public mutating func flush() -> String? {
        guard isDirty else { return nil }
        isDirty = false
        return draftText
    }
}

/// Whether a text view has to be measured again. Its width changes with
/// rotation and window size; its font with the text size setting, which may
/// not change the width at all.
public struct FitTrigger: Sendable, Equatable {
    private var width: CGFloat = 0
    private var pointSize: CGFloat = 0

    public init() {}

    /// True when `width` or `pointSize` differs from the last one seen.
    public mutating func changed(width: CGFloat, pointSize: CGFloat) -> Bool {
        guard width != self.width || pointSize != self.pointSize else { return false }
        self.width = width
        self.pointSize = pointSize
        return true
    }
}

/// Where a horizontal row of composer items is scrolled to. A scroll view
/// doesn't mirror its content, so the offset for an end depends on the
/// layout direction.
public enum ComposerRowOffset {
    /// The start of the row's reading order, or its end.
    public enum End: Sendable { case leading, trailing }

    public static func x(contentWidth: CGFloat, frameWidth: CGFloat, rightToLeft: Bool, showing end: End) -> CGFloat {
        let overflow = max(0, contentWidth - frameWidth)
        switch (end, rightToLeft) {
        case (.leading, false), (.trailing, true): return 0
        case (.leading, true), (.trailing, false): return overflow
        }
    }
}
