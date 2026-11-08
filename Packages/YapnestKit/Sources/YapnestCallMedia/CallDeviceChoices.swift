import Foundation

/// Which microphone, speaker and camera the user picked for calls on the Mac,
/// kept per Mac in UserDefaults by the device's UID. Absent means the system
/// default for audio, and the first camera for video. The audio unit and the
/// capture read it from their own threads, and UserDefaults allows that.
public final class CallDeviceChoices: @unchecked Sendable {
    public static let shared = CallDeviceChoices(defaults: .standard)
    /// Posted when a choice changes, so a live call can follow it.
    public static let didChange = Notification.Name("app.yapnest.CallDeviceChoicesDidChange")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var inputUID: String? {
        get { defaults.string(forKey: "callInputDevice") }
        set { store(newValue, key: "callInputDevice") }
    }

    public var outputUID: String? {
        get { defaults.string(forKey: "callOutputDevice") }
        set { store(newValue, key: "callOutputDevice") }
    }

    /// The camera's `uniqueID`.
    public var cameraID: String? {
        get { defaults.string(forKey: "callCamera") }
        set { store(newValue, key: "callCamera") }
    }

    private func store(_ value: String?, key: String) {
        guard defaults.string(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// What a stored choice means once the device may have been unplugged.
public enum CallDeviceResolution {
    /// The chosen audio device's UID if it is still there, else nil, which is
    /// the system default: a call goes on with the default when a headset is
    /// pulled out, and goes back to the headset when it returns.
    public static func audio(choice: String?, available: [String]) -> String? {
        guard let choice, available.contains(choice) else { return nil }
        return choice
    }

    /// The chosen camera's ID if it is still there, else the first.
    public static func camera(choice: String?, available: [String]) -> String? {
        audio(choice: choice, available: available) ?? available.first
    }
}

/// A row of a device picker: what is stored for it, and the name it shows.
public struct CallDeviceOption: Identifiable, Equatable, Sendable {
    /// Nil for the system's default.
    public let id: String?
    public let name: String

    /// The rows for `devices`, led by the system default when `defaultName` is given. A device listed
    /// twice under one id is one row: the picker identifies its rows by id, and two with the same one
    /// would be drawn as one or the wrong one selected.
    public static func rows(defaultName: String?, devices: [(id: String, name: String)]) -> [CallDeviceOption] {
        var seen = Set<String>()
        let listed = devices.filter { seen.insert($0.id).inserted }.map { CallDeviceOption(id: $0.id, name: $0.name) }
        return (defaultName.map { [CallDeviceOption(id: nil, name: $0)] } ?? []) + listed
    }
}
