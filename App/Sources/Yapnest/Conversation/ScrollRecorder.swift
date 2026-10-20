#if DEBUG
import SwiftUI

/// What the message list did, frame by frame, boiled down to the numbers a UI
/// test checks. A glitch of the list shows for a frame or two, which a test
/// looking at the screen now and then misses; the list reports every change
/// of its geometry here, so a frame that jumped is kept.
struct ScrollRecord: Equatable {
    /// How many geometry changes were seen.
    private(set) var samples = 0
    /// The farthest the list was from its bottom while it was to stay there:
    /// following the bottom, positioned and with nothing moving it. Anything
    /// but zero is a frame that showed the wrong place.
    private(set) var maxAway: CGFloat = 0
    /// How many times older messages came in above the rows on screen.
    private(set) var prepends = 0
    /// Of those, how many came in while the list was still or tracking a
    /// finger, the only ones whose shift can be measured: a list that is
    /// coasting moves by itself.
    private(set) var measuredPrepends = 0
    /// The most the topmost row on screen moved when older messages came in
    /// above it, which is to keep it still. Under a finger the scroll view's
    /// offset follows the finger, and a slow drag moves it a few points a
    /// frame, so what the offset moved is taken off: it is the user's, not
    /// the page's.
    private(set) var maxPrependShift: CGFloat = 0
    private(set) var rows = 0
    /// How far the list is scrolled from its top, so a test can tell how
    /// close the next older page is.
    private(set) var top: CGFloat = 0
    /// How many rows are at least partly on screen: the scroll view's last
    /// report, or the rows whose own frames overlap the view, if more. Zero
    /// with rows loaded is a blank list. Nothing here comes from the model.
    var visible: Int { max(reported, framedVisible) }
    /// What the scroll view last reported. After a scroll that ends on a tall
    /// row it can stay silent and go on saying none, though the row is drawn.
    private var reported = 0
    /// Where each row the lazy stack holds is, in the scroll view's space,
    /// as the row itself last measured it.
    private var frames: [Int64: (minY: CGFloat, maxY: CGFloat)] = [:]
    /// The scroll view's height, as it last reported.
    private var viewHeight: CGFloat = 0
    private var framedVisible: Int {
        frames.values.filter { $0.maxY > $0.minY && $0.maxY > 0 && $0.minY < viewHeight }.count
    }
    /// How many times the scroll to latest button's action ran. A test that
    /// tapped it tells a tap that never arrived from one that did nothing.
    private(set) var latestTaps = 0
    /// How many times the model nudged the list's margin to make the lazy
    /// stack lay out again while the list rested at its end. A list that
    /// shows its newest message there needs none.
    private(set) var endNudges = 0

    /// Whether the list has reached the bottom yet. The first geometry report
    /// comes before the scroll view applies its bottom anchor, in the same
    /// display frame, so it's never drawn and doesn't count as away. A list
    /// that never lands is caught by the UI tests' checks that the newest
    /// message and rows are on screen. A reset keeps it: it describes the
    /// list, not the count.
    private var landed = false
    private var firstRow: Int64?
    private var phase = ScrollPhase.idle
    /// The scroll view's content offset as of its latest report. The scroll
    /// view reports a frame's geometry before the rows in it, so the anchor
    /// is measured against the offset of its own frame.
    private var offset: CGFloat = 0
    private var anchor: (id: Int64, minY: CGFloat, offset: CGFloat)?
    /// Where the anchor was when the model took in older rows, before the
    /// list laid them out.
    private var anchorAtApply: (id: Int64, minY: CGFloat, offset: CGFloat)?
    /// Where the anchor was just before the rows above it changed, when, and
    /// whether a finger was on the list.
    private var anchorBeforePrepend: (id: Int64, minY: CGFloat, offset: CGFloat, at: TimeInterval, tracking: Bool)?
    /// How long after older rows come in the anchor's next move counts as
    /// theirs. A later one is the user scrolling.
    static let prependWindow: TimeInterval = 0.5

