import AVFoundation
import Foundation
import UserNotifications

/// What tells the user an incoming call is ringing where CallKit isn't there to
/// do it: a ringtone on repeat, and on the Mac a notification, for when the
/// app isn't in front.
@MainActor
final class CallRinger {
    private var player: AVAudioPlayer?
    private var loop: Task<Void, Never>?
    private var notified: String?

    /// The pause between one ring and the next.
    static let gap: Duration = .seconds(2)
    private static let sound = "ripple"

    func start(sid: String, name: String, video: Bool) {
        stop()
        startRinging()
        guard Platform.isMac else { return }
        notified = sid
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(name) is calling")
        content.body = video ? String(localized: "Video call") : String(localized: "Audio call")
        // The app plays the ring itself, so it can repeat until the call ends.
        content.sound = nil
        let request = UNNotificationRequest(identifier: Self.identifier(sid), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Before the call's audio is activated, as the ring would share its session.
    func stop() {
        loop?.cancel()
        loop = nil
        player?.stop()
        player = nil
        if let sid = notified {
            notified = nil
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(sid)])
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(sid)])
        }
    }

    private static func identifier(_ sid: String) -> String { "call-\(sid)" }

    private func startRinging() {
        guard let url = Bundle.main.url(forResource: Self.sound, withExtension: "caf"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        loop = Task {
            while !Task.isCancelled {
                player.currentTime = 0
                player.play()
                try? await Task.sleep(for: .seconds(player.duration) + Self.gap)
            }
        }
    }
}
