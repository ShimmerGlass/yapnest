import SwiftUI
import YapnestKit

/// What an `xmpp:` link asks for, put to the user before anything is sent.
/// The address is always shown whole; a name in the link is only a suggestion.
struct LinkConfirmation: View {
    let session: XMPPSession
    let link: XMPPURI
    /// Called with the chat to open, and a body for its composer, or with
    /// nothing when the user backs out.
    var onDone: (JID?, String?) -> Void

    var body: some View {
        switch link.action {
        case .join:
            JoinGroupView(session: session, room: link.jid) { onDone($0, nil) }
        case .addContact, .chat:
            AddContactLinkView(session: session, link: link, onDone: onDone)
        }
    }
}

/// Adds someone a link names, or only opens a chat with them.
private struct AddContactLinkView: View {
    let session: XMPPSession
    let link: XMPPURI
    var onDone: (JID?, String?) -> Void

    @State private var name: String
    @State private var add = ServerAction()

    init(session: XMPPSession, link: XMPPURI, onDone: @escaping (JID?, String?) -> Void) {
        self.session = session
        self.link = link
        self.onDone = onDone
        if case .addContact(let name, _) = link.action { _name = State(initialValue: name ?? "") } else { _name = State(initialValue: "") }
    }

    private var preauth: String? {
        if case .addContact(_, let preauth) = link.action { preauth } else { nil }
    }

    private var chatBody: String? {
        if case .chat(let body) = link.action { body } else { nil }
    }

    private var opensChat: Bool {
        if case .chat = link.action { true } else { false }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(link.jid.description)
                        .font(.headline)
                        .textSelection(.enabled)
                    TextField("Name (optional)", text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Add this address?")
                } footer: {
                    Text(preauth == nil
                        ? "They'll be asked to accept, and will see your address and name."
                        : "This invitation lets them accept you right away. They will see your address and name.")
                }
                if opensChat {
                    Section {
                        Button("Chat Without Adding") { onDone(link.jid, chatBody) }
                            .disabled(add.isBusy)
                    } footer: {
                        Text("Nothing is sent to them until you write.")
                    }
                }
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { onDone(nil, nil) }
                        .disabled(add.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Add", isBusy: add.isBusy, action: addContact)
                }
            }
            .actionAlert("Couldn't add contact", add)
        }
        .presentationDetents([.medium])
        // Cancel is disabled meanwhile, but a swipe would still close the
        // sheet, and the late answer would close whatever is up by then.
        .interactiveDismissDisabled(add.isBusy)
    }

    private func addContact() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (session, peer, preauth) = (session, link.jid, preauth)
        let (opensChat, chatBody) = (opensChat, chatBody)
        // The sheet stays until the server has taken the contact, so a refusal
        // or silence is shown where the user asked.
        add.run {
            try await session.addContactAndWait(peer, name: name.isEmpty ? nil : name, preauth: preauth)
            onDone(opensChat ? peer : nil, chatBody)
        }
    }
}