    static func == (lhs: ScrollRecord, rhs: ScrollRecord) -> Bool {
        lhs.summary == rhs.summary
    }

    /// One frame of the list. Both distances are as the user sees the list,
    /// the way up it is, as `ConversationModel` works them out.
    mutating func geometry(distanceFromBottom: CGFloat, distanceFromTop: CGFloat, viewHeight: CGFloat = 0, contentOffset: CGFloat = 0, followsBottom: Bool, isPositioned: Bool, phase: ScrollPhase) {
        samples += 1
        self.viewHeight = viewHeight
        offset = contentOffset
        top = distanceFromTop
        self.phase = phase
        guard followsBottom, isPositioned, phase == .idle else { return }
        if !landed {
            guard abs(distanceFromBottom) <= 1.5 else { return }
            landed = true
        }
        maxAway = max(maxAway, abs(distanceFromBottom))
    }

    /// The model is about to hand the list older rows. The list lays them
    /// out and reports the anchor's new place before the count's change is
    /// seen here, which would make a move in that same pass the baseline.
    mutating func olderRowsComing() {
        anchorAtApply = anchor
    }

    /// The rows changed: their count and the oldest's id.
    mutating func rowsChanged(count: Int, firstID: Int64?, at time: TimeInterval) {
        defer {
            rows = count
            firstRow = firstID
        }
        let applied = anchorAtApply
        anchorAtApply = nil
        guard let firstRow, let firstID, firstID != firstRow, count > rows, let anchor = applied ?? anchor else { return }
        prepends += 1
        guard phase == .idle || phase == .interacting else { return }
        measuredPrepends += 1
        anchorBeforePrepend = (anchor.id, anchor.minY, anchor.offset, time, phase == .interacting)
    }

    /// Where the topmost row on screen is, in the list's visible area. The
    /// row reports only when it moves, so one that stayed put leaves the
    /// shift at zero.
    mutating func anchorMeasured(id: Int64, minY: CGFloat, at time: TimeInterval) {
        if let before = anchorBeforePrepend {
            anchorBeforePrepend = nil
            if before.id == id, time - before.at <= Self.prependWindow {
                // A row's place in the content is its place on screen plus
                // the offset. Still, any move of the offset is the app's and
                // counts; under a finger the offset follows it.
                let shift = before.tracking ? abs((minY + offset) - (before.minY + before.offset)) : abs(minY - before.minY)
                maxPrependShift = max(maxPrependShift, shift)
            }
        }
        anchor = (id, minY, offset)
    }

    mutating func latestTapped() {
        latestTaps += 1
    }

    mutating func nudged() {
        endNudges += 1
    }

    mutating func visibleChanged(count: Int) {
        reported = count
    }

    /// A row measured where it is, or `nil` once the lazy stack let it go.
    mutating func rowFramed(id: Int64, minY: CGFloat?, maxY: CGFloat = 0) {
        frames[id] = minY.map { ($0, maxY) }
    }

    /// Starts counting again from the state the list is in now.
    mutating func reset() {
        samples = 0
        maxAway = 0
        prepends = 0
        measuredPrepends = 0
        maxPrependShift = 0
        latestTaps = 0
        endNudges = 0
        anchorBeforePrepend = nil
    }

    /// What a test reads, as `key=value` pairs.
    var summary: String {
        String(
            format: "samples=%d maxAway=%.1f prepends=%d measuredPrepends=%d maxPrependShift=%.1f rows=%d visible=%d top=%.0f latestTaps=%d endNudges=%d",
            samples, maxAway, prepends, measuredPrepends, maxPrependShift, rows, visible, top, latestTaps, endNudges,
        )
    }
}

