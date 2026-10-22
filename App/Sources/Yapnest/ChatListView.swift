import GRDB
import SwiftUI
import YapnestKit

/// The chats, and the open one: stacked on the iPhone, side by side where
/// there's room for both, like on the Mac.
struct ChatListView: View {
    let session: XMPPSession

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// Whether the connection has been down long enough to say so.
    @State private var showsConnectionProblem = false
    /// The iPhone's stack.
    @State private var path: [ChatRoute] = []
    /// Side by side: the open chat, and what's pushed in the sidebar.
    @State private var selection: JID?
    /// The message the open chat was opened on, from a search.
    @State private var selectedMessage: Int64?
    /// The list's row for a chat opened from it, which starts the header off.
    /// A reference, as the stack builds a pushed chat with the
    /// `navigationDestination` closure of an earlier body, which would
    /// otherwise still hold the items from before the tap.
    @State private var openedItems = OpenedItems()
    @State private var sidebarPath: [ChatRoute] = []
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var sheet: ChatListSheet?
    #if DEBUG
    @State private var devCommands: DevCommands?
    #endif
    @State private var me: Contact?
    /// What we show contacts, for the Mac's account footer.
    @State private var ownStatus: XMPPSession.OwnStatus?

    private var isSplit: Bool { sizeClass == .regular }

    /// `opening` is a chat a notification asked for before this view existed,
    /// as on a cold launch. The stack is created with it already pushed, so
    /// nothing has to wait for the destinations to register. The size class
    /// isn't known yet, so both layouts start on it.
    init(session: XMPPSession, opening peer: JID? = nil) {
        self.session = session
        _path = State(initialValue: peer.map { [.conversation($0)] } ?? [])
        _selection = State(initialValue: peer)
    }

