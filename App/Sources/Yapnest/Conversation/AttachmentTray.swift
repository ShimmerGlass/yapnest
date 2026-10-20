import AVFoundation
import UIKit
import UniformTypeIdentifiers
import YapnestKit

/// The row of tiles in the composer's field for what is waiting to be sent:
/// a thumbnail for pictures and videos, an icon and a name for anything else.
final class AttachmentTray: UIScrollView {
    var onRemove: ((PendingAttachment.ID) -> Void)?

    private let stack = UIStackView()
    private var tiles: [PendingAttachment.ID: AttachmentTile] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        showsHorizontalScrollIndicator = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 6),
            // One tile sits at the leading edge in both directions, which the
            // scroll view doesn't do for itself when mirrored.
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentLayoutGuide.trailingAnchor, constant: -6),
            contentLayoutGuide.widthAnchor.constraint(greaterThanOrEqualTo: frameLayoutGuide.widthAnchor),
            frameLayoutGuide.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the tiles that are still there, so their thumbnails aren't read again.
    func set(_ items: [PendingAttachment]) {
        let ids = Set(items.map(\.id))
        for (id, tile) in tiles where !ids.contains(id) {
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        for (index, item) in items.enumerated() {
            let tile: AttachmentTile
            if let existing = tiles[item.id] {
                tile = existing
            } else {
                tile = AttachmentTile(item: item) { [weak self] in self?.onRemove?(item.id) }
                tiles[item.id] = tile
            }
            // Re-inserting also puts a tile in its place, which keeps the order.
            if stack.arrangedSubviews.indices.contains(index), stack.arrangedSubviews[index] === tile { continue }
            stack.insertArrangedSubview(tile, at: index)
        }
        // A new tile is at the end, which is where the user wants to see it:
        // the right edge, or the left one when the layout is mirrored.
        layoutIfNeeded()
        // The content isn't mirrored: in right-to-left the stack runs from
        // the right, so its newest tile is at the content's left end.
        let x = ComposerRowOffset.x(
            contentWidth: contentSize.width, frameWidth: bounds.width,
            rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft, showing: .trailing,
        )
        setContentOffset(CGPoint(x: x, y: 0), animated: false)
    }
}

private final class AttachmentTile: UIView {
    private static let side: CGFloat = 64

    private let content = UIView()
    private var loading: Task<Void, Never>?

    init(item: PendingAttachment, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])

        content.backgroundColor = .secondarySystemFill
        content.layer.cornerRadius = 12
        content.layer.cornerCurve = .continuous
        content.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isAccessibilityElement = true
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        switch item.content {
        case .file(let file, let isPhoto):
            fill(file: file, isPhoto: isPhoto)
        case .location:
            showIcon("mappin.and.ellipse", caption: String(localized: "Location"))
        }

        let remove = UIButton(configuration: .plain(), primaryAction: UIAction { _ in onRemove() })
        remove.configuration?.image = UIImage(systemName: "xmark.circle.fill")
        remove.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 16)
        remove.configuration?.contentInsets = .zero
        remove.configuration?.baseForegroundColor = .white
        remove.configuration?.background.backgroundColor = .clear
        remove.layer.shadowColor = UIColor.black.cgColor
        remove.layer.shadowOpacity = 0.5
        remove.layer.shadowRadius = 2
        remove.layer.shadowOffset = .zero
        remove.accessibilityLabel = String(localized: "Remove")
        remove.preferredBehavioralStyle = .pad
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24),
        ])
        accessibilityElements = [content, remove]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loading?.cancel() }

    private func fill(file: URL, isPhoto: Bool) {
        let type = UTType(filenameExtension: file.pathExtension)
        let name = file.lastPathComponent
        content.accessibilityLabel = name
        if isPhoto {
            showThumbnail(placeholder: "photo") {
                await Task.detached(priority: .userInitiated) { ImageDownsampler.downsample(file, maxPixels: 256) }.value
            }
            content.accessibilityLabel = String(localized: "Photo")
        } else if type?.conforms(to: .vCard) == true {
            showIcon("person.crop.circle", caption: file.deletingPathExtension().lastPathComponent)
        } else if type?.conforms(to: .movie) == true {
            showThumbnail(placeholder: "film") { await Self.videoFrame(file) }
            content.accessibilityLabel = String(localized: "Video")
        } else {
            showIcon("doc.fill", caption: name)
        }
    }

    /// An icon until the picture is read, which happens off the main thread
    /// since decoding a full-size photo would stall it.
    private func showThumbnail(placeholder: String, load: @escaping @Sendable () async -> UIImage?) {
        let icon = UIImageView(image: UIImage(systemName: placeholder))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        pin(icon)
        loading = Task { [weak self] in
            guard let image = await load(), !Task.isCancelled, let self else { return }
            icon.removeFromSuperview()
            let picture = UIImageView(image: image)
            picture.contentMode = .scaleAspectFill
            picture.clipsToBounds = true
            pin(picture)
        }
    }

    nonisolated private static func videoFrame(_ file: URL) async -> UIImage? {
        // The first frame is black for videos that fade in, so try one a
        // little in with some tolerance, then fall back to the very first.
        let asset = AVURLAsset(url: file)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration.isFinite, duration > 0 {
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            let time = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)
            if let frame = await videoFrame(asset, at: time, tolerance: tolerance) { return frame }
        }
        return await videoFrame(asset, at: .zero, tolerance: .positiveInfinity)
    }

    nonisolated private static func videoFrame(_ asset: AVURLAsset, at time: CMTime, tolerance: CMTime) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let frame = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: frame)
    }

    private func showIcon(_ symbol: String, caption: String) {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let label = UILabel()
        label.text = caption
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        let column = UIStackView(arrangedSubviews: [icon, label])
        column.axis = .vertical
        column.spacing = 2
        column.isUserInteractionEnabled = false
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(top: 8, left: 4, bottom: 6, right: 4)
        pin(column)
        content.accessibilityLabel = caption
    }

    private func pin(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }
}
