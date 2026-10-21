import SwiftUI
import UIKit
import YapnestKit

/// A contact's picture, or their initials on a color derived from their
/// address, with an optional availability dot.
struct AvatarView: View {
    let name: String
    let seed: String
    var imageURL: URL?
    /// nil hides the dot, for contacts whose presence we don't receive.
    var presence: ContactPresence?
    /// Group chats show a group glyph rather than initials.
    var isGroup = false
    /// Drawn larger than about 80 pt, so it is decoded at a higher resolution.
    var isLarge = false

    /// What the off-main decode produced, with the file it came from so a
    /// changed picture never shows the old one.
    @State private var decoded: (url: URL, image: UIImage)?

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .green, .mint, .cyan]

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            picture(size: size)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if let presence {
                        PresenceDot(presence: presence)
                            .frame(width: size * 0.3, height: size * 0.3)
                            .offset(x: size * 0.02, y: size * 0.02)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .task(id: imageURL) { await decodeIfNeeded() }
    }

    /// A hit draws on the first frame; only a miss is decoded here, off the
    /// main thread, with the initials showing meanwhile.
    private var image: UIImage? {
        guard let imageURL else { return nil }
        if let cached = AvatarImageCache.cached(at: imageURL, large: isLarge) { return cached }
        if let decoded, decoded.url == imageURL { return decoded.image }
        return nil
    }

    private func decodeIfNeeded() async {
        guard let url = imageURL else { return }
        if let cached = AvatarImageCache.cached(at: url, large: isLarge) {
            // Kept here too, so evicting it from the cache can't blank the view.
            decoded = (url, cached)
            return
        }
        // The file may not be there yet if the download is still landing, so
        // look again a few times before leaving the initials.
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if Task.isCancelled { return }
            if let image = await AvatarImageCache.load(at: url, large: isLarge) {
                decoded = (url, image)
                return
            }
        }
    }

    @ViewBuilder private func picture(size: CGFloat) -> some View {
        if let image {
            // Pinned to the square, as a photo that isn't one would otherwise
            // keep its own width and sit off-centre.
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        } else {
            let color = Self.palette[Int(UInt(bitPattern: seed.stableHash) % UInt(Self.palette.count))]
            Circle()
                .fill(color.opacity(0.2))
                .overlay {
                    if isGroup {
                        GeometryReader { proxy in
                            Image(systemName: "person.2.fill")
                                .font(.system(size: proxy.size.width * 0.36))
                                .foregroundStyle(color)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        Text(initials)
                            .font(.system(size: (size * 0.4).rounded(), weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundStyle(color)
                    }
                }
        }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    private var accessibilityText: Text {
        guard let presence else { return Text(name) }
        return Text("\(name), \(presence.title)")
    }
}

/// The colored availability dot, ringed so it stands out against the picture.
struct PresenceDot: View {
    let presence: ContactPresence

    var body: some View {
        Circle()
            .fill(presence.color)
            .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
    }
}

extension ContactPresence {
    var color: Color {
        switch self {
        case .online: .green
        case .away: .yellow
        case .busy: .red
        case .offline: .gray
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .online: "online"
        case .away: "away"
        case .busy: "busy"
        case .offline: "offline"
        }
    }
}

/// Decoded avatars, keyed by file and size; the files are named by content
/// hash, so an entry never goes stale.
enum AvatarImageCache {
    // NSCache is thread-safe; lookups come from `body`, decoding from a task.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Bytes of decoded pixels, about 32 MB.
        cache.totalCostLimit = 32_000_000
        return cache
    }()

    private static func key(_ url: URL, large: Bool) -> NSString {
        (url.absoluteString + (large ? "#large" : "")) as NSString
    }

    static func cached(at url: URL, large: Bool) -> UIImage? {
        cache.object(forKey: key(url, large: large))
    }

    /// Decodes at 256 px, which covers an avatar up to 80 pt at 3x, or at
    /// 512 px for the larger ones (140 pt on the call screen), as the file
    /// comes from other people and may be far larger than an avatar.
    static func load(at url: URL, large: Bool) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if let image = cached(at: url, large: large) { return image }
            guard let cgImage = AvatarStore.thumbnail(at: url, pixels: large ? 512 : 256) else { return nil }
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: key(url, large: large), cost: cgImage.bytesPerRow * cgImage.height)
            return image
        }.value
    }
}

extension String {
    /// FNV-1a; `hashValue` is randomized per launch, which would reshuffle avatar colors.
    var stableHash: Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: hash)
    }
}
