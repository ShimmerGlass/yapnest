import ImageIO
import SwiftUI
import YapnestKit

/// Plays a GIF from data or a file. ImageIO decodes the frames as they're
/// needed, so a long GIF doesn't sit in memory as a stack of bitmaps, and the
/// animation only runs while the view is on screen, which keeps the rows of
/// the lazy list that scrolled away free. The frames are decoded in a task of
/// our own, because ImageIO's animator decodes on the main queue, where each
/// frame costs ten milliseconds or so and makes scrolling and keyboard
/// animations drop frames. The main thread only swaps in the finished image.
struct AnimatedImageView: UIViewRepresentable {
    enum Source: Equatable {
        case data(Data)
        case file(URL)
    }

    let source: Source
    /// Rounds the picture's own layer, which clips in place. The container
    /// can't do it: clipping a layer that has sublayers is an offscreen pass.
    let cornerRadius: CGFloat

    init(data: Data, cornerRadius: CGFloat = 0) {
        source = .data(data)
        self.cornerRadius = cornerRadius
    }

    init(url: URL, cornerRadius: CGFloat = 0) {
        source = .file(url)
        self.cornerRadius = cornerRadius
    }

    func makeUIView(context: Context) -> AnimatedUIImageView {
        AnimatedUIImageView()
    }

