import SwiftUI
import YapnestKit

/// Shown once, after the first sign-in on this install, to ask for the
/// settings that decide what Yapnest shares before the first message goes out.
/// The switches start at the account's values, which another device may have
/// set, and are saved together when the user continues.
struct WelcomeView: View {
    let session: XMPPSession

    @Environment(AppModel.self) private var model
    @State private var encryptsNewChats = true
    @State private var sendsReadMarkers = true
    @State private var sendsChatStates = true
    @State private var sharesLastSeen = false
    @State private var gifsEnabled = true
    /// The stored values are read off the main thread; until then the switches
    /// would show defaults and snap, so they stay disabled.
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Text("Welcome to Yapnest")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text("Choose what you share. You can change any of it later in Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    option("Encrypt New Chats", isOn: $encryptsNewChats, detail: "New one-to-one chats are end-to-end encrypted with OMEMO, so only you and the other person can read them. Chats you already have keep their setting.")
                }
                Section {
                    option("Send Read Receipts", isOn: $sendsReadMarkers, detail: "The people you chat with see when you've read their messages.")
                    option("Send Typing Indicator", isOn: $sendsChatStates, detail: "The people you chat with see when you're typing.")
                    option("Last Seen", isOn: $sharesLastSeen, detail: "Your contacts see how long ago you were online, and you see theirs. While you're offline, your server may tell your contacts when you were last online whatever this says; Yapnest can't control that.")
                }
                if Klipy.apiKey != nil {
                    Section {
                        option("GIFs", isOn: $gifsEnabled, detail: "Searches go to KLIPY, which sees what you search for and your IP address.")
                    }
                }

                Section {
                    Button(action: save) {
                        // The text stays in place, hidden, so the button keeps its size.
                        Text("Continue")
                            .opacity(isSaving ? 0 : 1)
                            .overlay { if isSaving { ProgressView().tint(.white) } }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!isLoaded || isSaving)
                    .accessibilityIdentifier("welcomeContinue")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .errorAlert("Couldn't save your choices", $error)
            .task {
                let saved = await offMain { [session] in
                    (
                        encryptsNewChats: session.database.flag(.encryptsNewChats, default: true),
                        sendsReadMarkers: session.sendsReadMarkers,
                        sendsChatStates: session.sendsChatStates,
                        sharesLastSeen: session.sharesLastSeen,
                        gifsEnabled: session.database.flag(.gifs, default: true),
                    )
                }
                encryptsNewChats = saved.encryptsNewChats
                sendsReadMarkers = saved.sendsReadMarkers
                sendsChatStates = saved.sendsChatStates
                sharesLastSeen = saved.sharesLastSeen
                gifsEnabled = saved.gifsEnabled
                isLoaded = true
            }
        }
    }

    private func option(_ title: LocalizedStringKey, isOn: Binding<Bool>, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .disabled(!isLoaded)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func save() {
        let values = (encryptsNewChats, sendsReadMarkers, sendsChatStates, sharesLastSeen, gifsEnabled)
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await offMain { [session] in
                    try session.database.setFlag(.encryptsNewChats, values.0)
                    try session.setSendsReadMarkers(values.1)
                    try session.setSendsChatStates(values.2)
                    try session.setSharesLastSeen(values.3)
                    if Klipy.apiKey != nil { try session.database.setFlag(.gifs, values.4) }
                }
                try await model.finishWelcome()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
