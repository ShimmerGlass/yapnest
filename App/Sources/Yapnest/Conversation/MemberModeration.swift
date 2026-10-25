import SwiftUI
import YapnestKit

extension View {
    /// What an owner or admin may do with a member of the group: remove, kick
    /// or ban them, and for owners make or unmake admins and owners. Offered in the row's
    /// menu and on swipe, only for what the room would allow.
    /// `isLastOwner` is worked out once for the list, not for each row.
    /// `onCommands`, when the member offers commands, adds an item for them to
    /// the menu, as a row can only have the one menu.
    func memberModeration(
        of row: MemberRow.Model, in room: RoomStatus?, isLastOwner: Bool, group: JID, session: XMPPSession, onCommands: (() -> Void)? = nil,
    ) -> some View {
        modifier(MemberModeration(row: row, room: room, isLastOwner: isLastOwner, group: group, session: session, onCommands: onCommands))
    }
}

private struct MemberModeration: ViewModifier {
    let row: MemberRow.Model
    let room: RoomStatus?
    let isLastOwner: Bool
    let group: JID
    let session: XMPPSession
    let onCommands: (() -> Void)?

    @State private var server = ServerAction()
    // Its own action, as its failure isn't a change to the group. Kept here
    // rather than in `AddContactButton`, whose state would go with the menu.
    @State private var addContact = ServerAction()
    // `row.contact` only reloads when the room changes.
    @State private var didAddContact = false
    @State private var confirming: Confirmation?

    private enum Confirmation: Equatable {
        case remove, ban, kick, makeOwner, removeOwner
    }

    private var actions: GroupModeration.MemberActions {
        guard let room, room.isJoined, row.jid != nil else { return GroupModeration.MemberActions() }
        return GroupModeration.actions(
            by: room.affiliation, on: row.affiliation, isSelf: row.isMe, isLastOwner: isLastOwner,
            actorRole: room.role, targetIsPresent: row.isPresent && row.nick != nil,
        )
    }

    private var isBusy: Bool { server.isBusy || addContact.isBusy }

    private var canAddContact: Bool {
        row.jid != nil && !row.isMe && row.contact?.isInRoster != true && !didAddContact
    }

    func body(content: Content) -> some View {
        let actions = actions
        content
            .overlay(alignment: .trailing) {
                if isBusy { ProgressView() }
            }
            .opacity(isBusy ? 0.5 : 1)
            .contextMenu {
                if let onCommands { Button("Commands", systemImage: "terminal", action: onCommands) }
                if canAddContact, !isBusy {
                    Button("Add to Contacts", systemImage: "person.badge.plus", action: add)
                }
                if !actions.isEmpty, !isBusy {
                    if onCommands != nil || canAddContact { Divider() }
                    buttons(actions)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !server.isBusy {
                    if actions.canRemove {
                        Button("Remove", systemImage: "person.badge.minus", role: .destructive) { confirming = .remove }
                    }
                    if actions.canKick {
                        Button("Kick", systemImage: "figure.walk.departure", role: .destructive) { confirming = .kick }
                    }
                    if actions.canBan {
                        Button("Ban", systemImage: "nosign", role: .destructive) { confirming = .ban }
                    }
                }
            }
            .alert(
                confirming.map(title(of:)) ?? "",
                isPresented: Binding(isPresent: $confirming),
                presenting: confirming,
            ) { confirmation in
                switch confirmation {
                case .remove:
                    Button("Remove", role: .destructive) { remove() }
                case .ban:
                    Button("Ban", role: .destructive) { ban() }
                case .kick:
                    Button("Kick", role: .destructive) { kick() }
                case .makeOwner:
                    Button("Make Owner") { setOwner(true) }
                case .removeOwner:
                    Button("Remove Ownership", role: .destructive) { setOwner(false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                switch confirmation {
                case .remove: Text("They'll be taken out of the group and can't read it any more. Someone can add them again.")
                case .ban: Text("They'll be taken out of the group, and can't come back until they're allowed to.")
                case .kick: Text("They'll be taken out of the group now, but stay a member and can come back.")
                case .makeOwner: Text("Owners can change the group's settings, make and remove other owners, and delete the group.")
                case .removeOwner:
                    Text(row.isMe
                        ? "You'll become an admin and no longer be able to change the group's settings or delete it."
                        : "They'll become an admin and no longer be able to change the group's settings or delete it.")
                }
            }
            .actionAlert("Couldn't change the group", server)
            .actionAlert("Couldn't add contact", addContact)
    }

    private func title(of confirmation: Confirmation) -> LocalizedStringKey {
        switch confirmation {
        case .remove: "Remove \(row.displayName)?"
        case .ban: "Ban \(row.displayName)?"
        case .kick: "Kick \(row.displayName)?"
        case .makeOwner: "Make \(row.displayName) an owner?"
        case .removeOwner: row.isMe ? "Remove your ownership?" : "Remove \(row.displayName)'s ownership?"
        }
    }

    @ViewBuilder
    private func buttons(_ actions: GroupModeration.MemberActions) -> some View {
        if actions.canMakeAdmin {
            Button("Make Admin", systemImage: "person.badge.key") { setAdmin(true) }
        }
        if actions.canRemoveAdmin {
            Button("Remove Admin", systemImage: "person.badge.shield.exclamationmark") { setAdmin(false) }
        }
        if actions.canMakeOwner {
            Button("Make Owner", systemImage: "crown") { confirming = .makeOwner }
        }
        if actions.canRemoveOwner {
            Button(row.isMe ? "Remove My Ownership" : "Remove Ownership", systemImage: "crown.fill") { confirming = .removeOwner }
        }
        if actions.canKick {
            Button("Kick from Group", systemImage: "figure.walk.departure", role: .destructive) { confirming = .kick }
        }
        if actions.canRemove {
            Button("Remove from Group", systemImage: "person.badge.minus", role: .destructive) { confirming = .remove }
        }
        if actions.canBan {
            Button("Ban from Group", systemImage: "nosign", role: .destructive) { confirming = .ban }
        }
    }

    private func run(_ work: @escaping @MainActor (XMPPSession, JID, JID) async throws -> Void) {
        guard let jid = row.jid else { return }
        server.run { [session, group] in try await work(session, jid, group) }
    }

    // No name: the nick is the member's own pick, and a roster name is the
    // user's on every device (see `acceptContactRequest`).
    private func add() {
        guard let jid = row.jid else { return }
        addContact.run { [session] in
            try await session.addContactAndWait(jid)
            didAddContact = true
        }
    }

    private func remove() { run { try await $0.removeMember($1, from: $2) } }

    private func ban() { run { try await $0.banMember($1, from: $2) } }

    private func kick() {
        guard let nick = row.nick else { return }
        server.run { [session, group] in try await session.kick(nickname: nick, in: group) }
    }

    private func setOwner(_ isOwner: Bool) { run { try await $0.setOwner(isOwner, member: $1, in: $2) } }

    private func setAdmin(_ isAdmin: Bool) { run { try await $0.setAdmin(isAdmin, member: $1, in: $2) } }
}
