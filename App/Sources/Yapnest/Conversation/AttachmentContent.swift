import SwiftUI
import UniformTypeIdentifiers
import YapnestKit

/// A message's file inside its bubble: the picture for images and videos,
/// a row with the file's name otherwise, with download and progress state.
struct AttachmentContent: View {
    let display: AttachmentDisplay
    let id: Int64
    let isOutgoing: Bool
    let transfers: TransferProgress

    private var attachment: Attachment { display.attachment }
    private var isMedia: Bool { attachment.isImage || attachment.isVideo }

    var body: some View {
        TransferReader(item: transfers.item(for: id)) { progress in
            content(progress: progress)
        }
    }

    private func content(progress: Double?) -> some View {
        Group {
            if isMedia {
                MediaThumbnail(display: display, badge: badge(progress: progress, media: true))
                    .background(TransitionAnchor(id: id))
            } else {
                fileRow(progress: progress)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([attachment.summary, detail(progress: progress)].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    private func fileRow(progress: Double?) -> some View {
        HStack(spacing: 10) {
            AttachmentBadge(state: badge(progress: progress, media: false), isOverMedia: false, tint: isOutgoing ? .white : .accentColor)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.isContact ? attachment.contactName : attachment.name)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(detail(progress: progress))
                    .font(.caption)
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The blank part beside the text counts as the row too.
        .contentShape(Rectangle())
    }

    private func badge(progress: Double?, media: Bool) -> AttachmentBadge.State {
        if let progress { return .progress(progress) }
        switch attachment.state {
        case .remote, .offered: return .download
        case .downloadFailed: return .failed
        case .unavailable: return .unavailable
        case .pendingUpload, .ready:
            if media { return attachment.isVideo ? .play : .hidden }
            return attachment.isContact ? .contact : .file
        }
    }

    private func detail(progress: Double?) -> String {
        let size = display.sizeText
        if let progress {
            return [size, String(localized: "\(Int(progress * 100))%")].compactMap { $0 }.joined(separator: " · ")
        }
        switch attachment.state {
        case .remote, .offered: return [size, String(localized: "Tap to download")].compactMap { $0 }.joined(separator: " · ")
        case .downloadFailed: return String(localized: "Couldn't download · Tap to retry")
        case .unavailable: return String(localized: "No longer available")
        case .pendingUpload, .ready:
            return [size, attachment.isContact ? String(localized: "Contact") : attachment.type?.localizedDescription].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Reads one transfer's progress, so only the content that shows it is
/// drawn again as it advances.
private struct TransferReader<Content: View>: View {
    let item: TransferProgress.Item?
    @ViewBuilder let content: (Double?) -> Content

    var body: some View {
        content(item?.value)
    }
}

/// The picture of a photo or video. Its shape comes from the size the message
/// announced, so it's the right height before the file has been read, and
/// doesn't change when the picture shows up.
private struct MediaThumbnail: View {
    let display: AttachmentDisplay
    let badge: AttachmentBadge.State
    /// Kept with the file it was read from: the view lives on when the
    /// message's file changes, and the old picture must not stay.
    @State private var loaded: (url: URL, image: UIImage)?
    /// What to do with a GIF, found from its header before anything is
    /// decoded. Kept with its file, like `loaded`.
    @State private var gif: (url: URL, mode: GifMode)?
    /// The sender's tiny preview, decoded off the main thread, shown blurred
    /// by upscaling until the file is here.
    @State private var preview: UIImage?

    private enum GifMode {
        /// Plays `file`: the GIF itself if it's small, else a smaller copy.
        case play(file: URL)
        /// Too big to play, and the copy is being made, or can't be.
        case still
        /// Too big to decode at all.
        case tooLarge
    }

    var body: some View {
        let size = display.attachment.imageSize ?? CGSize(width: 4, height: 3)
        let ratio = min(max(size.height / size.width, 0.5), 1.33)
        Color(.tertiarySystemFill)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .aspectRatio(1 / ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: MediaLimits.maxMediaHeight)
            .overlay {
                if display.fileURL == nil, let preview {
                    // Smoothed on the way up, which is the blur: drawing it
                    // through a blur filter would cost an offscreen pass per bubble.
                    GeometryReader { proxy in
                        Image(uiImage: preview)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .overlay {
                if let shown = display.fileURL.flatMap({ url in loaded.flatMap { $0.url == url ? $0.image : nil } ?? ThumbnailCache.cached(url) }) {
                    // A fixed frame: a flexible one grows to the filled picture's size, so a clip on it crops nothing.
                    GeometryReader { proxy in
                        Image(uiImage: shown)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .overlay {
                // The still above stays underneath, so there's no blank frame
                // while the animation starts.
                if let gif, gif.url == display.fileURL {
                    switch gif.mode {
                    case .play(let file): AnimatedImageView(url: file, cornerRadius: 12)
                    case .still: EmptyView()
                    case .tooLarge: tooLargePlaceholder
                    }
                }
            }
            .overlay {
                AttachmentBadge(state: badge, isOverMedia: true, tint: .white)
                    .frame(width: 48, height: 48)
            }
            // The corners are clipped on the picture layers themselves, not on
            // this stack: clipping a stack of layers is an offscreen render pass
            // per bubble, which made push animations GPU bound, while a clip on
            // a single layer is free.
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .task(id: display.attachment.thumbnail) {
                guard display.fileURL == nil, let data = display.attachment.thumbnail else { preview = nil; return }
                // The data was checked and shrunk when it arrived (`FileMetadata`).
                preview = await UIImage(data: data)?.byPreparingForDisplay()
            }
            .task(id: display.fileURL) {
                guard let url = display.fileURL else { loaded = nil; gif = nil; return }
                if display.attachment.type?.conforms(to: .gif) == true {
                    await planGif(at: url)
                } else {
                    gif = nil
                }
                if let cached = ThumbnailCache.cached(url) {
                    // Kept here too, so evicting it from the cache can't blank the view.
                    loaded = (url, cached)
                    return
                }
                loaded = nil
                // Nil for a GIF too large to decode, which leaves the placeholder.
                if let image = await ThumbnailCache.load(url, video: display.attachment.isVideo) { loaded = (url, image) }
            }
            // A lazy stack keeps the state of rows it has scrolled past, and
            // a decoded picture is megabytes. The task above fills it again
            // on return, and the body reads the cache meanwhile, so a hit
            // shows without a blank frame.
            .onDisappear { loaded = nil; gif = nil }
    }

    /// Big GIFs aren't played as they are: decoding a frame takes the whole
    /// canvas, and a peer can send one that's hundreds of megabytes a frame.
    private func planGif(at url: URL) async {
        let header = await Task.detached { AnimatedImages.header(of: url) }.value
        guard let header else {
            gif = (url, .still)
            return
        }
        switch header.plan {
        case .play:
            gif = (url, .play(file: url))
        case .tooLarge:
            gif = (url, .tooLarge)
        case .downsample:
            gif = (url, .still)
            // With Reduce Motion the still is all that's wanted.
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            if let copy = await AnimatedGifCopies.copy(of: url, header: header), display.fileURL == url {
                gif = (url, .play(file: copy))
            }
        }
    }

    private var tooLargePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.fill").font(.largeTitle)
            Text("Too large to preview").font(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill)))
    }
}

/// The round glyph over media and beside files: download, progress, play, failure.
struct AttachmentBadge: View {
    enum State: Equatable {
        case hidden, download, failed, unavailable, play, file, contact
        case progress(Double)
    }

    let state: State
    let isOverMedia: Bool
    let tint: Color

    var body: some View {
        let color: Color = isOverMedia ? .white : tint
        ZStack {
            Circle().fill(isOverMedia ? Color.black.opacity(0.45) : tint.opacity(0.18))
            if case .progress(let value) = state {
                Circle().stroke(color.opacity(0.25), lineWidth: 3).padding(4)
                Circle()
                    .trim(from: 0, to: max(0.03, value))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .opacity(state == .hidden ? 0 : 1)
    }

    private var symbol: String? {
        switch state {
        case .hidden, .progress: nil
        case .download: "arrow.down"
        case .failed: "arrow.clockwise"
        // Nothing to retry: the offer it came from is over.
        case .unavailable: "xmark"
        case .play: "play.fill"
        case .file: "doc.fill"
        case .contact: "person.fill"
        }
    }
}
