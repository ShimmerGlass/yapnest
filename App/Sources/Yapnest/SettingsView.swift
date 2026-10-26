import PhotosUI
import SwiftUI
import YapnestKit

/// The account's settings, as a sheet from the avatar button or the Mac's
/// Settings menu item.
struct SettingsView: View {
    let session: XMPPSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var me: Contact?
    @State private var sendsReadMarkers = true
    @State private var linkPreviewSetting = LinkPreviewSetting.askPerConversation
    @State private var sendsChatStates = true
    @State private var sharesLastSeen = false
    @State private var sharesProfilePublicly = false
    @State private var isChangingProfileAccess = false
    @State private var downloadsFromGroupMembers = true
    @State private var relaysCalls = false
    @State private var includesMessagesInBackups = true
    @State private var gifsEnabled = true
    @State private var encryptsNewChats = true
    @State private var privacyError: String?
    @State private var confirmsSignOut = false
    @State private var photo: PhotosPickerItem?
    @State private var isChangingAvatar = false
    @State private var profileError: String?
    @State private var diagnostics = DiagnosticsExporter()
    @State private var name = ""
    @State private var savedName = ""
    @State private var isSavingName = false
    @State private var profileAction = ServerAction()
    @State private var availability = XMPPSession.Availability.available
    @State private var status = ""
    @State private var savedStatus = ""
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
                    HStack(spacing: 16) {
                        AvatarView(
                            name: session.account.shortName,
                            seed: session.account.description,
                            imageURL: session.avatars.url(for: me),
                        )
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.account.description)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isChangingAvatar { ProgressView() }
                        }
                    }
                    .avatarHeaderRow()
                    HStack {
                        TextField("Display Name", text: $name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(saveName)
                            .disabled(profileAction.isBusy || !isLoaded)
                        if isSavingName {
                            ProgressView()
                        } else if XMPPSession.normalizedNickname(name) ?? "" != savedName {
                            Button("Save", action: saveName)
                        }
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose Photo", systemImage: "photo")
                            .labelStyle(.row)
                    }
                    .disabled(profileAction.isBusy)
                    if me?.avatarHash != nil {
                        Button("Remove Photo", systemImage: "trash", role: .destructive, action: removeAvatar)
                            .labelStyle(.destructiveRow)
                            .disabled(profileAction.isBusy)
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Your contacts see your name and photo.")
                }

                Section {
                    Picker("Availability", selection: Binding(get: { availability }, set: setAvailability)) {
                        Text("Available").tag(XMPPSession.Availability.available)
                        Text("Away").tag(XMPPSession.Availability.away)
                        Text("Do Not Disturb").tag(XMPPSession.Availability.dnd)
                    }
                    HStack {
                        TextField("Status Message", text: $status)
                            .submitLabel(.done)
                            .onSubmit(saveStatus)
                        if XMPPSession.normalizedStatus(status) ?? "" != savedStatus {
                            Button("Save", action: saveStatus)
                        }
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Your contacts see this next to your name.")
                }
                .disabled(!isLoaded)

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

                Section {
                    HStack {
                        Toggle("Show My Name and Photo to Everyone", isOn: Binding(get: { sharesProfilePublicly }, set: setSharesProfilePublicly))
                            .disabled(profileAction.isBusy)
                        if isChangingProfileAccess { ProgressView() }
                    }
                } footer: {
                    Text("With this off, only your contacts see your name and photo. People you haven't added, including members of your groups, don't.")
                }
                .disabled(!isLoaded)

                Section {
                    Toggle("Download Pictures from Group Members", isOn: Binding(get: { downloadsFromGroupMembers }, set: setDownloadsFromGroupMembers))
                } footer: {
                    Text("Downloading a picture shows your IP address to the sender's server. With this off, you tap a picture from a group member you haven't added to download it.")
                }
                .disabled(!isLoaded)

                Section {
                    Toggle("Always Relay Calls", isOn: Binding(get: { relaysCalls }, set: setRelaysCalls))
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
                        Toggle("GIFs", isOn: Binding(get: { gifsEnabled }, set: setGifsEnabled))
                    } footer: {
                        Text("Searches go to KLIPY, which sees what you search for and your IP address.")
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
                    Toggle("Encrypt New Chats", isOn: Binding(get: { encryptsNewChats }, set: setEncryptsNewChats))
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

                Section("Account") {
                    if offersPasswordChange {
                        NavigationLink {
                            ChangePasswordView()
                        } label: {
                            Label("Change Password", systemImage: "lock.rotation")
                        }
                    }
                    if offersCommands {
                        NavigationLink {
                            CommandsListView(title: "Server commands", session: session, entities: [(label: nil, jid: session.account.domain)])
                        } label: {
                            Label("Server commands", systemImage: "terminal")
                        }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmsSignOut = true
                    }
                    .labelStyle(.destructiveRow)
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
            .confirmationDialog("Sign out of \(session.account.description)?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
            } message: {
                Text("Messages and keys stored on this device are deleted.")
            }
            .diagnosticsErrorAlert(diagnostics)
            .errorAlert("Couldn't change the setting", $privacyError)
            .actionAlert("Couldn't update your profile", profileAction)
            .errorAlert("Couldn't update your profile", $profileError)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                setAvatar(from: item)
            }
            .task {
                let saved = await offMain { [session] in
                    (
                        name: session.nickname ?? "",
                        availability: session.availability,
                        status: session.statusMessage,
                        sendsReadMarkers: session.sendsReadMarkers,
                        linkPreviewSetting: session.database.linkPreviewSetting,
                        sendsChatStates: session.sendsChatStates,
                        sharesLastSeen: session.sharesLastSeen,
                        sharesProfilePublicly: session.sharesProfilePublicly,
                        downloadsFromGroupMembers: session.downloadsFromGroupMembers,
                        relaysCalls: session.relaysCalls,
                        includesMessagesInBackups: BackupPolicy.includesMessages(),
                        gifsEnabled: session.database.flag(.gifs, default: true),
                        encryptsNewChats: session.database.flag(.encryptsNewChats, default: true),
                    )
                }
                savedName = saved.name
                name = saved.name
                availability = saved.availability
                savedStatus = saved.status
                status = saved.status
                sendsReadMarkers = saved.sendsReadMarkers
                linkPreviewSetting = saved.linkPreviewSetting
                sendsChatStates = saved.sendsChatStates
                sharesLastSeen = saved.sharesLastSeen
                sharesProfilePublicly = saved.sharesProfilePublicly
                downloadsFromGroupMembers = saved.downloadsFromGroupMembers
                relaysCalls = saved.relaysCalls
                includesMessagesInBackups = saved.includesMessagesInBackups
                gifsEnabled = saved.gifsEnabled
                encryptsNewChats = saved.encryptsNewChats
                isLoaded = true
            }
            .task(id: session.account) {
                await session.database.forEachValue(of: session.database.observeContact(session.account), "Own contact") { contact in
                    me = contact
                }
            }
        }
        .closableFromPushedScreens()
    }

    /// Read from the server's features, which are known once connected. The
    /// offline fixtures have none, so they stand in for a server that offers it.
    private var offersPasswordChange: Bool {
        #if DEBUG
        if DevFixture.isActive { return true }
        #endif
        // The features arrive after connecting; reading the state redraws this then.
        _ = model.connection
        return session.canChangePassword
    }

    /// Like `offersPasswordChange`: the server's features arrive after connecting.
    private var offersCommands: Bool {
        #if DEBUG
        if DevFixture.isActive { return false }
        #endif
        _ = model.connection
        return session.serverOffersCommands
    }

    private func setAvatar(from item: PhotosPickerItem) {
        let session = session
        profileAction.run {
            isChangingAvatar = true
            defer { isChangingAvatar = false }
            let prepared = try await AvatarImagePreparation.prepare(item)
            try await session.publishAvatar(prepared.data, mimeType: prepared.mimeType, width: prepared.side, height: prepared.side)
        }
    }

    private func saveName() {
        guard !isSavingName, XMPPSession.normalizedNickname(name) ?? "" != savedName else { return }
        let (session, typed) = (session, name)
        profileAction.run {
            isSavingName = true
            defer { isSavingName = false }
            try await session.setNickname(typed)
            savedName = await offMain { session.nickname ?? "" }
            name = savedName
        }
    }

    // Saved here and sent in the same call, so nothing waits on the server.
    private func setAvailability(_ new: XMPPSession.Availability) {
        Task {
            do {
                try await offMain { [session] in try session.setAvailability(new) }
                availability = new
            } catch {
                profileError = error.localizedDescription
            }
        }
    }

    private func saveStatus() {
        let message = status
        Task {
            do {
                savedStatus = try await offMain { [session] in
                    try session.setStatusMessage(message)
                    return session.statusMessage
                }
                status = savedStatus
            } catch {
                profileError = error.localizedDescription
            }
        }
    }

    private func removeAvatar() {
        let session = session
        profileAction.run {
            isChangingAvatar = true
            defer { isChangingAvatar = false }
            try await session.removeAvatar()
        }
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

    // The switch moves once the server has taken it, with a spinner and the
    // profile alert's Retry if it didn't.
    private func setSharesProfilePublicly(_ on: Bool) {
        let session = session
        profileAction.run {
            isChangingProfileAccess = true
            defer { isChangingProfileAccess = false }
            try await session.setSharesProfilePublicly(on)
            sharesProfilePublicly = on
        }
    }

    private func setDownloadsFromGroupMembers(_ on: Bool) {
        save({ [session] in try session.database.setFlag(.downloadsFromGroupMembers, on) }) { downloadsFromGroupMembers = on }
    }

    private func setRelaysCalls(_ on: Bool) {
        save({ [session] in try session.database.setFlag(.relaysCalls, on) }) { relaysCalls = on }
    }

    private func setIncludesMessagesInBackups(_ on: Bool) {
        save({ BackupPolicy.setIncludesMessages(on) }) { includesMessagesInBackups = on }
    }

    private func setGifsEnabled(_ on: Bool) {
        save({ [session] in try session.database.setFlag(.gifs, on) }) { gifsEnabled = on }
    }

    private func setEncryptsNewChats(_ on: Bool) {
        save({ [session] in try session.database.setFlag(.encryptsNewChats, on) }) { encryptsNewChats = on }
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
