import SwiftUI
import YapnestKit

/// The app's settings, as a sheet from the chat list's gear button or the
/// Mac's Settings menu item. Who you are to your contacts is in `ProfileView`.
struct SettingsView: View {
    let session: XMPPSession

    @Environment(AppModel.self) private var model
    @State private var sendsReadMarkers = true
    @State private var linkPreviewSetting = LinkPreviewSetting.askPerConversation
    @State private var sendsChatStates = true
    @State private var sharesLastSeen = false
    @State private var downloadsFromGroupMembers = true
    @State private var relaysCalls = false
    @State private var includesMessagesInBackups = true
    @State private var gifsEnabled = true
    @State private var encryptsNewChats = true
    @AppStorage(AppSwitcherCoverSetting.key) private var hidesScreenInAppSwitcher = false
    @State private var privacyError: String?
    @State private var diagnostics = DiagnosticsExporter()
    /// The stored values are read off the main thread; until then the controls
    /// would show defaults and snap, so they stay disabled.
    @State private var isLoaded = false
    #if DEBUG
    @State private var opensLicencesForDev = ProcessInfo.processInfo.environment["YAPNEST_DEV_SETTINGS"]?.hasPrefix("licences") == true
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Send Read Receipts", isOn: Binding(get: { sendsReadMarkers }, set: setSendsReadMarkers))
                    Toggle("Send Typing Indicator", isOn: Binding(get: { sendsChatStates }, set: setSendsChatStates))
                    Toggle("Activity Status", isOn: Binding(get: { sharesLastSeen }, set: setSharesLastSeen))
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Only the people you've added see these. With Activity Status on, your contacts see how long ago you were online, and see you as away once you leave Yapnest on your iPhone or iPad, or step away from your Mac. You see theirs. While you're offline, your server may tell your contacts when you were last online whatever this says; Yapnest can't control that.")
                }
                .disabled(!isLoaded)

                if !Platform.isMac {
                    Section {
                        Toggle("Hide Screen in App Switcher", isOn: $hidesScreenInAppSwitcher)
                    } footer: {
                        Text("Shows a blank screen instead of your chats in the app switcher.")
                    }
                }

                Section {
                    Toggle("Download Pictures from Group Members", isOn: Binding(get: { downloadsFromGroupMembers }, set: { on in setFlag(.downloadsFromGroupMembers, on) { downloadsFromGroupMembers = on } }))
                } footer: {
                    Text("Downloading a picture shows your IP address to the sender's server. With this off, you tap a picture from a group member you haven't added to download it.")
                }
                .disabled(!isLoaded)

                Section {
                    Toggle("Always Relay Calls", isOn: Binding(get: { relaysCalls }, set: { on in setFlag(.relaysCalls, on) { relaysCalls = on } }))
                } footer: {
                    Text("Relaying hides your IP address from the person you call, and may lower the quality. It needs your server to offer a relay; without one, calls fail rather than connect directly.")
                }
                .disabled(!isLoaded)

                Section {
                    Picker("Link Previews", selection: Binding(get: { linkPreviewSetting }, set: setLinkPreviewSetting)) {
                        Text("Ask per conversation").tag(LinkPreviewSetting.askPerConversation)
                        Text("Never").tag(LinkPreviewSetting.never)
                    }
                } footer: {
                    Text("Loading a preview lets the linked site see your IP address and that you got the link.")
                }
                .disabled(!isLoaded)

                Section {
                    Toggle("Include Messages in Backups", isOn: Binding(get: { includesMessagesInBackups }, set: setIncludesMessagesInBackups))
                } footer: {
                    Text("With this off, your messages and files aren't in iCloud or computer backups. A phone restored from a backup then starts empty and gets its history back from your server; encrypted messages from before the restore can't be read again. With it on, backups include them, and iCloud Backup protects them end to end only with Advanced Data Protection. This applies to this device only.")
                }
                .disabled(!isLoaded)

                if Klipy.apiKey != nil {
                    Section {
                        Toggle("GIFs", isOn: Binding(get: { gifsEnabled }, set: { on in setFlag(.gifs, on) { gifsEnabled = on } }))
                    } footer: {
                        Text(Klipy.disclosure)
                    }
                    .disabled(!isLoaded)
                }

                #if targetEnvironment(macCatalyst)
                Section {
                    CallDevicePickers()
                } header: {
                    Text("Calls")
                } footer: {
                    Text("System default follows the Mac's sound settings. A device you pick is used for calls only.")
                }
                #endif

                Section {
                    Toggle("Encrypt New Chats", isOn: Binding(get: { encryptsNewChats }, set: { on in setFlag(.encryptsNewChats, on) { encryptsNewChats = on } }))
                        .disabled(!isLoaded)
                    NavigationLink {
                        DevicesList(session: session, peer: nil)
                    } label: {
                        Label("Encryption Keys", systemImage: "key")
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    Text("New one-to-one chats are end-to-end encrypted with OMEMO. Chats you already have keep their setting, and you can change it in each chat.")
                }

                Section {
                    if let url = AppLinks.terms {
                        Link(destination: url) { Label("Terms of Use", systemImage: "doc.text").labelStyle(.row) }
                    }
                    if let url = AppLinks.privacyPolicy {
                        Link(destination: url) { Label("Privacy Policy", systemImage: "hand.raised").labelStyle(.row) }
                    }
                    if let url = AppLinks.support {
                        Link(destination: url) { Label("Contact Support", systemImage: "envelope").labelStyle(.row) }
                    }
                    NavigationLink {
                        LicencesView()
                    } label: {
                        Label("Open Source Licences", systemImage: "scroll")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text(AppLinks.versionDescription)
                }

                Section {
                    Button {
                        Task { await diagnostics.start() }
                    } label: {
                        HStack {
                            Label("Export Logs", systemImage: "doc.text.magnifyingglass")
                                .labelStyle(.row)
                            if diagnostics.isExporting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(diagnostics.isExporting)
                    .accessibilityIdentifier("exportLogs")
                } footer: {
                    Text("Connection and sending events, the app version and the device model, for finding a problem. It shows when the app was used, but not who you talked to or what was said, and it holds no addresses.")
                }

                if offersCommands {
                    Section("Account") {
                        NavigationLink {
                            CommandsListView(title: "Server commands", session: session, entities: [(label: nil, jid: session.account.domain)])
                        } label: {
                            Label("Server commands", systemImage: "terminal")
                        }
                    }
                }

            }
            .dismissesKeyboardOnTap()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            // `YAPNEST_DEV_SETTINGS=licences[:<library id>]` opens the sheet on
            // that page, for screenshots.
            .navigationDestination(isPresented: $opensLicencesForDev) { LicencesView() }
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton()
                }
            }
            .diagnosticsErrorAlert(diagnostics)
            .errorAlert("Couldn't change the setting", $privacyError)
            .task {
                let saved = await offMain { [session] in
                    (
                        sendsReadMarkers: session.sendsReadMarkers,
                        linkPreviewSetting: session.database.linkPreviewSetting,
                        sendsChatStates: session.sendsChatStates,
                        sharesLastSeen: session.sharesLastSeen,
                        downloadsFromGroupMembers: session.downloadsFromGroupMembers,
                        relaysCalls: session.relaysCalls,
                        includesMessagesInBackups: BackupPolicy.includesMessages(),
                        gifsEnabled: session.database.flag(.gifs, default: true),
                        encryptsNewChats: session.database.flag(.encryptsNewChats, default: true),
                    )
                }
                sendsReadMarkers = saved.sendsReadMarkers
                linkPreviewSetting = saved.linkPreviewSetting
                sendsChatStates = saved.sendsChatStates
                sharesLastSeen = saved.sharesLastSeen
                downloadsFromGroupMembers = saved.downloadsFromGroupMembers
                relaysCalls = saved.relaysCalls
                includesMessagesInBackups = saved.includesMessagesInBackups
                gifsEnabled = saved.gifsEnabled
                encryptsNewChats = saved.encryptsNewChats
                isLoaded = true
            }
        }
        #if DEBUG
        // The snapshot can't be read from a UI test, so it reads how often the
        // cover went up. Its own element beside the form, as a footer is
        // exposed differently from one iOS version to the next.
        .overlay(alignment: .bottomTrailing) {
            Button {} label: {
                Color.clear.frame(width: 6, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appSwitcherCoverCount")
            .accessibilityLabel("Covers shown")
            .accessibilityValue("\(AppSwitcherCover.shared.shownCount)")
        }
        #endif
        .closableFromPushedScreens()
    }

    /// Read from the server's features, which arrive after connecting.
    private var offersCommands: Bool {
        #if DEBUG
        if DevFixture.isActive { return false }
        #endif
        _ = model.connection
        return session.serverOffersCommands
    }

    // Quick local writes, off the main thread all the same. The switch only
    // moves once the write has worked.
    private func setSendsReadMarkers(_ on: Bool) {
        save({ [session] in try session.setSendsReadMarkers(on) }) { sendsReadMarkers = on }
    }

    private func setLinkPreviewSetting(_ value: LinkPreviewSetting) {
        save({ [session] in try session.database.setLinkPreviewSetting(value) }) { linkPreviewSetting = value }
    }

    private func setSendsChatStates(_ on: Bool) {
        save({ [session] in try session.setSendsChatStates(on) }) { sendsChatStates = on }
    }

    private func setSharesLastSeen(_ on: Bool) {
        save({ [session] in try session.setSharesLastSeen(on) }) { sharesLastSeen = on }
    }

    /// Saves a flag that only differs from the others by its key; `done` shows it.
    private func setFlag(_ key: AppDatabase.SettingKey, _ on: Bool, then done: @escaping () -> Void) {
        save({ [session] in try session.database.setFlag(key, on) }, then: done)
    }

    private func setIncludesMessagesInBackups(_ on: Bool) {
        save({ BackupPolicy.setIncludesMessages(on) }) { includesMessagesInBackups = on }
    }

    private func save(_ write: @escaping @Sendable () throws -> Void, then done: @escaping () -> Void) {
        Task {
            do {
                try await offMain(write)
                done()
            } catch {
                privacyError = error.localizedDescription
            }
        }
    }
}