    func updateUIView(_ view: AnimatedUIImageView, context: Context) {
        view.source = source
        view.cornerRadius = cornerRadius
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnimatedUIImageView, context: Context) -> CGSize? {
        // It fills what its container gives it, whatever the picture's size.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Whether a GIF should be running. A scene that is merely inactive, such as
/// a Mac window that lost focus, keeps playing; one that is in the background
/// or can't be seen (the screen locked or asleep, the app covered whole) has
/// no use for frames, and the frame loop is timed by sleeping, so nothing else
/// would slow it down.
struct AnimatedPlaybackGate: Equatable {
    var inWindow = false
    var sceneInBackground = false
    var occluded = false
    var reducesMotion = false

    /// Whether frames are decoded at all. Reduce motion still shows the first.
    var showsFrames: Bool { inWindow && !sceneInBackground && !occluded }
    var animates: Bool { showsFrames && !reducesMotion }
}

final class AnimatedUIImageView: UIView {
    var source: AnimatedImageView.Source? {
        didSet {
            guard source != oldValue else { return }
            restart()
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet { imageView.layer.cornerRadius = cornerRadius }
    }

    private let imageView = UIImageView()
    private var player: Task<Void, Never>?
    var isAnimating: Bool { player != nil }
    var image: UIImage? { imageView.image }
    private(set) var gate = AnimatedPlaybackGate(
        occluded: !Platform.isWindowVisible,
        reducesMotion: UIAccessibility.isReduceMotionEnabled,
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        // It's only a picture: taps and the context menu belong to the
        // SwiftUI views around it.
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil,
        )
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(occlusionChanged),
            name: Platform.windowVisibilityDidChange, object: nil,
        )
        for name in [UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification] {
            center.addObserver(self, selector: #selector(sceneStateChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        gate.inWindow = window != nil
        gate.sceneInBackground = window?.windowScene?.activationState == .background
        restart()
    }

    /// Only a backgrounded scene stops the animation. An inactive one is
    /// still visible, such as a Mac window that lost focus.
    @objc private func sceneStateChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        // Tracked from the notifications: on the way back the scene's state
        // still says background when `willEnterForeground` is posted.
        update { $0.sceneInBackground = notification.name == UIScene.didEnterBackgroundNotification }
    }

    @objc private func reduceMotionChanged() {
        update { $0.reducesMotion = UIAccessibility.isReduceMotionEnabled }
    }

    @objc private func occlusionChanged() {
        setOccluded(!Platform.isWindowVisible)
    }

    func setOccluded(_ occluded: Bool) {
        update { $0.occluded = occluded }
    }

    /// Restarts only when the answer changes, so a notification that repeats
    /// what is already known doesn't restart a running GIF from its first frame.
    private func update(_ change: (inout AnimatedPlaybackGate) -> Void) {
        let before = gate
        change(&gate)
        if gate != before { restart() }
    }

    /// Reading a header opens the file, and `restart()` runs each time a row
    /// scrolls back into view, so whether the file plays is kept. Files in the
    /// store don't change under a name.
    private static var playable: [URL: Bool] = [:]

    private static func remember(_ isPlayable: Bool, ofFile url: URL) {
        if playable.count >= 64 { playable.removeAll() }
        playable[url] = isPlayable
    }

    private nonisolated static func isPlayable(_ source: AnimatedImageView.Source) -> Bool {
        let header = switch source {
        case .data(let data): AnimatedImages.header(of: data)
        case .file(let url): AnimatedImages.header(of: url)
        }
        return header?.plan == .play
    }

    private func restart() {
        player?.cancel()
        player = nil
        // Pausing leaves the frame on show; resuming starts the loop again.
        guard gate.showsFrames else { return }
        guard let source else {
            imageView.image = nil
            return
        }
        // Playing or even reading a frame of a big GIF decodes its whole
        // canvas; callers hand over a smaller copy of those, and this is the
        // last line of defense. Reading the header opens the file, so that
        // happens in the task too, unless a file's is already known.
        let known: Bool?
        if case .file(let url) = source { known = Self.playable[url] } else { known = nil }
        // Frames are drawn at the size the view has now; a view that is
        // resized later keeps them, scaled by the image view.
        let side = bounds.isEmpty
            ? AnimatedImages.downsampledSide
            : Int((max(bounds.width, bounds.height) * traitCollection.displayScale).rounded(.up))
        let stillOnly = !gate.animates
        player = Task.detached(priority: .userInitiated) { [weak self] in
            let playable: Bool
            if let known {
                playable = known
            } else {
                playable = Self.isPlayable(source)
                if case .file(let url) = source { await MainActor.run { Self.remember(playable, ofFile: url) } }
            }
            guard playable, let frames = Self.frames(of: source) else {
                await MainActor.run {
                    guard let view = self, !Task.isCancelled else { return }
                    view.imageView.image = nil
                    view.player = nil
                }
                return
            }
            var next = ContinuousClock.now
            var index = 0
            // A single frame or a still never loops, so it keeps nothing.
            let cache = (stillOnly || frames.count == 1) ? nil : frames.canvasSize.flatMap { size in
                AnimatedImages.FrameCache(frames: frames.count, width: size.width, height: size.height, maxSide: side) {
                    frames.image(at: $0, maxSide: side)
                }
            }
            while !Task.isCancelled {
                let decoded = if let cache { cache.image(at: index) } else { frames.image(at: index, maxSide: side) }
                guard let image = decoded else {
                    // A frame that won't decode ends the animation on the last good one.
                    return
                }
                let shown = await MainActor.run { () -> Bool in
                    guard let view = self, !Task.isCancelled else { return false }
                    view.imageView.image = UIImage(cgImage: image)
                    return true
                }
                if !shown || stillOnly || frames.count == 1 { return }
                // From the previous deadline, so decoding time doesn't add to
                // the delay. A deadline already past restarts from now: a slow
                // decode must not be followed by a burst of catch-up frames.
                next += frames.delay(at: index)
                let now = ContinuousClock.now
                if next > now {
                    try? await Task.sleep(until: next, clock: .continuous)
                } else {
                    next = now
                }
                index = (index + 1) % frames.count
            }
        }
    }

    private nonisolated static func frames(of source: AnimatedImageView.Source) -> AnimatedImages.Frames? {
        switch source {
        case .data(let data): AnimatedImages.Frames(data: data)
        case .file(let url): AnimatedImages.Frames(url: url)
        }
    }
}

/// Smaller copies of GIFs that are too big to play, made once each, in the
/// background.
@MainActor
enum AnimatedGifCopies {
    private static var running: [URL: Task<URL?, Never>] = [:]

    /// The copy of the GIF at `url`, made if it isn't there yet. Nil if it
    /// can't be made.
    static func copy(of url: URL, header: AnimatedImages.Header) async -> URL? {
        let copy = AnimatedImages.copyURL(for: url)
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        guard header.canDownsample else { return nil }
        if let task = running[url] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> URL? in
            do {
                try AnimatedImages.downsample(url, to: copy)
                return copy
            } catch {
                return nil
            }
        }
        running[url] = task
        let result = await task.value
        running[url] = nil
        return result
    }
}