    var body: some View {
        Group {
            if isSplit {
                NavigationSplitView(columnVisibility: Platform.isMac ? .constant(.all) : $columnVisibility) {
                    NavigationStack(path: $sidebarPath) {
                        chats
                            .navigationDestination(for: ChatRoute.self) { route in
                                if case .archive = route { archive }
                            }
                    }
                    // The Mac's compact title bar loses the sidebar button
                    // while the list is hidden, with no way to bring it back.
                    .toolbar(removing: Platform.isMac ? .sidebarToggle : nil)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
                } detail: {
                    NavigationStack {
                        if let selection {
                            ConversationView(session: session, peer: selection, openingAt: selectedMessage, initial: openedItems[selection])
                                .id(OpenChat(peer: selection, message: selectedMessage))
                        } else {
                            ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    chats
                        .navigationDestination(for: ChatRoute.self) { route in
                            switch route {
                            case .conversation(let peer, let message):
                                // Its controller and state are made for one peer; a
                                // notification can swap the peer under an open chat.
                                ConversationView(session: session, peer: peer, openingAt: message, initial: openedItems[peer])
                                    .id(OpenChat(peer: peer, message: message))
                            case .archive:
                                archive
                            }
                        }
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(session: session)
                    .sheetSizedForMac()
            case .compose:
                NewChatView(
                    session: session,
                    onStart: { peer in
                        self.sheet = nil
                        // Ask to see their presence and avatar. Offline, the
                        // chat's banner offers this once connected.
                        Task { [session] in await offMain { session.befriendForNewChat(peer) } }
                        show(peer)
                    },
                    onNewGroup: { self.sheet = .newGroup },
                    onJoinGroup: { self.sheet = .joinGroup },
                )
                .sheetSizedForMac(width: 440, height: 520)
            case .newGroup:
                NewGroupView(session: session) { room in
                    self.sheet = nil
                    show(room)
                }
                .sheetSizedForMac(width: 440, height: 520)
            case .link(let link):
                LinkConfirmation(session: session, link: link) { peer, body in
                    self.sheet = nil
                    if let peer { openChat(peer, prefilling: body) }
                }
                .sheetSizedForMac(width: 440, height: 520)
            case .joinGroup:
                JoinGroupView(session: session) { room in
                    self.sheet = nil
                    show(room)
                }
                .sheetSizedForMac(width: 440, height: 520)
            }
        }
        // From a tapped notification.
        .onChange(of: model.requestedConversation, initial: true) { _, peer in
            guard let peer else { return }
            model.requestedConversation = nil
            // The stack and its destinations exist by now: this view is only
            // made once a session is, and a cold launch seeded its state in
            // `init`. Opening the chat in the same update as closing the
            // sheet is fine for the stack.
            sheet = nil
            show(peer)
        }
        // From an `xmpp:` link, which may have arrived before sign-in.
        .onChange(of: model.pendingLink, initial: true) { _, link in
            guard let link else { return }
            model.pendingLink = nil
            Task { await handle(link) }
        }
        // From the menu bar's Settings and New Chat.
        .onChange(of: model.requestedSheet) { _, requested in
            guard let requested else { return }
            model.requestedSheet = nil
            sheet = requested
        }
        #if DEBUG
        .task {
            if let open = ProcessInfo.processInfo.environment["YAPNEST_DEV_OPEN"].flatMap(JID.init(_:)) { show(open) }
            if ProcessInfo.processInfo.environment["YAPNEST_DEV_SETTINGS"] != nil { sheet = .settings }
            // `YAPNEST_DEV_COMMANDS=<jid>` lists that entity's commands, and
            // `YAPNEST_DEV_COMMAND="<jid> <node>"` runs one, for screenshots.
            let env = ProcessInfo.processInfo.environment
            // `long` is a canned command that needs no connection.
            if env["YAPNEST_DEV_COMMAND"] == "long" {
                devCommands = .canned(LongCommandFixture.run())
                return
            }
            if env["YAPNEST_DEV_COMMANDS"] != nil || env["YAPNEST_DEV_COMMAND"] != nil {
                // The connection is still coming up when the list first appears.
                try? await Task.sleep(for: .seconds(4))
            }
            if let jid = env["YAPNEST_DEV_COMMANDS"] {
                devCommands = .list(jid)
            } else if let spec = env["YAPNEST_DEV_COMMAND"]?.split(separator: " ", maxSplits: 1), spec.count == 2 {
                devCommands = .run(AdHocCommand(jid: String(spec[0]), node: String(spec[1]), name: String(spec[1])))
            }
        }
        .sheet(item: $devCommands) { dev in
            NavigationStack {
                switch dev {
                case .list(let jid): CommandsListView(title: "Commands", session: session, entities: [(label: nil, jid: jid)])
                case .run(let command): CommandRunView(command: command, session: session)
                case .canned(let run): CommandRunView(run: run)
                }
            }
        }
        #endif
        .task(id: session.account) {
            await session.database.forEachValue(of: session.database.observeContact(session.account), "Own contact") { contact in
                me = contact
            }
        }
        .task(id: session.account) {
            guard Platform.isMac else { return }
            await session.database.forEachValue(of: session.observeOwnStatus(), "Own status") { status in
                ownStatus = status
            }
        }
    }

    /// What contacts see of us: nothing while we're not connected.
    private var ownPresence: (presence: ContactPresence?, status: String?) {
        switch model.connection {
        case .connected:
            guard let ownStatus else { return (nil, nil) }
            let label = switch ownStatus.availability {
            case .available: String(localized: "Available")
            case .away: String(localized: "Away")
            case .dnd: String(localized: "Do Not Disturb")
            }
            let presence: ContactPresence = switch ownStatus.availability {
            case .available: .online
            case .away: .away
            case .dnd: .busy
            }
            return (presence, ownStatus.message.isEmpty ? label : ownStatus.message)
        case .connecting: return (.offline, String(localized: "Connecting…"))
        case .disconnected, .failed: return (.offline, String(localized: "Offline"))
        }
    }

    private var chats: some View {
        ChatListContent(session: session, archived: false, selection: isSplit ? selection : nil, open: { open($0, item: $1) }, onDelete: closeIfOpen, onCompose: { sheet = .compose })
            .safeAreaInset(edge: .top, spacing: 0) {
                ConnectionBanner(state: showsConnectionProblem ? model.connection : nil)
            }
            .animation(.default, value: showsConnectionProblem ? model.connection : nil)
            // The app drops its connection a few seconds after leaving, and
            // every return reconnects in a moment. A banner for that would push
            // the list down and back each time, so only a connection that stays
            // down while the app is in use is worth reporting.
            // Restarts that change nothing (the list reappearing, Control
            // Center) leave a showing banner alone.
            .task(id: ConnectionWatch(isDown: model.connection.isDown, isActive: scenePhase != .background)) {
                switch ConnectionBannerRule.action(isDown: model.connection.isDown, isInBackground: scenePhase == .background, isShowing: showsConnectionProblem) {
                case .hide:
                    showsConnectionProblem = false
                    return
                case .keepShowing:
                    return
                case .showAfterDelay:
                    break
                }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                showsConnectionProblem = true
            }
            .accountFooter(
                name: me?.displayName ?? session.account.shortName,
                seed: session.account.description,
                imageURL: session.avatars.url(for: me),
                presence: ownPresence.presence,
                status: ownPresence.status,
            ) { sheet = .settings }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Catching up is brief and routine, so it goes in the title
                // instead of a bar that would push the list down.
                if model.connection == .connected(isSyncing: true) {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Chats").font(.headline)
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Updating…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                // The Mac's footer replaces it.
                if !Platform.isMac {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            sheet = .settings
                        } label: {
                            AvatarView(
                                name: session.account.shortName,
                                seed: session.account.description,
                                imageURL: session.avatars.url(for: me),
                            )
                            .frame(width: 30, height: 30)
                        }
                        .accessibilityLabel("Settings")
                    }
                    // On the Mac it sits beside the search field in the list.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Chat", systemImage: "square.and.pencil") { sheet = .compose }
                    }
                }
            }
    }

