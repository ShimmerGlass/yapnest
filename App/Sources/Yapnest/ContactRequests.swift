import SwiftUI
import YapnestKit

/// Someone who asked to add us, at the top of the chat list, with Accept
/// and Decline. Tapping it opens a chat with them.
struct ContactRequestRow: View {
    let session: XMPPSession
    let contact: Contact
    let onOpen: () -> Void

    @State private var confirmsBlock = false
    @State private var answer = ServerAction()

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AvatarView(
                        name: contact.requestTitle,
                        seed: contact.jid.description,
                        imageURL: session.avatars.url(for: contact),
                    )
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.requestTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(contact.jid.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Decline", systemImage: "xmark") { perform(session.declineContactRequest) }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(answer.isBusy)
            Button("Accept", systemImage: "checkmark") { perform(session.acceptContactRequest) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(answer.isBusy)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Accept", systemImage: "checkmark") { perform(session.acceptContactRequest) }
            Button("Decline", systemImage: "xmark") { perform(session.declineContactRequest) }
            Button("Block", systemImage: "hand.raised", role: .destructive) { confirmsBlock = true }
        }
        .blockConfirmation(isPresented: $confirmsBlock, session: session, peer: contact.jid, name: contact.requestTitle)
        .actionAlert("Couldn't answer", answer)
    }

    private func perform(_ action: @escaping @Sendable (JID) throws -> Void) {
        let jid = contact.jid
        answer.run { try await offMain { try action(jid) } }
    }
}

/// Adds someone to the roster, with a spinner until the server has taken
/// them, and an alert if it refuses or doesn't answer. The roster push then
/// hides the button.
struct AddContactButton: View {
    let session: XMPPSession
    let peer: JID

    @State private var add = ServerAction()

    var body: some View {
        Button(action: addContact) {
            BusyLabel(title: "Add to Contacts", systemImage: "person.badge.plus", isBusy: add.isBusy)
        }
        .disabled(add.isBusy)
        .actionAlert("Couldn't add contact", add)
    }

    private func addContact() {
        let (session, peer) = (session, peer)
        add.run { try await session.addContactAndWait(peer) }
    }
}

extension Contact {
    /// The name they asked with, which is theirs to pick; the address is
    /// always shown next to it.
    var requestTitle: String {
        if let requestedNickname, !requestedNickname.isEmpty { return requestedNickname }
        return displayName
    }
}
