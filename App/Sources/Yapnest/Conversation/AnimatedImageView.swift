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
    private var reducesMotion = UIAccessibility.isReduceMotionEnabled

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
        for name in [UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isInBackground = window?.windowScene?.activationState == .background
        restart()
    }

    /// Only a backgrounded scene stops the animation. An inactive one is
    /// still visible, such as a Mac window that lost focus.
    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        // Tracked from the notifications: on the way back the scene's state
        // still says background when `willEnterForeground` is posted.
        isInBackground = notification.name == UIScene.didEnterBackgroundNotification
        restart()
    }

    private var isInBackground = false

    @objc private func reduceMotionChanged() {
        reducesMotion = UIAccessibility.isReduceMotionEnabled
        restart()
    }

    /// Reading a header opens the file, and `restart()` runs each time a row
    /// scrolls back into view, so the answer is kept. Files in the store don't
    /// change under a name.
    private static var headers: [URL: AnimatedImages.Header?] = [:]

    private static func remember(_ header: AnimatedImages.Header?, ofFile url: URL) {
        if headers.count >= 64 { headers.removeAll() }
        headers[url] = .some(header)
    }

    private nonisolated static func parseHeader(of source: AnimatedImageView.Source) -> AnimatedImages.Header? {
        switch source {
        case .data(let data): AnimatedImages.header(of: data)
        case .file(let url): AnimatedImages.header(of: url)
        }
    }

    private func restart() {
        player?.cancel()
        player = nil
        guard window != nil, !isInBackground else { return }
        guard let source else {
            imageView.image = nil
            return
        }
        // Playing or even reading a frame of a big GIF decodes its whole
        // canvas; callers hand over a smaller copy of those, and this is the
        // last line of defense. Reading the header opens the file, so that
        // happens in the task too, unless a file's is already known.
        let known: AnimatedImages.Header??
        if case .file(let url) = source { known = Self.headers[url] } else { known = nil }
        // Frames are drawn at the size the view has now; a view that is
        // resized later keeps them, scaled by the image view.
        let side = bounds.isEmpty
            ? AnimatedImages.downsampledSide
            : Int((max(bounds.width, bounds.height) * traitCollection.displayScale).rounded(.up))
        let stillOnly = reducesMotion
        player = Task.detached(priority: .userInitiated) { [weak self] in
            let header: AnimatedImages.Header?
            if let known {
                header = known
            } else {
                header = Self.parseHeader(of: source)
                if case .file(let url) = source { await MainActor.run { Self.remember(header, ofFile: url) } }
            }
            guard header?.plan == .play else {
                await MainActor.run {
                    guard let view = self, !Task.isCancelled else { return }
                    view.imageView.image = nil
                    view.player = nil
                }
                return
            }
            guard let frames = Self.frames(of: source) else {
                await MainActor.run { self?.imageView.image = nil }
                return
            }
            var next = ContinuousClock.now
            var index = 0
            while !Task.isCancelled {
                guard let image = frames.image(at: index, maxSide: side) else {
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