    private var archive: some View {
        ChatListContent(session: session, archived: true, selection: isSplit ? selection : nil, open: { open($0, item: $1) }, onDelete: closeIfOpen)
            .navigationTitle("Archived Chats")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// A row's tap.
    private func open(_ route: ChatRoute, item: ChatListItem? = nil) {
        if case .conversation(let peer, _) = route { openedItems[peer] = item }
        switch (route, isSplit) {
        case (.conversation(let peer, let message), true):
            selection = peer
            selectedMessage = message
        case (.archive, true): sidebarPath.append(.archive)
        case (_, false): path.append(route)
        }
    }

    /// Opens what a link asks for, or asks the user first when it would send
    /// something: adding someone we don't know, or joining a group.
    private func handle(_ link: XMPPURI) async {
        guard link.jid != session.account else {
            model.linkProblem = String(localized: "That's your own address.")
            return
        }
        let (isKnown, hasJoined) = await offMain { [database = session.database] in
            let contact = try? database.contact(link.jid)
            let group = (try? database.groupChat(link.jid)) ?? nil
            return (contact?.isInRoster == true || contact?.hasContactRequest == true || group != nil, group?.hasLeft == false)
        }
        switch link.action {
        case .join:
            if hasJoined { openChat(link.jid) } else { sheet = .link(link) }
        case .addContact:
            if isKnown { openChat(link.jid) } else { sheet = .link(link) }
        case .chat(let body):
            if isKnown { openChat(link.jid, prefilling: body) } else { sheet = .link(link) }
        }
    }

    /// Opens the chat with `body` in the composer, to be sent by the user
    /// or not. Text already there stays, with the body below it.
    private func openChat(_ peer: JID, prefilling body: String? = nil) {
        guard let body else {
            sheet = nil
            show(peer)
            return
        }
        // A live chat, shown or under another in the stack, reads its draft
        // once, when it starts, and would write its own composer over one
        // stored now.
        if let live = model.liveConversations.model(for: peer) {
            live.prefill(body)
            sheet = nil
            show(peer)
            return
        }
        Task { [database = session.database] in
            await offMain {
                let existing = DraftWriter.shared.current(for: peer, in: database)
                let text = ConversationModel.composerText(adding: body, to: existing ?? "")
                DraftWriter.shared.save(text, for: peer, to: database)
            }
            sheet = nil
            show(peer)
        }
    }

    private func closeIfOpen(_ peer: JID) {
        if selection == peer { selection = nil; selectedMessage = nil }
    }

    /// Opens `peer`'s chat on its own, from outside the list.
    private func show(_ peer: JID) {
        openedItems[peer] = nil
        if isSplit {
            selection = peer
            selectedMessage = nil
        } else {
            // The same chat stays as it is: its view is made for one peer.
            if path != [.conversation(peer)] { path = [.conversation(peer)] }
        }
    }
}

enum ChatRoute: Hashable {
    /// `at` is a message to open on, such as a search result.
    case conversation(JID, at: Int64? = nil)
    case archive
}

/// What a chat view is made for: another message to open on is a new screen.
private struct OpenChat: Hashable {
    let peer: JID
    let message: Int64?
}

/// The list of conversations, or of archived ones, with Signal's swipe actions.
private struct ChatListContent: View {
    let session: XMPPSession
    let archived: Bool
    /// The chat open beside the list, if any.
    let selection: JID?
    let open: (ChatRoute, ChatListItem?) -> Void
    var onDelete: (JID) -> Void = { _ in }
    /// Shown beside the search field on the Mac, where the window toolbar
    /// has no room for it.
    var onCompose: (() -> Void)?

