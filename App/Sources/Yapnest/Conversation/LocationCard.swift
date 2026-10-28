import CryptoKit
import MapKit
import os
import SwiftUI
import YapnestKit

extension GeoLocation {
    func openInMaps() {
        if let url = mapsURL { UIApplication.shared.open(url) }
    }
}

/// A shared location in a bubble: a map snapshot with a pin. The frame has
/// its shape from the start, so the list doesn't move when the picture arrives.
struct LocationCard: View {
    let location: GeoLocation
    @State private var loaded: (key: String, image: UIImage)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let key = LocationSnapshotCache.key(location, dark: colorScheme == .dark, scale: scale)
        Color(.tertiarySystemFill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if let shown = loaded.flatMap({ $0.key == key ? $0.image : nil }) ?? LocationSnapshotCache.cached(key) {
                    FilledImage(image: Image(uiImage: shown), shape: RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(LocationSnapshotCache.size.width / LocationSnapshotCache.size.height, contentMode: .fit)
            .frame(maxWidth: .infinity)
            // Clipped on the snapshot itself rather than here: a clip on a
            // stack of layers is an offscreen render pass.
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .task(id: key) {
                if let cached = LocationSnapshotCache.cached(key) {
                    // Kept here too, so evicting it from the cache can't blank the view.
                    loaded = (key, cached)
                    return
                }
                loaded = nil
                if let image = await LocationSnapshotCache.load(location, dark: colorScheme == .dark, scale: scale, key: key) {
                    loaded = (key, image)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GeoLocation.summary)
            .accessibilityAddTraits(.isButton)
    }
}

/// Snapshots kept as PNG files, so a launch doesn't draw them all again,
/// which costs time, battery and a request to Apple Maps each. The oldest
/// are removed past `limit`, down to `keep`, so most stores find nothing to
/// trim. A file that is missing or unreadable is just a
/// miss.
struct SnapshotDiskCache: Sendable {
    let directory: URL
    var limit = 200
    var keep = 150

    /// In the caches directory, which the system empties when it needs room,
    /// and not the shared container, which nothing else reads these from.
    static let standard = SnapshotDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "MapSnapshots"),
    )

    /// The key has characters a file name can't hold.
    func url(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".png")
    }

    func image(for key: String, scale: CGFloat) -> UIImage? {
        let url = url(for: key)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data, scale: scale) else { return nil }
        // A read counts as use, so what is shown often outlives what isn't.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    /// Bumped by `removeAll`. A snapshot drawn for an account that has
    /// since signed out would be stored after the folder went, so a store
    /// checks it was asked for in the same generation, under the same lock.
    /// Copies of the cache share it.
    let generation = OSAllocatedUnfairLock(initialState: 0)

    func store(_ image: UIImage, for key: String, generation asked: Int) {
        guard let data = image.pngData() else { return }
        generation.withLock { current in
            guard current == asked else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url(for: key), options: .atomic)
        }
        trim()
    }

    /// Signing out deletes what the account left on the device, and a
    /// snapshot shows a place someone shared.
    func removeAll() {
        generation.withLock { current in
            current += 1
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > limit else { return }
        let excess = files.count - min(keep, limit)
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(excess) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Map snapshots, taken ahead of drawing. They're taken at one size, the
/// widest a bubble gets, and scaled down to fit.
@MainActor
enum LocationSnapshotCache {
    static let size = CGSize(width: MediaLimits.maxBubbleWidth - 24, height: (MediaLimits.maxBubbleWidth - 24) / 1.6)
    /// Metres across the picture's width.
    private static let span: CLLocationDistance = 800

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        // Snapshots are drawn at the screen's scale, a couple of megabytes
        // each, so the bytes bound the cache rather than the count.
        cache.totalCostLimit = 16_000_000
        return cache
    }()

    /// Everything that decides the picture, as the disk cache's file name comes from it.
    static func key(_ location: GeoLocation, dark: Bool, scale: CGFloat) -> String {
        String(format: "%.6f,%.6f@%.0fx%.0f/%.0f/%@/%.0f", location.latitude, location.longitude, size.width, size.height, scale, dark ? "dark" : "light", span)
    }

    static func bytes(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// What signing out leaves in memory goes with the files.
    static func removeAll() {
        cache.removeAllObjects()
    }

    static func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func load(_ location: GeoLocation, dark: Bool, scale: CGFloat, key: String) async -> UIImage? {
        if let image = cached(key) { return image }
        let disk = SnapshotDiskCache.standard
        let generation = disk.generation.withLock { $0 }
        if let image = await Task.detached(priority: .utility, operation: {
            // Decoded here, as drawing it for the first time would do it on the main thread.
            disk.image(for: key, scale: scale).map { $0.preparingForDisplay() ?? $0 }
        }).value {
            cache.setObject(image, forKey: key as NSString, cost: Self.bytes(of: image))
            return image
        }
        let options = MKMapSnapshotter.Options()
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: span / 1.6, longitudinalMeters: span)
        options.size = size
        options.traitCollection = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: dark ? .dark : .light), UITraitCollection(displayScale: scale)])
        let image = await snapshotWithPin(options: options, at: coordinate)
        guard let image else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: Self.bytes(of: image))
        Task.detached(priority: .utility) { disk.store(image, for: key, generation: generation) }
        return image
    }

    /// Pinned inside the completion handler, so only the finished picture crosses threads.
    private nonisolated static func snapshotWithPin(options: MKMapSnapshotter.Options, at coordinate: CLLocationCoordinate2D) async -> UIImage? {
        await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start(with: .global(qos: .userInitiated)) { snapshot, _ in
                continuation.resume(returning: snapshot.map { pinned($0, at: coordinate) })
            }
        }
    }

    private nonisolated static func pinned(_ snapshot: MKMapSnapshotter.Snapshot, at coordinate: CLLocationCoordinate2D) -> UIImage {
        let point = snapshot.point(for: coordinate)
        let pin = UIImage(systemName: "mappin", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold))?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        return UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { _ in
            snapshot.image.draw(at: .zero)
            // The symbol's point is at the bottom of its image.
            if let pin { pin.draw(at: CGPoint(x: point.x - pin.size.width / 2, y: point.y - pin.size.height)) }
        }
    }
}
