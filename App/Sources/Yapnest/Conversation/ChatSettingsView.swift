import GRDB
import Observation
import SwiftUI
import YapnestKit

/// Per-conversation settings, from the conversation's header.
struct ChatSettingsView: View {
    let session: XMPPSession
    let peer: JID
    /// What the conversation shows of the chat, kept live by its parent.
    let identity: ChatIdentity
    /// Calling is offered, by the same rule as the conversation's Call button.
    let canCall: Bool
    /// Video calling is offered too: the peer has a device that takes video.
    let canVideoCall: Bool
    /// Opens the chat's search; the conversation does it once this has closed.
    let onSearch: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var isEncrypted = true
    /// The first read has arrived. The sections depend on it (a group or a
    /// person), so the form stays hidden until then.
    @State private var isLoaded = false
    @State private var linkPreviews: Bool?
    @State private var notificationSound: String?
    @State private var notificationInterval: Int?
    @State private var previewsOffInSettings = false
    /// Set for group chats.
    @State private var group: GroupChat?
    @State private var showsInvite = false
    @State private var confirmsLeave = false
    @State private var contact: Contact?
    @State private var confirmsBlock = false
    @State private var unblock = ServerAction()
    @State private var memberRows: [MemberRow.Model] = []
    @State private var probeNickList: [String] = []
    /// Nicks of occupants that said they take commands, and the ones asked so
    /// far. Occupants of a room send no capabilities, so each is asked once.
    @State private var commandNicks: Set<String> = []
    @State private var probedNicks: Set<String> = []
    @State private var commandsTarget: CommandsTarget?
    @State private var confirmsRemove = false
    @State private var remove = ServerAction()
    @State private var rename = ServerAction()
    @State private var asksNickname = false
    @State private var nicknameDraft = ""
    @State private var leave = ServerAction()
    @State private var destroy = ServerAction()
    @State private var confirmsDestroy = false
    @State private var showsEdit = false
    @State private var changeNotify = ServerAction()
    /// The contact's devices that take commands. Presence changes them, so
    /// they are read each time the view appears.
    @State private var commandEntities: [String] = []
    /// Why a setting couldn't be saved.
    @State private var saveError: String?
    @State private var saves = SettingsWrites()

    /// What the form starts from, read off the main thread.
    private struct Initial: Sendable {
        var isEncrypted: Bool
        var linkPreviews: Bool?
        var notificationSound: String?
        var notificationInterval: Int?
        var previewsOff: Bool
        var group: GroupChat?
        var contact: Contact?
    }

    private func loadInitial() async {
        let session = session, peer = peer
        let initial = await offMain {
            let database = session.database
            return Initial(
                isEncrypted: (try? database.isEncrypted(with: peer)) ?? true,
                linkPreviews: (try? database.linkPreviews(peer: peer)) ?? nil,
                notificationSound: (try? database.notificationSound(peer: peer)) ?? nil,
                notificationInterval: (try? database.notificationInterval(peer: peer)) ?? nil,
                previewsOff: database.linkPreviewSetting == .never,
                group: try? database.groupChat(peer),
                contact: try? database.contact(peer),
            )
        }
        isEncrypted = initial.isEncrypted
        linkPreviews = initial.linkPreviews
        notificationSound = initial.notificationSound
        notificationInterval = initial.notificationInterval
        previewsOffInSettings = initial.previewsOff
        group = initial.group
        contact = initial.contact
        isLoaded = true
    }

    private var room: RoomStatus? { model.live.room(peer).status }

    /// The addresses a 1:1 peer takes commands at: its own if it's a bare
    /// domain, and the devices that say so in their capabilities. A component
    /// such as a gateway sends no presence, and needn't list commands in its
    /// disco#info either (slidge doesn't), so its list is always asked for.
    private var peerCommandEntities: [String] {
        (peer.localPart == nil && group == nil ? [peer.description] : []) + commandEntities
    }

