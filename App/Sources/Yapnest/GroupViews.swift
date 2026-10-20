import SwiftUI
import YapnestKit

/// Names a new private group and picks who's in it.
struct NewGroupView: View {
    let session: XMPPSession
    var onCreated: (JID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<JID> = []
    @State private var creation = ServerAction()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name", text: $name)
                } footer: {
                    Text("Only people you add can join, and messages are end-to-end encrypted.")
                }
                ContactPicker(session: session, selected: $selected)
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(creation.isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creation.isBusy {
                        ProgressView()
                    } else {
                        SheetConfirmButton("Create", action: create)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .errorAlert("Couldn't create the group", $creation.error)
        }
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let invitees = Array(selected)
        creation.run {
            let room = try await session.createGroup(name: name, inviting: invitees)
            onCreated(room)
        }
    }
}

/// Joins an existing group by its address, such as a public channel.
struct JoinGroupView: View {
    let session: XMPPSession
    var onJoined: (JID) -> Void
    /// The room a link named, if the sheet came from one.
    let linkRoom: JID?

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var nickname = ""
    @State private var joining = ServerAction()

    /// `room` is from a link, which the user still confirms with the whole
    /// address in front of them.
    init(session: XMPPSession, room: JID? = nil, onJoined: @escaping (JID) -> Void) {
        self.session = session
        self.onJoined = onJoined
        self.linkRoom = room
        _address = State(initialValue: room?.description ?? "")
    }

    /// An address from a link is one anyone can send us, so it must name a
    /// room that exists. One the user typed or edited may be made.
    static func mayCreate(_ room: JID, linkRoom: JID?) -> Bool {
        room != linkRoom
    }

    private var room: JID? {
        JID(pastedAddress: address)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("group@conference.example.org", text: $address)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Nickname (optional)", text: $nickname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Your nickname is how others in the group see you.")
                }
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(joining.isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                        .disabled(joining.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if joining.isBusy {
                        ProgressView()
                    } else {
                        SheetConfirmButton("Join", action: join).disabled(room == nil)
                    }
                }
            }
            .errorAlert("Couldn't join", $joining.error)
        }
        .presentationDetents([.medium])
        // The answer opens the chat, which a user who left no longer wants.
        .interactiveDismissDisabled(joining.isBusy)
    }

    private func join() {
        guard let room else { return }
        let nickname = nickname.trimmingCharacters(in: .whitespaces)
        joining.run {
            try await session.joinGroup(room, nickname: nickname.isEmpty ? nil : nickname, mayCreate: Self.mayCreate(room, linkRoom: linkRoom))
            onJoined(room)
        }
    }
}

/// What the picker's field decides, apart from the views.
enum ContactQuery {
    /// Contacts whose name or address contains the text, ignoring case.
    static func filter(_ contacts: [Contact], by query: String) -> [Contact] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.jid.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// The address the text names, if it may be added: one that's already a
    /// contact, in the group, ours or picked would only be a second way to
    /// reach a row that's there.
    static func addable(_ query: String, contacts: [Contact], excluding: Set<JID>, account: JID, selected: Set<JID>) -> JID? {
        guard let jid = JID(pastedAddress: query),
              jid != account,
              !excluding.contains(jid),
              !selected.contains(jid),
              !contacts.contains(where: { $0.jid == jid })
        else { return nil }
        return jid
    }
}

/// A contact's avatar, name and address, as the pickers list them.
struct ContactLabel: View {
    let session: XMPPSession
    let contact: Contact

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: contact.displayName, seed: contact.jid.description, imageURL: session.avatars.url(for: contact))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading) {
                Text(contact.displayName).foregroundStyle(.primary)
                Text(contact.jid.description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Roster contacts with checkmarks, and a field to add someone by address.
struct ContactPicker: View {
    let session: XMPPSession
    @Binding var selected: Set<JID>
    /// Left out, such as people already in the group.
    var excluding: Set<JID> = []

    /// nil until the roster is read.
    @State private var contacts: [Contact]?
    @State private var query = ""

    private var addable: JID? {
        ContactQuery.addable(query, contacts: contacts ?? [], excluding: excluding, account: session.account, selected: selected)
    }

    /// Picked addresses that aren't in the roster, so no contact row shows them.
    private var pickedStrangers: [JID] {
        let known = Set((contacts ?? []).map(\.jid))
        return selected.filter { !known.contains($0) }.sorted()
    }

    var body: some View {
        Section {
            TextField("Name or address", text: $query)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { if let addable { add(addable) } }
            if let addable {
                Button { add(addable) } label: {
                    Label("Add \(addable.description)", systemImage: "person.badge.plus")
                }
                .accessibilityLabel("Add \(addable.description)")
            }
            ForEach(pickedStrangers, id: \.self) { jid in
                Button { selected.remove(jid) } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: jid.shortName, seed: jid.description, imageURL: nil)
                            .frame(width: 36, height: 36)
                        Text(jid.description).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .imageScale(.large)
                    }
                }
                .accessibilityLabel(jid.description)
                .accessibilityAddTraits(.isSelected)
            }
            ForEach(ContactQuery.filter(contacts ?? [], by: query), id: \.jid) { contact in
                Button {
                    if selected.contains(contact.jid) { selected.remove(contact.jid) } else { selected.insert(contact.jid) }
                } label: {
                    HStack(spacing: 12) {
                        ContactLabel(session: session, contact: contact)
                        Spacer()
                        Image(systemName: selected.contains(contact.jid) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(contact.jid) ? Color.accentColor : .secondary)
                            .imageScale(.large)
                    }
                }
                .accessibilityAddTraits(selected.contains(contact.jid) ? .isSelected : [])
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Enter an address to add someone who isn't in your contacts.")
        }
        .task {
            let (excluding, account) = (excluding, session.account)
            contacts = await offMain { [session] in
                ((try? session.database.roster()) ?? []).filter { !excluding.contains($0.jid) && $0.jid != account }
            }
        }
    }

    private func add(_ jid: JID) {
        selected.insert(jid)
        query = ""
    }
}

/// Picks contacts to add to an existing group.
struct InviteView: View {
    let session: XMPPSession
    let room: JID
    let members: Set<JID>

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<JID> = []
    @State private var invitation = ServerAction()

    var body: some View {
        NavigationStack {
            Form {
                ContactPicker(session: session, selected: $selected, excluding: members)
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(invitation.isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if invitation.isBusy {
                        ProgressView()
                    } else {
                        SheetConfirmButton("Add", action: invite).disabled(selected.isEmpty)
                    }
                }
            }
            .errorAlert("Couldn't add them", $invitation.error)
        }
    }

    private func invite() {
        let invitees = Array(selected)
        invitation.run {
            try await session.invite(invitees, to: room)
            dismiss()
        }
    }
}

extension RoomStatus {
    /// Everyone in the group: members whether or not they're here, and
    /// occupants whose address we can't see.
    var memberCount: Int {
        let present = occupants.values
        let anonymous = present.filter { $0.jid == nil }.count
        return members.union(present.compactMap(\.jid)).count + anonymous
    }
}
