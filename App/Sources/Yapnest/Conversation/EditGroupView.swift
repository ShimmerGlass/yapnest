import PhotosUI
import SwiftUI
import YapnestKit

/// An edit of a group: its subject, and for owners also its picture, name,
/// description, who may join and who sees what. Each part is
/// sent on its own, and only if it changed.
struct EditGroupView: View {
    let session: XMPPSession
    let room: JID
    let group: GroupChat
    let identity: ChatIdentity

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    private enum Picture {
        case unchanged
        case replaced(AvatarImagePreparation.Prepared, UIImage)
        case removed
    }

    private enum Loading {
        case loading
        /// What the room's form had.
        case loaded(RoomConfiguration)
        case failed(String)
    }

    @State private var name: String
    @State private var subject: String
    @State private var description = ""
    @State private var picture = Picture.unchanged
    @State private var photo: PhotosPickerItem?
    @State private var preparingPicture = ServerAction()
    @State private var loading = Loading.loading
    @State private var options = RoomConfiguration()
    @State private var isSaving = false
    @State private var confirmsEncryptionOff = false
    @State private var failures: String?
    /// What the room has now, kept as parts of the save go through so a
    /// retry sends only what is left.
    @State private var savedName: String
    @State private var savedSubject: String

    init(session: XMPPSession, room: JID, group: GroupChat, identity: ChatIdentity) {
        self.session = session
        self.room = room
        self.group = group
        self.identity = identity
        // The room's own name, not what is shown for it: an unnamed room
        // shows its address's, which saving would then make its name.
        _name = State(initialValue: group.name ?? "")
        _savedName = State(initialValue: group.name ?? "")
        _subject = State(initialValue: group.subject ?? "")
        _savedSubject = State(initialValue: group.subject ?? "")
    }

