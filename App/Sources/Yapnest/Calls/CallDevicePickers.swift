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
        picker(title, symbol: symbol, selection: selection) {
            Text("System default").tag(String?.none)
            ForEach(list) { Text($0.name).tag(String?.some($0.uid)) }
        }
    }

    private var camera: some View {
        picker("Camera", symbol: "video", selection: Binding(
            get: { devices.selectedCamera }, set: { devices.cameraID = $0 })
        ) {
            ForEach(devices.cameras) { Text($0.name).tag(String?.some($0.id)) }
        }
    }

    @ViewBuilder
    private func picker<Choices: View>(
        _ title: LocalizedStringKey, symbol: String, selection: Binding<String?>, @ViewBuilder choices: () -> Choices
    ) -> some View {
        if inMenu {
            Section(title) {
                Picker(title, selection: selection, content: choices)
                    .pickerStyle(.inline)
                    .labelsHidden()
            }
        } else {
            Picker(title, systemImage: symbol, selection: selection, content: choices)
        }
    }
}
#endif
