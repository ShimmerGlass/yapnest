import SwiftUI
import YapnestKit

struct NewChatView: View {
    let session: XMPPSession
    var onStart: (JID) -> Void
    var onNewGroup: () -> Void
    var onJoinGroup: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// nil until the roster is read.
    @State private var contacts: [Contact]?

    private var matches: [Contact] {
        ContactQuery.filter(contacts ?? [], by: query)
    }

    /// The address typed, if it can be chatted with: one that's already a
    /// contact has its own row, and we can't chat with ourselves. A bare
    /// domain is a gateway or bot component, which people do chat with.
    private var typedAddress: JID? {
        guard let jid = JID(chatAddress: query), jid != session.account else { return nil }
        return jid
    }

    /// Who Return starts a chat with: the typed address, or the one contact
    /// the text narrows the list to.
    private func target(in matches: [Contact]) -> JID? {
        if let typedAddress { return typedAddress }
        return matches.count == 1 ? matches[0].jid : nil
    }

    var body: some View {
        let matches = matches
        NavigationStack {
            Form {
                TextField("Name or address", text: $query)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(start)
                if let typedAddress, !(contacts ?? []).contains(where: { $0.jid == typedAddress }) {
                    Section {
                        Button("Chat with \(typedAddress.description)", systemImage: "bubble.left") { onStart(typedAddress) }
                    }
                }
                Section {
                    Button("New Group", systemImage: "person.2", action: onNewGroup)
                    Button("Join a Group", systemImage: "number", action: onJoinGroup)
                }
                if !matches.isEmpty {
                    Section("Contacts") {
                        ForEach(matches, id: \.jid) { contact in
                            Button { onStart(contact.jid) } label: {
                                ContactLabel(session: session, contact: contact)
                            }
                        }
                    }
                }
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton(iconOnMac: true) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Chat", iconOnMac: true, action: start).disabled(target(in: matches) == nil)
                }
            }
            .task {
                let account = session.account
                contacts = await offMain { [session] in
                    ((try? session.database.roster()) ?? []).filter { $0.jid != account }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func start() {
        if let target = target(in: matches) { onStart(target) }
    }
}