    private var status: RoomStatus? { model.live.room(room).status }
    private var isOwner: Bool { status?.canEditInfo == true }
    private var canChangeSubject: Bool { status?.canChangeSubject == true }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSubject: String { subject.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What the room's form says now, once read; the options are hidden until then.
    private var loaded: RoomConfiguration? {
        if case .loaded(let configuration) = loading { configuration } else { nil }
    }

    /// Until the form is read, `options` has no fields but the name, so only
    /// the name can differ.
    private var configurationChange: RoomConfiguration? {
        guard isOwner else { return nil }
        var draft = options
        draft.name = Self.nameToSend(trimmedName, saved: savedName)
        return draft.difference(from: loaded ?? RoomConfiguration(name: savedName))
    }

    /// The name to send, or nil if the field wasn't touched. An unnamed room's
    /// name is empty here but may be absent from its form, so comparing with
    /// the form's could read as a change that nobody made.
    static func nameToSend(_ name: String, saved: String) -> String? {
        name == saved ? nil : name
    }

    private var changesPicture: Bool {
        if case .unchanged = picture { return false }
        return isOwner
    }

    private var changesSubject: Bool { canChangeSubject && trimmedSubject != savedSubject }

    private var hasChanges: Bool { changesPicture || configurationChange != nil || changesSubject }

    private var canSave: Bool {
        hasChanges && !isSaving && !preparingPicture.isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                if isOwner { pictureSection }
                Section {
                    if isOwner {
                        TextField("Name", text: $name, prompt: Text(group.displayName))
                            .accessibilityLabel("Name")
                        if loaded != nil {
                            TextField("Description", text: $options.descriptionBinding, axis: .vertical)
                                .lineLimit(1...4)
                        }
                    }
                    if canChangeSubject {
                        TextField("Subject", text: $subject, axis: .vertical)
                            .lineLimit(1...4)
                    }
                } footer: {
                    if canChangeSubject {
                        Text("The subject is shown to everyone at the top of the group.")
                    }
                }
                if isOwner { optionsSection }
            }
            .dismissesKeyboardOnTap()
            .disabled(isSaving)
            .navigationTitle("Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Save", isBusy: isSaving, action: save).disabled(!canSave)
                }
            }
            .errorAlert("Couldn't save everything", $failures)
            .actionAlert("Couldn't use that picture", preparingPicture)
            .confirmationDialog("Turn off encryption?", isPresented: $confirmsEncryptionOff, titleVisibility: .visible) {
                Button("Turn Off Encryption", role: .destructive, action: perform)
            } message: {
                Text("This turns end-to-end encryption off for the group. The server will be able to read its messages.")
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                choosePicture(item)
            }
            .task(id: isOwner) {
                guard isOwner, loaded == nil else { return }
                await loadConfiguration()
            }
        }
    }

    // MARK: Sections

    private var pictureSection: some View {
        Section {
            VStack(spacing: 12) {
                pictureView
                    .frame(width: 80, height: 80)
                    .overlay {
                        if preparingPicture.isBusy { ProgressView() }
                    }
                HStack(spacing: 24) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose Picture", systemImage: "photo")
                    }
                    if hasPicture {
                        Button("Remove Picture", systemImage: "trash", role: .destructive) { picture = .removed }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(preparingPicture.isBusy)
            }
            .frame(maxWidth: .infinity)
            .avatarHeaderRow()
        }
        .listRowBackground(Color.clear)
    }

    private var hasPicture: Bool {
        switch picture {
        case .unchanged: identity.imageURL != nil
        case .replaced: true
        case .removed: false
        }
    }

    @ViewBuilder
    private var pictureView: some View {
        switch picture {
        case .replaced(_, let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        case .removed:
            AvatarView(name: group.displayName, seed: identity.seed, imageURL: nil, isGroup: true)
        case .unchanged:
            AvatarView(name: group.displayName, seed: identity.seed, imageURL: identity.imageURL, isGroup: true)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        switch loading {
        case .loading:
            Section("Options") {
                HStack {
                    Text("Loading").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }
        case .failed(let reason):
            Section("Options") {
                Text("The group's options couldn't be read: \(reason)")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    loading = .loading
                    Task { await loadConfiguration() }
                }
            }
        case .loaded(let loaded):
            if loaded.isMembersOnly != nil {
                Section {
                    Toggle("Members only", isOn: Binding(get: { options.isMembersOnly ?? false }, set: { options.isMembersOnly = $0 }))
                } footer: {
                    Text(options.isMembersOnly == true
                        ? "Only people you add can join."
                        : "Anyone who knows the group's address can join.")
                }
            }
            let hasAddresses = loaded.whoCanSeeAddresses != nil
            let hasInvite = loaded.membersCanInvite != nil
            let hasSubject = loaded.membersCanChangeSubject != nil
            if hasAddresses || hasInvite || hasSubject {
                Section {
                    if hasAddresses {
                        Picker("Who can see members' addresses", selection: Binding(
                            get: { options.whoCanSeeAddresses ?? .anyone }, set: { options.whoCanSeeAddresses = $0 },
                        )) {
                            Text("Everyone").tag(RoomConfiguration.AddressVisibility.anyone)
                            Text("Admins").tag(RoomConfiguration.AddressVisibility.moderators)
                        }
                    }
                    if hasInvite {
                        Toggle("Members can invite", isOn: Binding(get: { options.membersCanInvite ?? false }, set: { options.membersCanInvite = $0 }))
                    }
                    if hasSubject {
                        Toggle("Members can change the subject", isOn: Binding(
                            get: { options.membersCanChangeSubject ?? false }, set: { options.membersCanChangeSubject = $0 },
                        ))
                    }
                } footer: {
                    if hasAddresses {
                        Text("A group can only be encrypted when it is members only and everyone sees members' addresses.")
                    }
                }
            }
        }
    }

    // MARK: Server

    private func loadConfiguration() async {
        do {
            var configuration = try await session.roomConfiguration(of: room)
            options = configuration
            // Typing started before the form arrived is kept.
            if trimmedName == savedName, let formName = configuration.name, !formName.isEmpty {
                name = formName
                savedName = formName
                configuration.name = formName
            }
            loading = .loaded(configuration)
        } catch {
            loading = .failed(error.localizedDescription)
        }
    }

    private func choosePicture(_ item: PhotosPickerItem) {
        preparingPicture.run {
            let prepared = try await AvatarImagePreparation.prepare(item)
            guard let image = UIImage(data: prepared.data) else { throw AvatarImagePreparation.UnreadableError() }
            picture = .replaced(prepared, image)
        }
    }

    private func save() {
        if group.wouldStopBeingPrivate(by: configurationChange) {
            confirmsEncryptionOff = true
        } else {
            perform()
        }
    }

    private func perform() {
        guard !isSaving else { return }
        isSaving = true
        let pictureChange = changesPicture ? picture : .unchanged
        let configuration = configurationChange
        let newSubject = changesSubject ? trimmedSubject : nil
        Task {
            var failed: [String] = []
            switch pictureChange {
            case .unchanged: break
            case .replaced(let prepared, _):
                await attempt("Picture", &failed) {
                    try await session.setGroupAvatar(prepared.data, mimeType: prepared.mimeType, in: room)
                    picture = .unchanged
                }
            case .removed:
                await attempt("Picture", &failed) {
                    try await session.setGroupAvatar(nil, in: room)
                    picture = .unchanged
                }
            }
            if let configuration {
                await attempt("Settings", &failed) {
                    try await session.updateRoomConfiguration(configuration, in: room)
                    if let name = configuration.name { savedName = name }
                    if let current = loaded { loading = .loaded(current.merging(configuration)) }
                }
            }
            if let newSubject {
                await attempt("Subject", &failed) {
                    try await session.setSubject(newSubject, in: room)
                    savedSubject = newSubject
                }
            }
            isSaving = false
            if failed.isEmpty {
                dismiss()
            } else {
                failures = failed.joined(separator: "\n")
            }
        }
    }

    private func attempt(_ part: LocalizedStringResource, _ failed: inout [String], _ work: @MainActor () async throws -> Void) async {
        do { try await work() } catch { failed.append("\(String(localized: part)): \(error.localizedDescription)") }
    }
}

private extension RoomConfiguration {
    /// The description as text for a field, which the room's form has once read.
    var descriptionBinding: String {
        get { description ?? "" }
        set { description = newValue }
    }
}
