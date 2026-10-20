import Foundation
import UserNotifications

/// The sound a chat's notifications make. The choice is stored per
/// conversation as text: nil for the system's sound, `silent` for none, else
/// the file name of one of the sounds bundled with the app (`App/Sounds`).
public enum NotificationSound {
    public struct Option: Sendable, Equatable, Identifiable {
        public var name: String
        /// What's stored, and the file in the app's bundle.
        public var file: String
        public var id: String { file }
    }

    /// Stored for "None", which no file name can be.
    public static let silent = "none"

    /// In the order the picker lists them. Never rename a file: chats store
    /// it. A removed one falls back to the system's sound.
    public static let bundled: [Option] = [
        Option(name: "Chime", file: "chime.caf"),
        Option(name: "Ding", file: "ding.caf"),
        Option(name: "Glass", file: "glass.caf"),
        Option(name: "Bloom", file: "bloom.caf"),
        Option(name: "Pluck", file: "pluck.caf"),
        Option(name: "Pop", file: "pop.caf"),
        Option(name: "Drop", file: "drop.caf"),
        Option(name: "Bong", file: "bong.caf"),
        Option(name: "Hmm", file: "hmm.caf"),
        Option(name: "Ripple", file: "ripple.caf"),
    ]

    public enum Choice: Sendable, Equatable {
        case systemDefault
        case none
        case file(String)
    }

    /// What a notification should play. A quiet notification (a muted group)
    /// stays silent whatever was chosen, and only a person's chat has a choice.
    public static func choice(kind: Conversation.Kind, stored: String?, isQuiet: Bool) -> Choice {
        if isQuiet { return .none }
        guard kind == .chat, let stored else { return .systemDefault }
        if stored == silent { return .none }
        // A sound a later version dropped must not leave the chat mute.
        return bundled.contains { $0.file == stored } ? .file(stored) : .systemDefault
    }

    /// The name to show for a stored choice.
    public static func displayName(of stored: String?) -> String {
        switch choice(kind: .chat, stored: stored, isQuiet: false) {
        case .systemDefault: String(localized: "Default")
        case .none: String(localized: "None")
        case .file(let file): bundled.first { $0.file == file }?.name ?? file
        }
    }
}

extension NotificationSound.Choice {
    public var unSound: UNNotificationSound? {
        switch self {
        case .systemDefault: .default
        case .none: nil
        case .file(let file): UNNotificationSound(named: UNNotificationSoundName(file))
        }
    }
}
