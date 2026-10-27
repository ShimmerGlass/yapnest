import Foundation
import Testing
@testable import Yapnest

/// Hide Screen in App Switcher: a per-device choice, off until turned on.
struct AppSwitcherCoverTests {
    private func defaults() -> UserDefaults {
        let suite = "AppSwitcherCoverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func itIsOffByDefault() {
        #expect(!AppSwitcherCoverSetting.isOn(in: defaults()))
    }

    @Test func theChoiceIsKept() {
        let defaults = defaults()
        defaults.set(true, forKey: AppSwitcherCoverSetting.key)
        #expect(AppSwitcherCoverSetting.isOn(in: defaults))
        defaults.set(false, forKey: AppSwitcherCoverSetting.key)
        #expect(!AppSwitcherCoverSetting.isOn(in: defaults))
    }
}
