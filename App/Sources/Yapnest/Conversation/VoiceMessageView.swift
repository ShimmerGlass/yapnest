import SwiftUI
import YapnestKit

/// A sound inside its bubble: a play button, the sound's outline with how
/// far it has played, and its length. The bubble is the same size whether
/// the file has been downloaded or not and whether the outline has been
/// worked out, so nothing around it moves when they happen.
struct VoiceMessageView: View {
    let display: AttachmentDisplay
    let id: Int64
    let isOutgoing: Bool
    let progress: Double?
    /// What a tap does when there is nothing to play yet: download, retry or explain.
    let onTap: () -> Void
    /// A clip we failed to send explains that, through `onTap`, rather than playing.
    let isFailed: Bool
    /// Plays the file from a fraction of its length, or from the start if nil.
    let play: (URL, Double?) -> Void

    static let height: CGFloat = 40
    static let width: CGFloat = 220
    private static let spacing: CGFloat = 10

    private var playback: VoicePlayback { .shared }
    private var attachment: Attachment { display.attachment }

    /// The outline, kept with the file it was read from: the view lives on
    /// when the message's file changes.
    private struct Shape {
        var url: URL
        var bars: [UInt8]?
    }

    @State private var shape: Shape?
    /// What the outline measures, which a tap on it is a fraction of.
    @State private var waveformWidth = VoiceMessageView.width - VoiceMessageView.height - VoiceMessageView.spacing

    private var tint: Color { isOutgoing ? .white : .accentColor }

    /// The file, once it is here and nothing is being transferred.
    private var playableURL: URL? { progress == nil ? display.fileURL : nil }

    /// What a tap on the button or the outline does.
    static func playsOnTap(canPlay: Bool, isFailed: Bool) -> Bool { canPlay && !isFailed }

    var body: some View {
        let isCurrent = playback.current == id
        let seconds = isCurrent ? playback.seconds : 0
        HStack(spacing: Self.spacing) {
            AttachmentBadge(
                state: AttachmentStatus.badge(attachment, progress: progress, ready: playback.isPlaying(id) ? .pause : .play),
                isOverMedia: false, tint: tint,
            )
            .contentShape(Circle())
            .onTapGesture { primary() }
            .frame(width: Self.height, height: Self.height)
            VStack(alignment: .leading, spacing: 4) {
                WaveformBars(bars: shapeOfThisFile?.bars, played: isCurrent ? playback.playedFraction : 0, tint: tint)
                    .frame(height: 22)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { waveformWidth = $0 }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in seek(at: tap.location.x) })
                Text(detail(isCurrent: isCurrent, seconds: seconds))
                    .font(.caption.monospacedDigit())
                    .opacity(0.75)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width, minHeight: Self.height, maxHeight: Self.height)
        .contentShape(Rectangle())
        .onTapGesture { if urlToPlay == nil { onTap() } }
        .task(id: display.fileURL) { await loadShape() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([AttachmentStatus.spokenSound(attachment), attachment.duration.map(AudioFormat.clock)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(isCurrent ? AudioFormat.clock(TimeInterval(seconds)) : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { primary() }
    }

    private var shapeOfThisFile: Shape? {
        shape.flatMap { $0.url == display.fileURL ? $0 : nil }
    }

    private var urlToPlay: URL? {
        Self.playsOnTap(canPlay: playableURL != nil, isFailed: isFailed) ? playableURL : nil
    }

    private func primary() {
        if let url = urlToPlay { play(url, nil) } else { onTap() }
    }

    private func seek(at x: CGFloat) {
        guard let url = urlToPlay else {
            onTap()
            return
        }
        play(url, Double(min(max(x / waveformWidth, 0), 1)))
    }

    private func detail(isCurrent: Bool, seconds: Int) -> String {
        let length = attachment.duration.map(AudioFormat.clock)
        let played = AudioFormat.clock(TimeInterval(seconds))
        return AttachmentStatus.detail(
            display, progress: progress,
            remote: [length, display.sizeText].compactMap { $0 }.joined(separator: " · "),
            ready: isCurrent ? [played, length].compactMap { $0 }.joined(separator: " / ") : length ?? "",
        )
    }

    private func loadShape() async {
        guard let url = display.fileURL else { shape = nil; return }
        if let cached = VoiceShapeCache.cached(url) {
            shape = Shape(url: url, bars: cached.bars)
            return
        }
        shape = nil
        // Decoding the whole file is for a background thread; the result is
        // kept beside the file, so this happens once.
        let bars = await Task.detached(priority: .utility) { AudioWaveform.levels(for: url) }.value
        VoiceShapeCache.store(url, bars: bars)
        if display.fileURL == url { shape = Shape(url: url, bars: bars) }
    }
}

/// Outlines already worked out, so a bubble scrolled back into view has its
/// own in the first frame.
@MainActor
private enum VoiceShapeCache {
    final class Box {
        let bars: [UInt8]?
        init(bars: [UInt8]?) {
            self.bars = bars
        }
    }

    private static let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 300
        return cache
    }()

    static func cached(_ url: URL) -> Box? { cache.object(forKey: url as NSURL) }

    static func store(_ url: URL, bars: [UInt8]?) {
        cache.setObject(Box(bars: bars), forKey: url as NSURL)
    }
}

/// Vertical bars, the ones before `played` (0...1) in full colour. Until the
/// outline is known, or if the file has none, the bars are flat.
private struct WaveformBars: View {
    let bars: [UInt8]?
    let played: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let count = BarGeometry.capacity(in: size.width)
            for (index, level) in Self.resample(bars, to: count).enumerated() {
                let rect = BarGeometry.rect(x: CGFloat(index) * BarGeometry.step, level: level, in: size.height)
                let isPlayed = Double(index) / Double(count) < played
                context.fill(Path(roundedRect: rect, cornerRadius: BarGeometry.width / 2), with: .color(tint.opacity(isPlayed ? 1 : 0.35)))
            }
        }
    }

    /// `count` levels from 0 to 1, each the loudest of the bars it covers.
    static func resample(_ bars: [UInt8]?, to count: Int) -> [Double] {
        guard let bars, !bars.isEmpty else { return Array(repeating: 0.15, count: count) }
        return (0..<count).map { index in
            let start = index * bars.count / count
            let end = max(start + 1, (index + 1) * bars.count / count)
            let loudest = bars[start..<min(end, bars.count)].max() ?? 0
            return max(0.15, Double(loudest) / 255)
        }
    }
}