/// Keeps a conversation's `ScrollRecord`, for UI tests and scripts. Only made
/// when asked for (`YAPNEST_DEV_RECORD=1`, or any fixture), so the list does
/// no more work otherwise.
@MainActor @Observable
final class ScrollRecorder {
    @ObservationIgnored private var record = ScrollRecord()
    /// The record's summary, updated a little after it changes rather than on
    /// every frame, so the probe isn't redrawn at the display's rate.
    private(set) var summary = ScrollRecord().summary
    @ObservationIgnored private var publishing: Task<Void, Never>?

    static func makeIfEnabled() -> ScrollRecorder? {
        let env = ProcessInfo.processInfo.environment
        return env["YAPNEST_DEV_RECORD"] == "1" || env["YAPNEST_DEV_FIXTURE"] != nil ? ScrollRecorder() : nil
    }

    func update(_ change: (inout ScrollRecord) -> Void) {
        change(&record)
        guard publishing == nil else { return }
        publishing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            publishing = nil
            summary = record.summary
        }
    }

    func reset() {
        update { $0.reset() }
    }
}

extension View {
    /// Has a row tell the recorder where it is, for the count of rows on
    /// screen that doesn't depend on the scroll view's reports or the model.
    @ViewBuilder
    func recordingFrame(of id: Int64, _ model: ConversationModel) -> some View {
        if let recorder = model.recorder {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .named("messageList")) } action: { frame in
                recorder.update { $0.rowFramed(id: id, minY: frame.minY, maxY: frame.maxY) }
            }
            .onDisappear { recorder.update { $0.rowFramed(id: id, minY: nil) } }
        } else {
            self
        }
    }

    /// Feeds the conversation's recorder, if it has one, and puts its probe
    /// over the list. After the list's own modifiers, so the probe isn't part
    /// of the list's tap that puts the keyboard away.
    @ViewBuilder
    func scrollRecording(_ model: ConversationModel) -> some View {
        if let recorder = model.recorder {
            onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                recorder.update {
                    $0.geometry(
                        distanceFromBottom: ConversationModel.distanceFromBottom(geometry, flipped: model.isFlipped),
                        distanceFromTop: ConversationModel.distanceFromTop(geometry, flipped: model.isFlipped),
                        viewHeight: geometry.containerSize.height, contentOffset: geometry.contentOffset.y, followsBottom: model.followsBottom,
                        isPositioned: model.hasLoaded && model.isPositioned, phase: model.scrollPhase,
                    )
                }
            }
            .onChange(of: model.rows.count, initial: true) {
                let (count, first) = (model.rows.count, model.rows.first?.id)
                recorder.update { $0.rowsChanged(count: count, firstID: first, at: ProcessInfo.processInfo.systemUptime) }
            }
            // Any part of a row, unlike the model's report, which wants half
            // of one: what's drawn at all, whatever the model makes of it.
            .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.01) { ids in
                FrameLog.event("recorder visible count=\(ids.count)")
                recorder.update { $0.visibleChanged(count: ids.count) }
            }
            // In the leading margin, halfway down, clear of the bars and the
            // composer that cover the list's ends.
            .overlay(alignment: .leading) { ScrollRecorderProbe(recorder: recorder) }
        } else {
            self
        }
    }
}

/// A sliver in the list's margin that UI tests read the record from (its
/// accessibility value) and reset it with (a tap).
struct ScrollRecorderProbe: View {
    let recorder: ScrollRecorder

    var body: some View {
        VStack(spacing: 24) {
            Button { recorder.reset() } label: {
                Color.clear
                    .frame(width: 6, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scrollRecorder")
            .accessibilityLabel("Scroll recorder")
            .accessibilityValue(recorder.summary)
            // Only where a fixture holds its downloads for the test to release.
            if PreviewsFixture.isHolding {
                Button { PreviewsFixture.releaseDownloads() } label: {
                    Color.clear
                        .frame(width: 6, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("releaseDownloads")
                .accessibilityLabel("Release downloads")
            }
        }
    }
}
#endif
