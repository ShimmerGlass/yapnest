#if targetEnvironment(macCatalyst)
import SwiftUI
import YapnestCallMedia

/// The Mac's choice of microphone, speaker and camera for calls, on the call
/// screen's menu and in Settings. AVAudioSession can't pick devices on the
/// Mac, so these are the devices CoreAudio lists (`CallDevices`).
struct CallDevicePickers: View {
    var showsCamera = true
    /// In a menu each picker lists its devices under a heading; in a form it
    /// is a row of its own.
    var inMenu = false

    @State private var devices = CallDevices.shared

    var body: some View {
        Group {
            audio("Microphone", symbol: "mic", list: devices.inputs, selection: Binding(
                get: { devices.selectedInput }, set: { devices.inputUID = $0 }))
            audio("Speaker", symbol: "speaker.wave.2", list: devices.outputs, selection: Binding(
                get: { devices.selectedOutput }, set: { devices.outputUID = $0 }))
            if showsCamera, !devices.cameras.isEmpty { camera }
        }
        // A USB microphone plugged in while the menu or form is up.
        .onAppear { devices.refresh() }
    }

    private func audio(
        _ title: LocalizedStringKey, symbol: String, list: [CallAudioDevice], selection: Binding<String?>
    ) -> some View {
        picker(
            title, symbol: symbol, selection: selection,
            choices: [Choice(id: nil, name: String(localized: "System default"))] + list.map { Choice(id: $0.uid, name: $0.name) })
    }

    private var camera: some View {
        picker(
            "Camera", symbol: "video", selection: Binding(get: { devices.selectedCamera }, set: { devices.cameraID = $0 }),
            choices: devices.cameras.map { Choice(id: $0.id, name: $0.name) })
    }

    private struct Choice: Identifiable {
        /// What's stored for it, nil for the system's default.
        let id: String?
        let name: String
    }

    @ViewBuilder
    private func picker(
        _ title: LocalizedStringKey, symbol: String, selection: Binding<String?>, choices: [Choice]
    ) -> some View {
        if inMenu {
            // Buttons, not a Picker: in a Catalyst menu an inline Picker ignores
            // its style and becomes a submenu, whose row is blank once
            // `labelsHidden` takes its title.
            Section(title) {
                ForEach(choices) { choice in
                    Button {
                        selection.wrappedValue = choice.id
                    } label: {
                        if selection.wrappedValue == choice.id {
                            Label(choice.name, systemImage: "checkmark")
                        } else {
                            Text(choice.name)
                        }
                    }
                }
            }
        } else {
            Picker(title, systemImage: symbol, selection: selection) {
                ForEach(choices) { Text($0.name).tag($0.id) }
            }
        }
    }
}
#endif