    @Environment(AppModel.self) private var model
    // nil until the first read: the empty state and the sections that appear
    // later would otherwise flash and push the list.
    @State private var items: [ChatListItem]?
    @State private var archivedCount = 0
    @State private var search = ""
    @State private var pendingDelete: ChatListItem?
    @State private var leaving = ServerAction()
    @State private var requests: [Contact]?
    @State private var invitations: [GroupInvitation]?
    @State private var messageResults: [MessageSearchResult] = []
    @State private var isSearchingMessages = false
    @State private var selectionTrack = SelectionTrack()

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// Messages of the chats listed here; the other list has the rest.
    private var shownMessageResults: [(result: MessageSearchResult, item: ChatListItem)] {
        guard !messageResults.isEmpty else { return [] }
        let byId = Dictionary((items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return messageResults.compactMap { result in byId[result.conversationId].map { (result, $0) } }
    }

    private var visibleItems: [ChatListItem] {
        guard !query.isEmpty else { return items ?? [] }
        return (items ?? []).filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.conversation.peer.description.localizedCaseInsensitiveContains(query)
                || (item.lastMessage?.body.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        let visible = visibleItems
        let shown = shownMessageResults
        List {
            if !archived, search.isEmpty, let requests, !requests.isEmpty {
                Section {
                    ForEach(requests, id: \.jid) { contact in
                        ContactRequestRow(session: session, contact: contact) {
                            open(.conversation(contact.jid), nil)
                        }
                        .listRowInsets(ChatRowButtonStyle.rowInsets)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Contact Requests")
                }
            }

            if !archived, search.isEmpty, let invitations, !invitations.isEmpty {
                Section {
                    ForEach(invitations, id: \.room) { invitation in
                        GroupInvitationRow(session: session, invitation: invitation)
                            .listRowInsets(ChatRowButtonStyle.rowInsets)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Group Invitations")
                }
            }

            ForEach(visible) { item in
                Button {
                    open(.conversation(item.conversation.peer), item)
                } label: {
                    ChatListRow(
                        item: item,
                        isTyping: item.groupChat == nil && model.typing.contains(item.conversation.peer),
                        avatarURL: session.avatars.url(for: item.contact),
                        presence: model.presence(of: item.conversation.peer, contact: item.contact, isGroup: item.groupChat != nil),
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChatRowButtonStyle(isSelected: item.conversation.peer == selection, selectionTrack: selectionTrack))
                .listRowInsets(ChatRowButtonStyle.rowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .leading) {
                    readButton(item).tint(.blue)
                    if !archived { pinButton(item).tint(.orange) }
                }
                .swipeActions(edge: .trailing) {
                    deleteButton(item)
                    archiveButton(item).tint(.gray)
                }
                // The same, for a right click or a long press.
                .contextMenu {
                    readButton(item)
                    if !archived { pinButton(item) }
                    archiveButton(item)
                    deleteButton(item)
                }
            }

            if !query.isEmpty, isSearchingMessages || !shown.isEmpty {
                Section {
                    ForEach(shown, id: \.result.id) { found in
                        Button {
                            open(.conversation(found.item.conversation.peer, at: found.result.messageId), found.item)
                        } label: {
                            MessageSearchRow(
                                result: found.result,
                                item: found.item,
                                avatarURL: session.avatars.url(for: found.item.contact),
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ChatRowButtonStyle())
                        .listRowInsets(ChatRowButtonStyle.rowInsets)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        Text("Messages")
                        if isSearchingMessages { ProgressView().controlSize(.small) }
                    }
                }
            }

            if !archived, archivedCount > 0, search.isEmpty {
                Button {
                    open(.archive, nil)
                } label: {
                    Text("Archived Chats (\(archivedCount))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The Mac's search bar sits right on the list, which left a selected
        // first row's highlight touching it. As far below the bar as the
        // highlight is from the list's sides; it still scrolls under it.
        .modifier(MacTopMargin(ChatRowButtonStyle.rowInsets.leading - ChatRowButtonStyle.overhang))
        .background { ChatListBackdrop() }
        .sidebarSearch(text: $search, onCompose: onCompose)
        .overlay {
            switch ChatListEmptyState.choose(
                itemCount: items?.count,
                visibleItemCount: visible.count,
                hasMessageResults: !shown.isEmpty,
                isSearchingMessages: isSearchingMessages,
                requestCount: requests?.count,
                invitationCount: invitations?.count,
                search: search,
                archived: archived,
            ) {
            case .noArchivedChats:
                ContentUnavailableView("No Archived Chats", systemImage: "archivebox")
            case .noChats:
                ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right", description: Text("Start one with the compose button."))
            case .noResults:
                ContentUnavailableView.search(text: search)
            case nil:
                EmptyView()
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(isPresent: $pendingDelete),
            titleVisibility: .visible,
            presenting: pendingDelete,
        ) { item in
            Button(item.groupChat?.hasLeft == false ? "Leave and Delete" : "Delete", role: .destructive) {
                if let group = item.groupChat, !group.hasLeft {
                    // The chat stays until the server has taken us out of the
                    // group; otherwise the next connection would join it again.
                    leaving.run {
                        try await session.leaveGroup(group.jid)
                        delete(item)
                    }
                } else {
                    delete(item)
                }
            }
        } message: { item in
            if let group = item.groupChat, !group.hasLeft {
                Text("You'll leave the group on all your devices. Messages are deleted from this device only.")
            } else {
                Text("Messages are deleted from this device only.")
            }
        }
        .errorAlert("Couldn't leave group", $leaving.error)
        .overlay {
            if leaving.isBusy {
                ProgressView()
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear.contentShape(Rectangle()))
            }
        }
        // A new query replaces the task, which drops the last one's answer.
        .task(id: query) {
            await searchMessages(for: query)
        }
        .task(id: archived) {
            await session.database.forEachValue(of: session.database.observeChatList(archived: archived), "Chat list") { list in
                items = list
            }
        }
        .task(id: archived) {
            guard !archived else { return }
            await session.database.forEachValue(of: session.database.observeContactRequests(), "Contact request") { list in
                // The first value is what the list opens with.
                if requests == nil { requests = list } else { withAnimation { requests = list } }
            }
        }
        .task(id: archived) {
            guard !archived else { return }
            await session.database.forEachValue(of: session.database.observeGroupInvitations(), "Group invitation") { list in
                if invitations == nil { invitations = list } else { withAnimation { invitations = list } }
            }
        }
        .task(id: archived) {
            guard !archived else { return }
            await session.database.forEachValue(of: session.database.observeArchivedCount(), "Archive count") { count in
                archivedCount = count
            }
        }
    }

    private func readButton(_ item: ChatListItem) -> some View {
        Button {
            perform { [session] in
                try item.unreadCount > 0 ? session.markRead(item.conversation) : session.database.markUnread(conversationId: item.id)
            }
        } label: {
            item.unreadCount > 0
                ? Label("Read", systemImage: "message")
                : Label("Unread", systemImage: "message.badge")
        }
    }

    private func pinButton(_ item: ChatListItem) -> some View {
        Button {
            perform { [session] in try session.database.setPinned(!item.conversation.isPinned, conversationId: item.id) }
        } label: {
            item.conversation.isPinned
                ? Label("Unpin", systemImage: "pin.slash")
                : Label("Pin", systemImage: "pin")
        }
    }

    private func archiveButton(_ item: ChatListItem) -> some View {
        Button {
            perform { [session, archived] in try session.database.setArchived(!archived, conversationId: item.id) }
        } label: {
            archived
                ? Label("Unarchive", systemImage: "tray.and.arrow.up")
                : Label("Archive", systemImage: "archivebox")
        }
    }

    private func deleteButton(_ item: ChatListItem) -> some View {
        Button(role: .destructive) {
            pendingDelete = item
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Looks for `query` in the stored messages once typing pauses. Returns
    /// without an answer if the query changed meanwhile.
    private func searchMessages(for query: String) async {
        guard !query.isEmpty else {
            messageResults = []
            isSearchingMessages = false
            return
        }
        isSearchingMessages = true
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let database = session.database
        let found = await offMain {
            (try? database.searchMessages(query, limit: 50)) ?? []
        }
        guard !Task.isCancelled else { return }
        messageResults = found
        isSearchingMessages = false
    }

    private func delete(_ item: ChatListItem) {
        // Removing the attachment files is disk work.
        perform { [session] in try session.deleteConversation(id: item.id) }
        onDelete(item.conversation.peer)
    }

    /// Quick local writes, still not for the main thread: the list updates
    /// when the observation sees them.
    private func perform(_ action: @escaping @Sendable () throws -> Void) {
        Task {
            do { try await offMain(action) } catch { DiagLog.error(.app, "Chat action failed", .error(error)) }
        }
    }
}

/// A soft mauve wash behind the chats: strongest under the title, gone by
/// the middle of the screen, with a faint rose glow in the bottom corner so
/// the end of the list isn't flat.
private struct ChatListBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let mauve = isDark ? Color(red: 0.56, green: 0.38, blue: 0.64) : Color(red: 0.76, green: 0.58, blue: 0.84)
        let rose = isDark ? Color(red: 0.62, green: 0.36, blue: 0.52) : Color(red: 0.90, green: 0.64, blue: 0.78)
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(
                stops: [
                    .init(color: mauve.opacity(isDark ? 0.34 : 0.30), location: 0),
                    .init(color: mauve.opacity(isDark ? 0.12 : 0.10), location: 0.3),
                    .init(color: mauve.opacity(0), location: 0.6),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
            RadialGradient(colors: [rose.opacity(isDark ? 0.20 : 0.16), rose.opacity(0)], center: .bottomTrailing, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

/// Highlights the row while pressed, like a table cell, without a chevron,
/// and while its chat is open beside the list.
private struct ChatRowButtonStyle: ButtonStyle {
    static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    /// How far the highlight reaches past the row on either side.
    static let overhang: CGFloat = 8

    var isSelected = false
    var selectionTrack: SelectionTrack?

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .background {
                ZStack {
                    if let selectionTrack {
                        SelectionHighlight(isSelected: isSelected, track: selectionTrack)
                    }
                    PressGlow()
                        .opacity(configuration.isPressed ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                }
            }
    }

    static func highlight(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(color).padding(.horizontal, -overhang)
    }
}

/// The pressed row: the accent colour brightest at the middle and fading
/// out to the edges, with a soft halo past them.
private struct PressGlow: View {
    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 10)
            shape
                .fill(RadialGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.08)],
                    center: .center,
                    startRadius: 0,
                    endRadius: proxy.size.width / 2,
                ))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10)
        }
        .padding(.horizontal, -ChatRowButtonStyle.overhang)
    }
}

/// Where the open chat's row is on screen, for the next row selected to
/// slide its highlight in from. Not observed: it changes as the list
/// scrolls, and nothing redraws for it.
@MainActor
private final class SelectionTrack {
    var frame: CGRect?
}

/// A row's highlight while its chat is open. A newly selected row draws it
/// where the last one was and slides it into place, so the selection reads
/// as one highlight moving. Each row animates its own: the list doesn't
/// carry an animation into the row that gains the selection, so a shared
/// one moved out of the old row but popped up in the new one.
private struct SelectionHighlight: View {
    let isSelected: Bool
    let track: SelectionTrack
    /// Kept out of the view's state: it changes on every frame of a scroll.
    @State private var ownFrame = FrameBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private final class FrameBox { var frame: CGRect? }

    var body: some View {
        // Always there and only shown when selected: the slide has to start
        // in the update that selects the row, and a highlight inserted then
        // would have drawn a frame at its destination first. A keyframe
        // animation runs on its own clock, where an animated state change
        // in a list row didn't move at all.
        ChatRowButtonStyle.highlight(Color.accentColor.opacity(0.18))
            .opacity(isSelected ? 1 : 0)
            .keyframeAnimator(initialValue: 0, trigger: isSelected) { content, offset in
                content.offset(y: offset)
            } keyframes: { _ in
                let start = startOffset()
                KeyframeTrack {
                    MoveKeyframe(start)
                    SpringKeyframe(0, duration: 0.25, spring: .snappy(duration: 0.25))
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                ownFrame.frame = frame
                if isSelected { track.frame = frame }
            }
            .onChange(of: isSelected) { _, selected in
                if selected { track.frame = ownFrame.frame }
            }
    }

    /// From where the last selected row was, read before this row takes its place.
    private func startOffset() -> CGFloat {
        guard isSelected, !reduceMotion, let from = track.frame, let to = ownFrame.frame else { return 0 }
        return from.minY - to.minY
    }
}

/// Left alone on iOS, where an explicit margin would replace the list's own.
private struct MacTopMargin: ViewModifier {
    let margin: CGFloat
    init(_ margin: CGFloat) { self.margin = margin }

    func body(content: Content) -> some View {
        if Platform.isMac { content.contentMargins(.top, margin, for: .scrollContent) } else { content }
    }
}

/// What decides whether the banner is due: it restarts its delay when either changes.
private struct ConnectionWatch: Equatable {
    let isDown: Bool
    let isActive: Bool
}

private extension XMPPSession.State {
    var isDown: Bool {
        if case .connected = self { false } else { true }
    }
}

/// Shown above the list while the connection is down, once it's been down a
/// while. Catching up is in the title instead.
private struct ConnectionBanner: View {
    let state: XMPPSession.State?

    var body: some View {
        if let (text, icon, color) = content {
            Label(text, systemImage: icon)
                .font(.footnote)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var content: (String, String, Color)? {
        #if DEBUG
        // The screenshots fixture never connects, and shouldn't say so.
        if DevFixture.requested == .screenshots { return nil }
        #endif
        return switch state {
        case nil, .connected?: nil
        case .connecting?: ("Connecting…", "antenna.radiowaves.left.and.right", .secondary)
        case .disconnected(let error)?: (error.map { "Offline: \($0)" } ?? "Offline", "wifi.slash", .secondary)
        case .failed(let reason)?: (reason, "exclamationmark.triangle", .red)
        }
    }
}

/// One conversation, laid out like Signal's chat list cell.
private struct ChatListRow: View {
    let item: ChatListItem
    let isTyping: Bool
    let avatarURL: URL?
    let presence: ContactPresence?

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: item.title, seed: item.conversation.peer.description, imageURL: avatarURL, presence: presence, isGroup: item.groupChat != nil)
                .frame(width: 56, height: 56)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if item.conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 6)
                    if let date = item.lastMessage?.timestamp {
                        TimelineView(.everyMinute) { context in
                            Text(date.chatListFormatted(now: context.date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if isTyping {
                            TypingDots()
                        } else {
                            snippet
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let status = outgoingStatus {
                        if let image = status.indicator {
                            Image(uiImage: image)
                                .renderingMode(.template)
                                .foregroundStyle(status == .failed ? Color.red : .secondary)
                        }
                    }
                    if item.notifyingUnreadCount > 0 {
                        Text(item.notifyingUnreadCount, format: .number)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(Color.accentColor))
                    } else if item.unreadCount > 0 {
                        // Unread, but nothing that notifies: a dot, not a count.
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .frame(minHeight: 20)
                            .accessibilityLabel("Unread")
                    }
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
    }

    /// Our last message's delivery state, shown instead of a "You:" prefix.
    private var outgoingStatus: Message.Status? {
        guard !isTyping, item.conversation.draft?.isEmpty ?? true,
              let message = item.lastMessage, message.direction == .outgoing, message.call == nil else { return nil }
        return message.status
    }

    private var snippet: Text {
        if let draft = item.conversation.draft, !draft.isEmpty {
            return Text("Draft: ").italic() + Text(draft)
        }
        guard let message = item.lastMessage else { return Text(" ") }
        // "/me waves" reads as "Alice waves", with no "Alice:" before it.
        if let action = message.meAction {
            let name = message.direction == .outgoing ? String(localized: "You")
                : item.groupChat != nil ? message.nick ?? item.title
                : item.contact?.displayName ?? item.conversation.peer.shortName
            return Text("\(name) \(action.replacingOccurrences(of: "\n", with: " "))").italic()
        }
        // Groups name who wrote it, as Signal does.
        let author = item.groupChat != nil && message.direction == .incoming ? message.nick.map { Text("\($0): ").fontWeight(.medium) } : nil
        let content: Text
        if message.isRetracted {
            content = message.isModerated ? Text("Removed by a moderator").italic() : Text("Message deleted").italic()
        } else if message.encryption == .omemoUndecryptable {
            content = Text("Encrypted message").italic()
        } else if let call = message.call {
            content = Text(call.snippet)
        } else if let attachment = item.lastAttachment {
            content = Text(attachment.summary)
        } else if GeoLocation(body: message.body) != nil {
            content = Text(GeoLocation.summary)
        } else {
            content = Text(message.body.trimmingBlankEdgeLines.replacingOccurrences(of: "\n", with: " "))
        }
        return author.map { $0 + content } ?? content
    }
}

/// Signal's chat list typing indicator: three pulsing dots.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(phase - Double(index) * 0.8)))
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel("typing")
    }
}

extension Date {
    /// Signal's chat list format: "Now", minutes, time today, weekday this
    /// week, then month and day, then the full short date.
    func chatListFormatted(now: Date = .now) -> String {
        let calendar = Calendar.current
        let elapsed = now.timeIntervalSince(self)
        if elapsed < 60 { return String(localized: "Now") }
        if elapsed < 3600 { return String(localized: "\(Int(elapsed / 60))m") }
        if calendar.isDate(self, inSameDayAs: now) { return formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: now)).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(self, equalTo: now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(date: .numeric, time: .omitted)
    }
}

/// What the chat list can present over itself, one at a time.
enum ChatListSheet: Identifiable, Hashable {
    case settings, compose, newGroup, joinGroup
    /// An `xmpp:` link that needs the user's say before anything is sent.
    case link(XMPPURI)

    var id: Self { self }
}

#if DEBUG
/// What `YAPNEST_DEV_COMMANDS` and `YAPNEST_DEV_COMMAND` open.
enum DevCommands: Identifiable {
    case list(String)
    case run(AdHocCommand)
    case canned(AdHocRun)

    var id: String {
        switch self {
        case .list(let jid): "list \(jid)"
        case .run(let command): command.id
        case .canned: "canned"
        }
    }
}
#endif

/// The list's rows for the chats opened from it, by peer.
@MainActor
private final class OpenedItems {
    private var items: [JID: ChatListItem] = [:]

    subscript(peer: JID) -> ChatListItem? {
        get { items[peer] }
        set { items[peer] = newValue }
    }
}
