import SwiftUI
import YapnestKit

/// A link's preview inside a bubble: the image itself for an image link, a
/// card with the page's image, site, title and description otherwise.
struct LinkPreviewCard: View {
    let display: PreviewDisplay
    let isOutgoing: Bool

    var body: some View {
        switch display {
        case .image(let preview, let url):
            PreviewImage(url: url, cornerRadii: .init(topLeading: 10, bottomLeading: 10, bottomTrailing: 10, topTrailing: 10))
                .aspectRatio(1 / ratio(of: preview, max: 1.33), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: MediaLimits.maxMediaHeight)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(String(localized: "Image"))
        case .page(let preview, let url):
            card(preview, imageURL: url)
        case .none, .ask:
            EmptyView()
        }
    }

    private func ratio(of preview: LinkPreview, max maxRatio: CGFloat) -> CGFloat {
        let size = preview.imageSize ?? CGSize(width: 16, height: 9)
        return min(max(size.height / size.width, 0.3), maxRatio)
    }

    private func card(_ preview: LinkPreview, imageURL: URL?) -> some View {
        // Wide images (OpenGraph's 1.91:1 cards) go on top; logos and
        // other small or squarish ones become a thumbnail.
        let isLarge = preview.imageSize.map { $0.width >= 400 && $0.width >= $0.height * 1.3 } ?? false
        return VStack(spacing: 0) {
            if isLarge, let imageURL {
                PreviewImage(url: imageURL, cornerRadii: .init(topLeading: 10, topTrailing: 10))
                    .aspectRatio(1 / ratio(of: preview, max: 1), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: MediaLimits.maxMediaHeight)
            }
            HStack(alignment: .top, spacing: 10) {
                if !isLarge, let imageURL {
                    PreviewImage(url: imageURL, cornerRadii: .init(topLeading: 6, bottomLeading: 6, bottomTrailing: 6, topTrailing: 6))
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let site = preview.siteName {
                        Text(site).font(.caption).opacity(0.7)
                    }
                    if let title = preview.title {
                        Text(title).font(.subheadline.bold()).lineLimit(2)
                    }
                    if let summary = preview.summary {
                        Text(summary).font(.footnote).lineLimit(3).opacity(0.85)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A filled shape rather than a clipped container: clipping a stack of
        // layers is an offscreen render pass per card.
        .background(RoundedRectangle(cornerRadius: 10).fill(isOutgoing ? Color.white.opacity(0.2) : Color(.systemFill)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([preview.siteName, preview.title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isLink)
    }
}

/// A preview's picture, decoded off the main thread; the layout already has
/// its size from the preview.
private struct PreviewImage: View {
    let url: URL
    /// Rounded on the picture's own layers: a clip on a group of them would be
    /// an offscreen pass.
    var cornerRadii = RectangleCornerRadii()
    /// Kept with its URL, so a different one doesn't show the old picture.
    @State private var loaded: (url: URL, image: UIImage)?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Color(.tertiarySystemFill)
            .clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii))
            .overlay {
                if let shown = loaded.flatMap({ $0.url == url ? $0.image : nil }) ?? PreviewImageCache.cached(url) {
                    // A fixed frame: a flexible one grows to the filled picture's size, so a clip on it crops nothing.
                    GeometryReader { proxy in
                        Image(uiImage: shown)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii))
                    }
                }
            }
            .task(id: url) {
                if let cached = PreviewImageCache.cached(url) {
                    // Kept here too, so evicting it from the cache can't blank the view.
                    loaded = (url, cached)
                    return
                }
                loaded = nil
                if let image = await PreviewImageCache.load(url, scale: scale) { loaded = (url, image) }
            }
            // Released with the row's visibility; see `MediaThumbnail`.
            .onDisappear { loaded = nil }
    }
}
