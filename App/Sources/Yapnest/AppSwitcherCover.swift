import SwiftUI
import UIKit

/// Hides the window from the iPhone's and iPad's app switcher when the user
/// has asked for it. The choice is about this device,
/// not the account, so it lives in the device's defaults and never syncs.
enum AppSwitcherCoverSetting {
    static let key = "yapnest.hidesScreenInAppSwitcher"

    /// Off unless turned on.
    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// A plain cover in a window of its own, above the app's window, sheets and
/// alerts. UIKit posts willDeactivate before the system takes its snapshot,
/// and a window shown by then is in it; an animation or a SwiftUI overlay
/// would be too late or leave the sheets bare.
@MainActor @Observable
final class AppSwitcherCover {
    static let shared = AppSwitcherCover()

    /// How many times the cover went up, for the UI tests: the snapshot
    /// itself can't be read from a test.
    private(set) var shownCount = 0

    @ObservationIgnored private var windows: [ObjectIdentifier: UIWindow] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    func start(center: NotificationCenter = .default, defaults: UserDefaults = .standard) {
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: nil) { [weak self] note in
                // Posted on the main thread, and handled before it returns.
                nonisolated(unsafe) let scene = note.object as? UIWindowScene
                let on = AppSwitcherCoverSetting.isOn(in: defaults)
                MainActor.assumeIsolated {
                    guard let scene, on else { return }
                    self?.cover(scene)
                }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: nil) { [weak self] note in
                nonisolated(unsafe) let scene = note.object as? UIScene
                MainActor.assumeIsolated {
                    guard let scene else { return }
                    self?.uncover(scene)
                }
            },
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: nil) { [weak self] note in
                nonisolated(unsafe) let scene = note.object as? UIScene
                MainActor.assumeIsolated {
                    guard let scene else { return }
                    self?.windows.removeValue(forKey: ObjectIdentifier(scene))
                }
            },
        ]
    }

    private func cover(_ scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        let window = windows[id] ?? makeWindow(in: scene)
        windows[id] = window
        guard window.isHidden else { return }
        window.isHidden = false
        shownCount += 1
    }

    /// Built once per scene and then only shown and hidden, as the cover goes
    /// up on every trip to the app switcher.
    private func makeWindow(in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: .greatestFiniteMagnitude)
        let host = UIHostingController(rootView: AppSwitcherCoverView())
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.isHidden = true
        return window
    }

    private func uncover(_ scene: UIScene) {
        windows[ObjectIdentifier(scene)]?.isHidden = true
    }
}

private struct AppSwitcherCoverView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            AppIconImage(size: 120)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("appSwitcherCover")
    }
}
