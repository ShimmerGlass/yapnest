import SwiftUI
import YapnestKit

/// Who is banned from a group, for its admins and owners, who can let them
/// back in. Only the room can say who is banned, so the list is asked for
/// when this opens.
struct BannedMembersView: View {
    let session: XMPPSession
    let room: JID

    @Environment(AppModel.self) private var model
    @State private var loadError: String?
    @State private var lifting = ServerAction()
    @State private var isLoading = true
    /// Who is being let back in, for the spinner on their row.
    @State private var unbanning: JID?
    @State private var names: [JID: String] = [:]

    private var banned: [JID] {
        (model.rooms[room]?.banned ?? []).sorted { $0.description < $1.description }
    }

    var body: some View {
        let banned = banned
        List {
            ForEach(banned, id: \.self) { jid in
                row(jid)
            }
        }
        .overlay {
            if banned.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No one is banned", systemImage: "nosign")
                }
            }
        }
        .navigationTitle("Banned")
        .navigationBarTitleDisplayMode(.inline)
        .sheetDoneButton()
        .errorAlert("Couldn't load the banned list", $loadError)
        .actionAlert("Couldn't unban", lifting)
        .task {
            // The room's list replaces what we have, so it is read before the
            // spinner goes.
            do { try await session.refreshBanList(of: room) } catch { loadError = error.localizedDescription }
            isLoading = false
        }
        .task(id: banned) {
            let session = session, jids = banned
            names = await offMain {
                (try? session.database.contactNames(of: jids)) ?? [:]
            }
        }
    }

    private func row(_ jid: JID) -> some View {
        let busy = unbanning == jid
        return HStack {
            VStack(alignment: .leading) {
                if let name = names[jid], name != jid.description {
                    Text(name)
                    Text(jid.description).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(jid.description)
                }
            }
            Spacer()
            if busy { ProgressView() }
        }
        .opacity(busy ? 0.5 : 1)
        .contextMenu { unbanButton(jid) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { unbanButton(jid).tint(.accentColor) }
    }

    @ViewBuilder
    private func unbanButton(_ jid: JID) -> some View {
        if !lifting.isBusy { Button("Unban", systemImage: "arrow.uturn.backward") { lift(jid) } }
    }

    private func lift(_ jid: JID) {
        unbanning = jid
        lifting.run { [session, room] in
            defer { unbanning = nil }
            try await session.unban(jid, in: room)
        }
    }
}
