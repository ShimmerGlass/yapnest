import CoreLocation
import MapKit
import SwiftUI
import YapnestKit

/// The device's position, asked for only once the picker is shown.
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    private(set) var location: CLLocation?
    private(set) var failed = false
    private(set) var isLocating = false
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    func start() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            refresh()
        }
    }

    func refresh() {
        guard !isDenied, status != .notDetermined else { return }
        failed = false
        isLocating = true
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            self.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.location = last
            self.failed = false
            self.isLocating = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.failed = true
            self.isLocating = false
        }
    }
}

/// Choosing a place to send: a map under a fixed pin, starting on where the
/// user is. Without a position the map still works for picking by hand.
struct LocationPicker: View {
    /// Called with the chosen place, which goes in the composer to be sent from there.
    let onAdd: (GeoLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var provider = LocationProvider()
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    /// The fix the map was last centred on; sending from there keeps its accuracy.
    @State private var fix: CLLocation?
    /// Whether there is a place to send: a fix, or a spot the user moved to.
    @State private var hasChosen = false

    /// How far the pin may be from the fix and still count as it. The
    /// camera settles with a little rounding.
    private static let unmovedMetres: CLLocationDistance = 3

    var body: some View {
        NavigationStack {
            Map(position: $position)
                .onMapCameraChange(frequency: .onEnd) { context in
                    // The first report is the map settling in, not a choice.
                    if center != nil { hasChosen = true }
                    center = context.region.center
                }
                .overlay {
                    // The pin's tip is the chosen spot, so it sits above the centre.
                    Image(systemName: "mappin")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.red)
                        .shadow(radius: 2)
                        .offset(y: -18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .top) { note }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        if let location = provider.location { centre(on: location) }
                        provider.refresh()
                    } label: {
                        Group {
                            if provider.isLocating, provider.location == nil {
                                ProgressView()
                            } else {
                                Image(systemName: "location.fill")
                            }
                        }
                        .frame(width: 22, height: 22)
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                    }
                    // After a failed fix the button retries, so it stays usable.
                    .disabled(provider.location == nil && !provider.failed)
                    .accessibilityLabel(String(localized: "Current location"))
                    .padding()
                }
                .navigationTitle("Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCancelButton { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        SheetConfirmButton("Add") { add() }
                            .disabled(center == nil || !hasChosen)
                    }
                }
        }
        .onAppear { provider.start() }
        .onChange(of: provider.location) { old, new in
            // The first fix moves the map; later ones only matter once the user asks to recentre.
            if old == nil, let new { centre(on: new) }
        }
    }

    @ViewBuilder
    private var note: some View {
        let text: Text? = if provider.isDenied {
            Text("Location access is off, so choose a spot on the map.")
        } else if provider.failed, provider.location == nil {
            Text("Your location isn't available right now. Choose a spot on the map.")
        } else {
            nil
        }
        if let text {
            VStack(spacing: 6) {
                text.font(.footnote)
                if provider.isDenied {
                    Button("Open Settings") { openSettings() }
                        .font(.footnote.bold())
                }
            }
            .multilineTextAlignment(.center)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
    }

    private func centre(on location: CLLocation) {
        fix = location
        hasChosen = true
        // The camera reports its new centre only when the move ends; Add may be tapped before then.
        center = location.coordinate
        position = .region(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
    }

    private func isAtFix(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let fix else { return false }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: fix) < Self.unmovedMetres
    }

    private func add() {
        guard let center else { return }
        // The accuracy belongs to the fix, so a spot picked by hand has none.
        let accuracy = isAtFix(center) ? fix.flatMap { $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil } : nil
        onAdd(GeoLocation(latitude: center.latitude, longitude: center.longitude, accuracy: accuracy))
        dismiss()
    }

    private func openSettings() {
        if let url = Platform.privacySettingsURL("Privacy_LocationServices") { openURL(url) }
    }
}