    private var header: some View {
        Section {
            VStack(spacing: 12) {
                identity.avatar(size: 80)
                VStack(spacing: 2) {
                    Text(identity.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    identity.subtitleLine(.subheadline)
                    // The address, unless the title already is it.
                    if identity.title != peer.description {
                        Text(peer.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let subject = group?.subject {
                        Text(subject)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                HStack(spacing: 10) {
                    if canCall {
                        HeaderAction(title: "Call", systemImage: "phone") {
                            dismiss()
                            model.calls.startCall(to: peer)
                        }
                        .disabled(model.calls.isInCall)
                    }
                    if canCall, canVideoCall {
                        HeaderAction(title: "Video", systemImage: "video") {
                            dismiss()
                            model.calls.startCall(to: peer, video: true)
                        }
                        .disabled(model.calls.isInCall)
                    }
                    HeaderAction(title: "Search", systemImage: "magnifyingglass") {
                        onSearch()
                        dismiss()
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .avatarHeaderRow()
        }
        .listRowBackground(Color.clear)
        // The buttons belong with the header; the first section shouldn't sit
        // a full section's gap away from them.
        .listSectionSpacing(.compact)
    }

    var body: some View {
        NavigationStack {
            Form {
                header

                if let group { groupSections(group, probeNicks: probeNickList) }

                if group == nil, contact?.seesPresence == true, let status = model.live.peer(peer).status {
                    Section("Status") {
                        Text(status)
                    }
                }

                // Only for the roster: naming anyone else would add them.
                if group == nil, peer != session.account, contact?.isInRoster == true {
                    Section {
                        Button {
                            nicknameDraft = contact?.name ?? ""
                            asksNickname = true
                        } label: {
                            LabeledContent {
                                Text(contact?.name ?? "None")
                            } label: {
                                // Not `.row`: its label inside LabeledContent made
                                // the row several times its height. The tint
                                // keeps the name and title primary; the icon is
                                // coloured here instead.
                                Label {
                                    Text("Nickname")
                                } icon: {
                                    if rename.isBusy { ProgressView() } else { Image(systemName: "pencil").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                        .tint(.primary)
                        .disabled(rename.isBusy)
                    } footer: {
                        Text("Only you see this, on all your devices. Without one, you see the name they chose, or their address.")
                    }
                }

                if group == nil {
                    Section {
                        NavigationLink {
                            NotificationSoundPicker(selection: Binding(get: { notificationSound }, set: setNotificationSound))
                        } label: {
                            LabeledContent {
                                Text(NotificationSound.displayName(of: notificationSound))
                            } label: {
                                Label("Notification sound", systemImage: "speaker.wave.2")
                            }
                        }
                        if !peerCommandEntities.isEmpty {
                            NavigationLink {
                                CommandsListView(
                                    title: "Commands", session: session,
                                    entities: peerCommandEntities.map { (label: $0.split(separator: "/", maxSplits: 1).last.map(String.init), jid: $0) },
                                )
                            } label: {
                                Label("Commands", systemImage: "terminal")
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { isEncrypted }, set: setEncrypted)) {
                        Label("Encrypt messages", systemImage: "lock")
                    }
                    .disabled(group.map { !$0.isPrivate } ?? false)
                    if group == nil {
                        NavigationLink {
                            DevicesList(session: session, peer: peer)
                        } label: {
                            Label("Devices and fingerprints", systemImage: "key")
                        }
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    if let group, !group.isPrivate {
                        Text("This group can't be encrypted: anyone may join, or members can't see each other's addresses. Your server and the group's can read its messages.")
                    } else if isEncrypted {
                        Text(group == nil
                            ? "Messages are end-to-end encrypted with OMEMO."
                            : "Messages are end-to-end encrypted with OMEMO for every member's devices. Tap a member to check their devices.")
                    } else {
                        Text("Messages are sent unencrypted. Your server and theirs can read them.")
                    }
                }

                Section {
                    if previewsOffInSettings {
                        Label("Link previews are off", systemImage: "link")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: Binding(get: { linkPreviews }, set: setLinkPreviews)) {
                            Text("Ask").tag(Bool?.none)
                            Text("Always").tag(Bool?.some(true))
                            Text("Never").tag(Bool?.some(false))
                        } label: {
                            Label("Link previews", systemImage: "link")
                        }
                    }
                } header: {
                    Text("Links")
                } footer: {
                    if previewsOffInSettings {
                        Text("Link previews are turned off in Settings.")
                    } else {
                        Text("Previews are loaded by your phone, so a linked site can see your IP address and that you received its link. Links you send are previewed unless this is Never.")
                    }
                }

                if let group, !group.hasLeft {
                    Section {
                        Button(role: .destructive) { confirmsLeave = true } label: {
                            BusyLabel(title: "Leave Group", systemImage: "rectangle.portrait.and.arrow.right", isBusy: leave.isBusy)
                                .labelStyle(.destructiveRow)
                        }
                        .disabled(leave.isBusy)
                    }
                }

                if group != nil, room?.canDestroy == true {
                    Section {
                        Button(role: .destructive) { confirmsDestroy = true } label: {
                            BusyLabel(title: "Delete Group", systemImage: "trash", isBusy: destroy.isBusy)
                                .labelStyle(.destructiveRow)
                        }
                        .disabled(destroy.isBusy)
                    }
                }

                if group == nil, peer != session.account, contact?.isBlocked != true {
                    Section {
                        if contact?.isInRoster == true {
                            Button(role: .destructive) { confirmsRemove = true } label: {
                                BusyLabel(title: "Remove from Contacts", systemImage: "person.badge.minus", isBusy: remove.isBusy)
                                    .labelStyle(.destructiveRow)
                            }
                            .disabled(remove.isBusy)
                        } else if contact?.hasContactRequest != true {
                            AddContactButton(session: session, peer: peer)
                                .labelStyle(.row)
                        }
                    }
                }

                if group == nil {
                    Section {
                        if contact?.isBlocked == true {
                            Button {
                                unblock.run { try await session.unblock(peer) }
                            } label: {
                                BusyLabel(title: "Unblock", systemImage: "hand.raised.slash", isBusy: unblock.isBusy)
                                    .labelStyle(.row)
                            }
                            .disabled(unblock.isBusy)
                        } else {
                            Button("Block", systemImage: "hand.raised", role: .destructive) { confirmsBlock = true }
                                .labelStyle(.destructiveRow)
                        }
                    } footer: {
                        if contact?.isBlocked == true {
                            Text("They can't message you or see when you're online.")
                        }
                    }
                }
            }
            .dismissesKeyboardOnTap()
            .opacity(isLoaded ? 1 : 0)
            .overlay {
                if !isLoaded { ProgressView() }
            }
            .navigationTitle(group == nil ? "Chat Settings" : "Group Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton()
                }
                if group != nil, room?.canEditAnything == true {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetEditButton { showsEdit = true }
                    }
                }
            }
            .blockConfirmation(isPresented: $confirmsBlock, session: session, peer: peer, name: contact?.displayName ?? peer.description)
            .confirmationDialog("Remove \(contact?.displayName ?? peer.description) from your contacts?", isPresented: $confirmsRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    remove.run { try await session.removeContact(peer) }
                }
            } message: {
                Text("You'll stop seeing when each other is online, on all your devices. The chat stays, and they can still message you.")
            }
            .actionAlert("Couldn't remove contact", remove)
            .actionAlert("Couldn't save the nickname", rename)
            .alert("Nickname", isPresented: $asksNickname) {
                TextField(contact?.nickname ?? peer.shortName, text: $nicknameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = nicknameDraft
                    rename.run { try await saveNickname(name) }
                }
            } message: {
                Text("Leave it empty to go back to the name they chose.")
            }
            .actionAlert("Couldn't unblock", unblock)
            .actionAlert("Couldn't leave group", leave)
            .actionAlert("Couldn't delete group", destroy)
            .actionAlert("Couldn't change notifications", changeNotify)
            .errorAlert("Couldn't save the setting", $saveError)
            .task { await loadInitial() }
            .onAppear { if group == nil { commandEntities = session.commandEntities(of: peer) } }
            .task {
                await session.database.forEachValue(of: session.database.observeLinkPreviewSetting(), "Link preview app setting") { setting in
                    previewsOffInSettings = setting == .never
                }
            }
            .task(id: isLoaded) {
                guard isLoaded, group == nil else { return }
                await session.database.forEachValue(of: session.database.observeContact(peer), "Contact") { contact in
                    self.contact = contact
                }
            }
            .task(id: group?.nickname) { await watchRoom() }
            .task(id: CommandProbeKey(nicks: probeNickList)) {
                await probeCommands()
            }
            .sheet(item: $commandsTarget) { target in
                NavigationStack {
                    CommandsListView(title: "Commands", session: session, entities: [(label: nil, jid: target.jid)])
                }
                .closableFromPushedScreens()
                .sheetSizedForMac()
            }
            .sheet(isPresented: $showsInvite) {
                InviteView(session: session, room: peer, members: room?.members ?? [])
            }
            .sheet(isPresented: $showsEdit) {
                if let group {
                    EditGroupView(session: session, room: peer, group: group, identity: identity)
                        .sheetSizedForMac()
                }
            }
            .confirmationDialog("Delete this group?", isPresented: $confirmsDestroy, titleVisibility: .visible) {
                Button("Delete Group", role: .destructive) {
                    let peer = peer
                    destroy.run { [session] in
                        try await session.destroyGroup(peer)
                        dismiss()
                    }
                }
            } message: {
                Text("This deletes the group for everyone, and its messages on the server. This can't be undone.")
            }
            .confirmationDialog("Leave this group?", isPresented: $confirmsLeave, titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) {
                    let peer = peer
                    leave.run { [session] in
                        try await session.leaveGroup(peer)
                        dismiss()
                    }
                }
            } message: {
                Text("You'll leave on all your devices. The messages stay on this device.")
            }
            .task(id: isLoaded) {
                guard isLoaded, group != nil else { return }
                await session.database.forEachValue(of: session.database.observeGroupChat(peer), "Group") { group in
                    self.group = group
                    let session = session, peer = peer
                    let encrypted = await offMain { try? session.database.isEncrypted(with: peer) }
                    if let encrypted { isEncrypted = encrypted }
                }
            }
        }
        .closableFromPushedScreens()
    }

    private func saveNickname(_ name: String) async throws {
        #if DEBUG
        // Fixtures never connect, so there is no server to push the roster
        // item back; this writes what the push would.
        if DevFixture.isActive {
            let session = session, peer = peer
            try await Task.detached {
                guard let contact = try session.database.contact(peer) else { return }
                try session.database.updateRosterItem(
                    jid: peer, name: XMPPSession.normalizedNickname(name), subscription: contact.subscription,
                    isPending: contact.isSubscriptionPending, groups: contact.rosterGroups,
                )
            }.value
            return
        }
        #endif
        try await session.setContactName(peer, name: name)
    }

    private func groupCommandEntities(presentNicks: [String]) -> [(label: String?, jid: String)] {
        var entities: [(label: String?, jid: String)] = []
        if room?.offersCommands == true {
            entities.append((label: String(localized: "Group"), jid: peer.description))
        }
        for nick in presentNicks {
            entities.append((label: nick, jid: "\(peer)/\(nick)"))
        }
        return entities
    }

    @ViewBuilder
    private func groupSections(_ group: GroupChat, probeNicks: [String]) -> some View {
        // A member who answered once may have left since.
        let presentNicks = probeNicks.filter(commandNicks.contains)
        Section {
            Picker(selection: Binding(get: { group.notify }, set: setNotify)) {
                Text("All Messages").tag(GroupChat.Notify.always)
                Text("Mentions").tag(GroupChat.Notify.onMention)
                Text("None").tag(GroupChat.Notify.never)
            } label: {
                BusyLabel(title: "Notifications", systemImage: "bell", isBusy: changeNotify.isBusy)
            }
            .disabled(changeNotify.isBusy)
            if group.notify == .always {
                Picker(selection: Binding(get: { notificationInterval }, set: setNotificationInterval)) {
                    Text("Off").tag(Int?.none)
                    Text("Every 5 Minutes").tag(Int?.some(5))
                    Text("Every 15 Minutes").tag(Int?.some(15))
                    Text("Every Hour").tag(Int?.some(60))
                    // A value another version of the app synced, which this one doesn't offer.
                    if let minutes = notificationInterval, ![5, 15, 60].contains(minutes) {
                        Text("Every \(Self.duration(minutes))").tag(Int?.some(minutes))
                    }
                } label: {
                    Label("Notify at Most", systemImage: "bell.badge")
                }
            }
            if room?.offersCommands == true || !presentNicks.isEmpty {
                NavigationLink {
                    // A bot can't offer commands at the room's own address, so
                    // the members' are gathered here beside the room's.
                    CommandsListView(title: "Commands", session: session, entities: groupCommandEntities(presentNicks: presentNicks))
                } label: {
                    Label("Commands", systemImage: "terminal")
                }
            }
        } footer: {
            switch group.notify {
            case .always:
                if let notificationInterval {
                    Text("After a notification, messages for the next \(Self.duration(notificationInterval)) arrive silently, unless they mention you, say “\(group.nickname)” or reply to yours. They still count in the app's badge.")
                }
            case .onMention: Text("Only messages that mention you, say “\(group.nickname)” or reply to yours notify you or count in the app's badge.")
            case .never: Text("Messages from this group don't notify you or count in the app's badge.")
            }
        }

        Section {
            if room?.isJoined == true, group.isMembersOnly || room?.canInvite == true {
                Button("Add Members", systemImage: "person.badge.plus") { showsInvite = true }
                    .labelStyle(.row)
            }
            if room?.canSeeBans == true {
                NavigationLink {
                    BannedMembersView(session: session, room: peer)
                } label: {
                    LabeledContent {
                        Text(room?.banned.count ?? 0, format: .number)
                    } label: {
                        Label("Banned", systemImage: "nosign")
                    }
                }
            }
            let isLastOwner = room?.isLastOwner(session.account) ?? false
            ForEach(memberRows, id: \.id) { row in
                let opensCommands = commandsAction(for: row)
                let linksDevices = row.jid != nil && group.isPrivate && !row.isMe
                Group {
                    if linksDevices, let jid = row.jid {
                        NavigationLink {
                            DevicesList(session: session, peer: jid)
                        } label: {
                            MemberRow(row: row, session: session, reservesButton: opensCommands != nil)
                        }
                    } else {
                        MemberRow(row: row, session: session, reservesButton: opensCommands != nil)
                    }
                }
                .overlay(alignment: .trailing) {
                    if let opensCommands {
                        Button(action: opensCommands) {
                            Image(systemName: "terminal").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Commands")
                        // Clear of the chevron a private group's row has.
                        .padding(.trailing, linksDevices ? 28 : 0)
                    }
                }
                .memberModeration(of: row, in: room, isLastOwner: isLastOwner, group: peer, session: session, onCommands: opensCommands)
            }
        } header: {
            Text("Members")
        } footer: {
            if room?.isJoined != true {
                Text("Members show up once you're in the group.")
            }
        }
    }

    private struct CommandsTarget: Identifiable {
        let jid: String
        var id: String { jid }
    }

    private struct CommandProbeKey: Hashable {
        var nicks: [String]
    }

    /// The nicks of present occupants other than us, once we're in the room,
    /// sorted so the probe restarts only when someone comes or goes.
    private func probeNicks(of room: RoomStatus?) -> [String] {
        guard let room, room.isJoined else { return [] }
        let own = group?.nickname
        return room.occupants.values.filter { $0.nick != own && $0.jid != session.account }.map(\.nick).sorted()
    }

    /// Follows the room through the model's observation, so a change to it is
    /// compared once, not whenever this view is drawn, and loads the members
    /// for it, one load at a time.
    private func watchRoom() async {
        let (changes, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Read and armed with nothing in between, so no change goes unseen.
        func arm() -> RoomStatus? {
            withObservationTracking { _ = model.live.room(peer).status } onChange: { signal.yield() }
            return room
        }
        var last = arm()
        probeNickList = probeNicks(of: last)
        await loadMembers()
        for await _ in changes {
            let now = arm()
            guard now != last else { continue }
            last = now
            let nicks = probeNicks(of: now)
            if nicks != probeNickList { probeNickList = nicks }
            await loadMembers()
        }
    }

    private func commandsAction(for row: MemberRow.Model) -> (() -> Void)? {
        guard row.isPresent, !row.isMe, let nick = row.nick, commandNicks.contains(nick) else { return nil }
        return { commandsTarget = CommandsTarget(jid: "\(peer)/\(nick)") }
    }

    /// Asks the occupants not yet asked, a batch at a time, off the main thread.
    private func probeCommands() async {
        while !Task.isCancelled, await probeBatch() {}
    }

    /// Returns whether it asked anyone, so there may be more to ask.
    private func probeBatch() async -> Bool {
        let batch = probeNickList.filter { !probedNicks.contains($0) }.prefix(30)
        guard !batch.isEmpty else { return false }
        let session = session, peer = peer
        let offering = await Task.detached(priority: .utility) {
            await withTaskGroup(of: (String, Bool).self) { tasks in
                for nick in batch {
                    tasks.addTask { (nick, await session.offersCommands(at: "\(peer)/\(nick)")) }
                }
                var offering: Set<String> = []
                for await (nick, offers) in tasks where offers { offering.insert(nick) }
                return offering
            }
        }.value
        // A cancelled pass's answers are failures, not nos, so it is run again.
        guard !Task.isCancelled else { return false }
        commandNicks.formUnion(offering)
        probedNicks.formUnion(batch)
        return true
    }

    /// The rows are worked out when the room changes rather than whenever the
    /// view is drawn, and with their contacts, which are read off the main thread.
    private func loadMembers() async {
        guard let room else {
            memberRows = []
            return
        }
        let session = session, nickname = group?.nickname
        memberRows = await offMain {
            Self.members(of: room, nickname: nickname, session: session)
        }
    }

    /// Present occupants first, then members who aren't here right now.
    private nonisolated static func members(of room: RoomStatus, nickname: String?, session: XMPPSession) -> [MemberRow.Model] {
        let present = room.occupants.values.map { occupant in
            MemberRow.Model(jid: occupant.jid, nick: occupant.nick, affiliation: occupant.affiliation, isPresent: true,
                            isMe: occupant.jid == session.account || occupant.nick == nickname)
        }
        let here = Set(present.compactMap(\.jid))
        let absent = room.members.subtracting(here).map { jid in
            MemberRow.Model(jid: jid, nick: nil, affiliation: room.affiliation(of: jid), isPresent: false, isMe: jid == session.account)
        }
        let jids = (present + absent).compactMap(\.jid)
        let contacts = (try? session.database.reader.read { db in try Contact.fetchAll(db, keys: jids) })
            .map { Dictionary($0.map { ($0.jid, $0) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        return (present + absent).map { member in
            var member = member
            member.contact = member.jid.flatMap { contacts[$0] }
            return member
        }.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            if a.isPresent != b.isPresent { return a.isPresent }
            return a.sortName.localizedCaseInsensitiveCompare(b.sortName) == .orderedAscending
        }
    }

    /// The toggle moves at once; the write follows off the main thread, and
    /// the toggle goes back if it fails.
    private func setEncrypted(_ encrypted: Bool) {
        let previous = isEncrypted
        isEncrypted = encrypted
        saves.run({ [session, peer] in try session.setEncrypted(encrypted, with: peer) }, onFailure: { error in
            isEncrypted = previous
            saveError = error.localizedDescription
        })
    }

    /// Changing it publishes the group's bookmark, a server action, so it
    /// shows a spinner while it's under way.
    private func setNotify(_ notify: GroupChat.Notify) {
        guard let previous = group?.notify, previous != notify else { return }
        group?.notify = notify
        changeNotify.run { [session, peer] in
            do {
                try await offMain { try session.setNotify(notify, in: peer) }
            } catch {
                group?.notify = previous
                throw error
            }
        }
    }

    private func setNotificationSound(_ sound: String?) {
        let previous = notificationSound
        notificationSound = sound
        saves.run({ [database = session.database, peer] in try database.setNotificationSound(sound, peer: peer) }, onFailure: { error in
            notificationSound = previous
            saveError = error.localizedDescription
        })
    }

    /// "15 minutes", "1 hour", in the user's language.
    private static func duration(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private func setNotificationInterval(_ minutes: Int?) {
        let previous = notificationInterval
        notificationInterval = minutes
        saves.run({ [database = session.database, peer] in try database.setNotificationInterval(minutes, peer: peer) }, onFailure: { error in
            notificationInterval = previous
            saveError = error.localizedDescription
        })
    }

    private func setLinkPreviews(_ allowed: Bool?) {
        let previous = linkPreviews
        linkPreviews = allowed
        saves.run({ [database = session.database, peer] in try database.setLinkPreviews(allowed, peer: peer) }, onFailure: { error in
            linkPreviews = previous
            saveError = error.localizedDescription
        })
    }
}

/// Writes for settings, off the main thread and in the order they were
/// made, so toggling twice quickly ends where the user left it.
@MainActor
private final class SettingsWrites {
    private var tail: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () throws -> Void, onFailure: @escaping @MainActor (Error) -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            do {
                try await offMain(work)
            } catch {
                onFailure(error)
            }
        }
    }
}

struct MemberRow: View {
    struct Model: Sendable {
        var jid: JID?
        var nick: String?
        var affiliation: RoomAffiliation
        var isPresent: Bool
        var isMe: Bool
        var contact: Contact?

        /// Present occupants are told apart by nickname, as one person can be
        /// in a room under two; absent members only have their address.
        var id: String { isPresent ? "nick:\(nick ?? "")" : "jid:\(jid?.description ?? "")" }
        var sortName: String { nick ?? jid?.localPart ?? "" }
        /// What the member is called, apart from "You".
        var displayName: String { contact?.displayName ?? nick ?? jid?.localPart ?? "?" }
    }

    let row: Model
    let session: XMPPSession
    /// Leaves room at the end for a button laid over the row.
    var reservesButton = false

    var body: some View {
        let contact = row.contact
        let name = row.isMe ? String(localized: "You") : row.displayName
        let detail = row.isMe ? row.nick : row.jid?.description ?? row.nick
        HStack(spacing: 12) {
            AvatarView(name: name, seed: row.jid?.description ?? row.nick ?? "", imageURL: session.avatars.url(for: contact))
                .frame(width: 36, height: 36)
                .opacity(row.isPresent ? 1 : 0.5)
            VStack(alignment: .leading) {
                Text(name)
                if let detail, detail != name {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch row.affiliation {
            case .owner: Text("Owner").font(.caption).foregroundStyle(.secondary)
            case .admin: Text("Admin").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
            if reservesButton { Color.clear.frame(width: 28, height: 1) }
        }
    }
}

/// An icon over a short label on a rounded tile, as in a profile's header.
private struct HeaderAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption)
            }
            .frame(width: 84, height: 56)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
