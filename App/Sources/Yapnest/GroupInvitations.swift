import SwiftUI
import YapnestKit

/// A group a contact seems to have invited us to, but whose server can't
/// vouch for them, at the top of the chat list. Nothing is joined until
/// Join is confirmed, after the warning about what can't be known.
struct GroupInvitationRow: View {
    let session: XMPPSession
    let invitation: GroupInvitation

    @State private var confirmsJoin = false
    @State private var joining = ServerAction()

    /// Their name from the contacts, read once off the main thread.
    @State private var knownName: String?

    private var inviterName: String { knownName ?? invitation.inviter.description }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(invitation.room.description)
                    .font(.headline)
                    .lineLimit(1)
                Text("Invited by \(inviterName) (\(invitation.inviter.description)), unconfirmed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let reason = invitation.reason {
                    Text(reason)
                        .font(.subheadline)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Decline", systemImage: "xmark", action: decline)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(joining.isBusy)
            Button {
                confirmsJoin = true
            } label: {
                if joining.isBusy {
                    ProgressView()
                } else {
                    Label("Join", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(joining.isBusy)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Join", systemImage: "checkmark") { confirmsJoin = true }
                .disabled(joining.isBusy)
            Button("Decline", systemImage: "xmark", action: decline)
                .disabled(joining.isBusy)
        }
        .confirmationDialog("Join this group?", isPresented: $confirmsJoin, titleVisibility: .visible) {
            Button("Join", action: join)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(invitation.room.description) says \(inviterName) invited you. This can't be confirmed: the group is on a different server than \(inviterName)'s, and that server could name anyone as the inviter.\n\nJoining shows the group your nickname and that you're online, and adds the group to all your devices. If you're unsure, ask \(inviterName) first.")
        }
        .errorAlert("Couldn't join", $joining.error)
        .task(id: invitation.inviter) {
            let inviter = invitation.inviter
            knownName = await offMain { [session] in (try? session.database.contact(inviter))?.displayName }
        }
    }

    private func join() {
        let (session, room) = (session, invitation.room)
        joining.run { try await session.acceptGroupInvitation(room) }
    }

    private func decline() {
        let room = invitation.room
        Task {
            do { try await offMain { [session] in try session.declineGroupInvitation(room) } } catch { self.joining.error = error.localizedDescription }
        }
    }
}
