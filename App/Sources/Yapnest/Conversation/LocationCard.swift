import MapKit
import SwiftUI
import YapnestKit

extension GeoLocation {
    /// Apple Maps through its web URL, which opens the Maps app on iOS and on the Mac.
    var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude)), URLQueryItem(name: "q", value: String(localized: "Location"))]
        return components?.url
    }

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
                    // A fixed frame: a flexible one grows to the filled picture's size, so a clip on it crops nothing.
                    GeometryReader { proxy in
                        Image(uiImage: shown)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
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
        return cache
    }()

    static func key(_ location: GeoLocation, dark: Bool, scale: CGFloat) -> String {
        String(format: "%.6f,%.6f@%.0fx%.0f/%.0f/%@", location.latitude, location.longitude, size.width, size.height, scale, dark ? "dark" : "light")
    }

    static func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func load(_ location: GeoLocation, dark: Bool, scale: CGFloat, key: String) async -> UIImage? {
        if let image = cached(key) { return image }
        let options = MKMapSnapshotter.Options()
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: span / 1.6, longitudinalMeters: span)
        options.size = size
        options.traitCollection = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: dark ? .dark : .light), UITraitCollection(displayScale: scale)])
        let image = await snapshotWithPin(options: options, at: coordinate)
        guard let image else { return nil }
        cache.setObject(image, forKey: key as NSString)
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
