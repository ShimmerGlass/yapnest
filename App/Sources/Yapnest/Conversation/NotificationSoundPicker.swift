import AudioToolbox
import SwiftUI
import YapnestKit

/// The list behind a chat's "Notification sound" row. Choosing a sound plays
/// it, so the user hears what they pick.
struct NotificationSoundPicker: View {
    /// What `NotificationSound` stores: nil for the system's sound.
    @Binding var selection: String?

    @State private var preview = NotificationSoundPreview()

    var body: some View {
        List {
            Section {
                row(String(localized: "Default"), stored: nil)
                row(String(localized: "None"), stored: NotificationSound.silent)
            } footer: {
                Text("Default is the sound you chose in the system's settings. Muted chats stay silent.")
            }
            Section {
                ForEach(NotificationSound.bundled) { option in
                    row(option.name, stored: option.file) { preview.play(option.file) }
                }
            }
        }
        .navigationTitle("Notification Sound")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { preview.stop() }
    }

    private func row(_ name: String, stored: String?, then: @escaping () -> Void = {}) -> some View {
        Button {
            selection = stored
            preview.stop()
            then()
        } label: {
            HStack {
                Text(verbatim: name)
                Spacer()
                if selection == stored { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }
}

/// Plays a bundled sound once as a system sound: it follows the silent switch
/// and leaves the user's music playing, and needs no audio session, which
/// would change how the rest of the app's audio behaves for good.
@MainActor
final class NotificationSoundPreview {
    private var playing: SystemSoundID?

    func play(_ file: String) {
        stop()
        guard let url = Bundle.main.url(forResource: file, withExtension: nil) else { return }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return }
        playing = id
        AudioServicesPlaySystemSound(id)
    }

    func stop() {
        if let playing { AudioServicesDisposeSystemSoundID(playing) }
        playing = nil
    }
}
