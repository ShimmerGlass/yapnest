import PhotosUI
import SwiftUI
import YapnestKit

/// Who you are to your contacts, as a sheet from the avatar button: name,
/// photo and status, who may see them, and the account itself.
struct ProfileView: View {
    let session: XMPPSession

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var me: Contact?
    @State private var sharesProfilePublicly = false
    @State private var isChangingProfileAccess = false
    @State private var confirmsSignOut = false
    @State private var photo: PhotosPickerItem?
    @State private var isChangingAvatar = false
    @State private var profileError: String?
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
                        ForEach(XMPPSession.Availability.allCases, id: \.self) { Text($0.label).tag($0) }
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
                    HStack {
                        Toggle("Show My Name and Photo to Everyone", isOn: Binding(get: { sharesProfilePublicly }, set: setSharesProfilePublicly))
                            .disabled(profileAction.isBusy)
                        if isChangingProfileAccess { ProgressView() }
                    }
                } footer: {
                    Text("With this off, only your contacts see your name and photo. People you haven't added, including members of your groups, don't.")
                }
                .disabled(!isLoaded)

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
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
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
                        sharesProfilePublicly: session.sharesProfilePublicly,
                    )
                }
                savedName = saved.name
                name = saved.name
                availability = saved.availability
                savedStatus = saved.status
                status = saved.status
                sharesProfilePublicly = saved.sharesProfilePublicly
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
}
