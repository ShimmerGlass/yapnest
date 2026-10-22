import SwiftUI
import YapnestKit

/// The conversation screen: the navigation bar, the messages, and the composer,
/// which is UIKit, as is each bubble's host on iOS and the emoji picker.
struct ConversationView: View {
    let session: XMPPSession
    let peer: JID
    /// A message to open the chat on, highlighted, as when it came from a search.
    var openingAt: Int64?
    /// What the caller already knows of the chat, so the header starts out
    /// right instead of showing the bare address until the database answers.
    var initial: ChatListItem?

    @Environment(AppModel.self) private var model
    /// SwiftUI makes this struct again whenever the parent updates, and
    /// keeps only the first holder. Everything costly is made through it,
    /// once, when the body first needs it.
    @State private var holder = ScreenHolder()
    @State private var listDropTargeted = false
    @State private var showsSettings = false
    /// Search was chosen in the settings; it opens once they're gone.
    @State private var searchAfterSettings = false
    @State private var composerHeight: CGFloat?
    /// What's laid over the top of the list: the Mac's strip, the search
    /// field and the banners.
    @State private var topBarsHeight: CGFloat = 0
    /// How tall the composer, or the bar in its place, is. The list runs on
    /// under it and keeps this much room past its newest message.
    @State private var bottomBarHeight: CGFloat = 0
    /// The screen's width, which the header's slot in the bar is sized from.
    @State private var width: CGFloat = 0
    /// The group has been joining for a while. A group is joined again on
    /// every connection, which usually takes a moment, so "Joining…" waits
    /// to show until it's taking longer than that.
    @State private var joinIsSlow = false

    @State private var confirmsBlock = false
    /// A contact request is being answered.
    @State private var answering = ServerAction()

    private var screen: ConversationScreen { holder.screen(session: session, peer: peer, openingAt: openingAt, initial: initial) }
    private var conversation: ConversationModel { screen.conversation }
    private var picker: AttachmentPicker { screen.picker }
    private var search: ChatSearch { screen.search }
    private var contact: Contact? { screen.contact }
    /// Set for group chats.
    private var group: GroupChat? { screen.group }

    /// Either of these covers the composer, and keeps files from being sent.
    private var hasLeftGroup: Bool { group?.hasLeft == true }
    private var hasBlockedContact: Bool { group == nil && contact?.isBlocked == true }

    private var title: String {
        group?.displayName ?? contact?.displayName ?? peer.shortName
    }

    private var isJoining: Bool {
        guard let group, !group.hasLeft else { return false }
        switch model.rooms[peer]?.phase {
        case .joining?, nil: return true
        case .joined?, .failed?: return false
        }
    }

    private var presence: ContactPresence? {
        model.presence(of: peer, contact: contact, isGroup: group != nil)
    }

    private var canCall: Bool {
        model.callablePeers.contains(peer) && group == nil && !hasBlockedContact
    }

    private var canVideoCall: Bool {
        canCall && model.videoCallablePeers.contains(peer)
    }

    private var identity: ChatIdentity {
        ChatIdentity(
            title: title,
            seed: peer.description,
            imageURL: session.avatars.url(for: contact),
            presence: presence,
            isGroup: group != nil,
            subtitle: subtitle,
        )
    }

    private var subtitle: Text? {
        if let group {
            if group.hasLeft { return Text("You left this group") }
            switch model.rooms[peer]?.phase {
            case .joined?: return Text("\(model.rooms[peer]?.memberCount ?? 0) members")
            case .failed(let reason)?: return Text(reason)
            case .joining?, nil: return joinIsSlow ? Text("Joining…") : nil
            }
        }
        if model.typing.contains(peer) { return Text("typing…") }
        guard let presence else { return nil }
        // Their server's word on when they left, which only shows while
        // the user shares their own.
        if presence == .offline, let seen = contact?.lastSeenAt {
            return Text("Last seen \(seen, format: .relative(presentation: .numeric))")
        }
        // One line, so a long status is cut off rather than pushing the
        // name around; the full text is in the chat's settings.
        if let status = model.statuses[peer] { return Text("\(presence.title) · \(status)") }
        return Text(presence.title)
    }

    var body: some View {
        messages
            // Not on the Mac, whose header isn't in the bar, so resizing the
            // window doesn't redraw the screen at every step.
            .onGeometryChange(for: CGFloat.self) { Platform.usesChatHeader ? 0 : $0.size.width } action: { width = $0 }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .windowTitle(title)
            // The Mac's header has the picture, the name and the call button.
            .toolbar(Platform.usesChatHeader ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if !Platform.usesChatHeader {
                    ToolbarItem(placement: .principal) {
                        header
                            .frame(width: headerWidth)
                    }
                }
                if canCall, !Platform.usesChatHeader {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Call", systemImage: "phone") { model.calls.startCall(to: peer) }
                            .disabled(model.calls.isInCall)
                    }
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if Platform.usesChatHeader { macHeader }
                    if search.isActive { ChatSearchBar(search: search) }
                    if screen.isLoaded, group == nil, let contact, contact.hasContactRequest {
                        requestBanner(contact)
                    } else if isStranger {
                        strangerBanner
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarsHeight = $0 }
                // The Mac's header takes the band at the top of the window.
                .ignoresSafeArea(.container, edges: Platform.usesChatHeader ? .top : [])
            }
            .onChange(of: model.chatSearchRequests) { search.open() }
            .blockConfirmation(isPresented: $confirmsBlock, session: session, peer: peer, name: title)
            .errorAlert("Couldn't answer", $answering.error)
            .sheet(isPresented: $showsSettings, onDismiss: {
                // The search field takes focus as it appears, which a sheet
                // that's still leaving would swallow.
                if searchAfterSettings {
                    searchAfterSettings = false
                    search.open()
                }
            }) {
                ChatSettingsView(session: session, peer: peer, identity: identity, canCall: canCall, canVideoCall: canVideoCall) { searchAfterSettings = true }
                    .sheetSizedForMac()
                    .countsAsConversationSheet()
            }
            // Asks their server when they were last online, as the chat opens
            // and when they go offline; the session limits how often.
            .task(id: presence) {
                guard presence == .offline else { return }
                await session.refreshLastSeen(of: peer)
            }
            .task(id: isJoining) {
                joinIsSlow = false
                guard isJoining else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    joinIsSlow = true
                } catch {}
            }
            .task {
                await session.database.forEachValue(of: session.database.observeGroupChat(peer), "Group") { group in
                    screen.group = group
                    screen.hasGroupValue = true
                }
            }
            .task {
                await session.database.forEachValue(of: session.database.observeContact(peer), "Contact") { contact in
                    screen.contact = contact
                    screen.hasContactValue = true
                }
            }
    }

    @ViewBuilder
    private func busyCard(_ shows: Bool, label: LocalizedStringKey) -> some View {
        if shows {
            ProgressView()
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(label)
        }
    }

    /// The messages run under the bars, which blur them, and the composer
    /// rides above the keyboard.
    private var messages: some View {
        layout
        // Measured from the window's top on the Mac, as the header is.
        .ignoresSafeArea(.container, edges: Platform.usesChatHeader ? .top : [])
        .overlay(alignment: .top) {
            if Platform.flipsMessageList, #available(iOS 26, *) { TopEdgeBlur() }
        }
        .overlay { busyCard(conversation.isSearching, label: "Looking for the message") }
        .overlay { busyCard(conversation.isRemovingForEveryone, label: "Removing the message") }
        .overlay {
            // The composer is UIKit and tells the model; the list is SwiftUI.
            if listDropTargeted || conversation.composerDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: hasLeftGroup || hasBlockedContact, initial: true) { _, blocked in
            conversation.canSendAttachments = !blocked
        }
        .background { EmojiPickerHost(model: conversation).frame(width: 1, height: 1) }
        .conversationPrompts(conversation)
        .sheet(isPresented: Binding(get: { conversation.devicesSheet != nil }, set: { if !$0 { conversation.devicesSheet = nil } })) {
            if let peer = conversation.devicesSheet {
                DevicesView(session: session, peer: peer)
                    .countsAsConversationSheet()
            }
        }
        .sheet(isPresented: Bindable(conversation).showsLocationPicker) {
            LocationPicker { conversation.stageLocation($0) }
                .sheetSizedForMac(width: 520, height: 560)
                .countsAsConversationSheet()
        }
        .sheet(isPresented: Bindable(conversation).showsGifPicker) {
            GifPicker(database: session.database) { conversation.addGif($0) }
                .sheetSizedForMac(width: 520, height: 640)
                .countsAsConversationSheet()
        }
        .task { conversation.start(previews: model.linkPreviews) }
        .onAppear {
            conversation.setOnScreen(true)
            conversation.linkHandler = { [weak model] in model?.open(link: $0) }
            model.liveConversations.register(conversation)
        }
        .onDisappear { conversation.setOnScreen(false) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in conversation.appBecameActive() }
        // On the Mac the window can lose focus while the app stays active.
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in conversation.sceneActivated() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in conversation.appWillResignActive() }
    }

    /// The list, reaching down under the composer so the messages show
    /// through its glass, and keeping the composer's height clear past its
    /// newest message. It's stretched in the stack rather than given the
    /// composer as a safe area inset or laid under it in a ZStack: either way
    /// it took in the keyboard's safe area, and its layout never settled.
    /// SwiftUI lifts both with the keyboard, and the flipped list on iOS keeps
    /// its newest message at the composer's edge through it.
    private var layout: some View {
        VStack(spacing: 0) {
            listArea
                .overlay(alignment: .bottomTrailing) { scrollToEnd.padding(.bottom, bottomBarHeight) }
                .padding(.bottom, -bottomBarHeight)
            bottomBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBarHeight = $0 }
        }
        // Behind the messages and the composer, down to the screen's edge,
        // so it rises from the bottom of the screen and shows through the
        // composer's glass.
        .background(alignment: .bottom) {
            ReceivedPulse(trigger: conversation.receivedPulse)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        // While a hover bar's menu is open the pointer is in the menu's own
        // window, so the first move here after it closes says it has. The
        // rows hear of it by notification: reading state from each row would
        // redraw them all.
        .onContinuousHover { phase in
            guard Platform.isMac, case .active = phase, conversation.hoverMenuOpen else { return }
            conversation.hoverMenuOpen = false
            NotificationCenter.default.post(name: .hoverMenuClosed, object: conversation)
        }
    }

    private var listArea: some View {
        ZStack {
            if conversation.hasLoaded {
                MessageList(model: conversation, topInset: topBarsHeight, bottomInset: bottomBarHeight)
                    .opacity(conversation.isPositioned ? 1 : 0)
                    .modifier(MacArrival(isReady: conversation.isPositioned))
            }
            // Takes all the room above the composer even while it's alone in
            // the stack; otherwise the stack is shorter than the screen and
            // centres the composer until the list appears.
            MessagesPlaceholder(model: conversation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, bottomBarHeight)
        }
        .onDrop(of: [.item], delegate: AttachmentDropDelegate(model: conversation, isTargeted: $listDropTargeted))
    }

    private var scrollToEnd: some View {
        // Centred over the microphone button at the end of the composer's row.
        ScrollToEndControl(model: conversation)
            .padding(.trailing, ConversationInputBar.Metrics.outerMargin + (ConversationInputBar.Metrics.controlSize - ScrollToEndControl.size) / 2)
            .padding(.bottom, 12)
    }

    /// In the stack in place of the composer, so the list ends above it. The
    /// model keeps the composer's text for when it returns.
    @ViewBuilder
    private var bottomBar: some View {
        if hasLeftGroup {
            ActionBar(message: "You're no longer in this group.", button: "Join Again", errorTitle: "Couldn't join") {
                try await session.joinGroup(peer)
            }
        } else if hasBlockedContact {
            ActionBar(message: "You blocked this contact.", button: "Unblock", errorTitle: "Couldn't unblock") {
                try await session.unblock(peer)
            }
        } else if group != nil, case .failed(let reason)? = model.rooms[peer]?.phase {
            // Not left, but out for now; some failures retry by themselves.
            ActionBar(message: LocalizedStringKey(reason), button: "Join Again", errorTitle: "Couldn't join") {
                try await session.joinGroup(peer)
            }
        } else {
            ComposerBar(model: conversation, picker: picker, height: $composerHeight)
        }
    }

    /// The picture, name and status, in the navigation bar on iOS and in our
    /// own header on the Mac.
    private var header: some View {
        Button { showsSettings = true } label: {
            ConversationTitle(identity: identity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat Settings")
        #if DEBUG
        .onChange(of: identity.title, initial: true) { _, title in
            conversation.recorder?.update { $0.titled(title) }
        }
        .recordingSqueezes(conversation, room: headerWidth)
        #endif
    }

    /// The header's slot in the bar is as wide as the bar allows whatever
    /// it shows, so it never has to grow. The bar sizes the slot for what
    /// it first shows and doesn't measure it again while a push runs, so a
    /// name or status that came in then was cut short ("N…") until the push
    /// ended. Room for a bar button on both sides keeps it centred.
    private var headerWidth: CGFloat? {
        width > 0 ? width - 2 * Self.barButtonRoom : nil
    }

    /// A bar button with the margins beside it. The call button takes 84 on
    /// iOS 26; with less, the bar moves the slot off centre to fit.
    private static let barButtonRoom: CGFloat = 88

    /// Click for the chat's settings, as with the header in Messages.
    private var macHeader: some View {
        Button { showsSettings = true } label: {
            ConversationTitle(identity: identity, isLarge: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel("Chat Settings")
        .help(identity.title)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            if canCall {
                Button("Call", systemImage: "phone") { model.calls.startCall(to: peer) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .disabled(model.calls.isInCall)
                    .pointingHandCursor()
                    .help("Call")
            }
        }
        .padding(.horizontal, 16)
        // Below the window buttons, in the title bar's band, which on the
        // compact style passes the pointer on from 17 points down.
        .padding(.top, 32)
        .padding(.bottom, 10)
        .background(.bar)
        // A Divider in an overlay draws vertically, through the middle.
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    /// Someone outside our contacts wrote to us.
    private var isStranger: Bool {
        screen.isLoaded && group == nil && peer != session.account && contact?.isInRoster != true && contact?.isBlocked != true
    }

    private var strangerBanner: some View {
        banner(Text("\(peer.description) isn't in your contacts.")) {
            AddContactButton(session: session, peer: peer)
                .buttonStyle(.bordered)
            Button("Block", systemImage: "hand.raised", role: .destructive) { confirmsBlock = true }
                .buttonStyle(.bordered)
        }
    }

    /// They asked to add us: what they'd see is our presence, so that's
    /// what accepting shares.
    private func requestBanner(_ contact: Contact) -> some View {
        banner(Text("\(contact.requestTitle) (\(peer.description)) wants to add you as a contact and see when you're online.")) {
            Button("Accept") { answer { try $0.acceptContactRequest(from: $1) } }
                .buttonStyle(.borderedProminent)
                .disabled(answering.isBusy)
            Button("Decline") { answer { try $0.declineContactRequest(from: $1) } }
                .buttonStyle(.bordered)
                .disabled(answering.isBusy)
            Button("Block", role: .destructive) { confirmsBlock = true }
                .buttonStyle(.bordered)
        }
    }

    /// A line of explanation over the actions it offers.
    private func banner<Buttons: View>(_ message: Text, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 10) {
            message
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                buttons()
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.bar)
    }

    /// Answering writes to the database, so it runs off the main thread; the
    /// buttons are off until it's done.
    private func answer(_ action: @escaping @Sendable (XMPPSession, JID) throws -> Void) {
        let session = session, peer = peer
        answering.run { try await offMain { try action(session, peer) } }
    }
}

/// What the screen is built on, made once per conversation.
@MainActor
@Observable
private final class ConversationScreen {
    let conversation: ConversationModel
    let picker: AttachmentPicker
    let search: ChatSearch
    /// Observed, and so nil until the first value arrives: the database isn't
    /// read on the main thread.
    var contact: Contact?
    var group: GroupChat?
    var hasContactValue = false
    var hasGroupValue = false
    /// Both have been observed once, so a nil is an answer rather than a wait
    /// (a banner offering to add the contact would flash otherwise).
    var isLoaded: Bool { hasContactValue && hasGroupValue }

    init(session: XMPPSession, peer: JID, openingAt: Int64?, initial: ChatListItem?) {
        if let initial {
            contact = initial.contact
            group = initial.groupChat
            hasContactValue = true
            hasGroupValue = true
        }
        conversation = ConversationModel(session: session, peer: peer, openingAt: openingAt)
        picker = AttachmentPicker(model: conversation)
        search = ChatSearch(session: session, peer: peer, conversation: conversation)
    }
}

/// Makes the screen's state on first use. Cheap to make, since SwiftUI
/// makes one for every update of the parent and drops all but the first.
@MainActor
private final class ScreenHolder {
    private var screen: ConversationScreen?

    func screen(session: XMPPSession, peer: JID, openingAt: Int64?, initial: ChatListItem?) -> ConversationScreen {
        if let screen { return screen }
        let made = ConversationScreen(session: session, peer: peer, openingAt: openingAt, initial: initial)
        screen = made
        return made
    }
}

/// Stands in for the composer with a message and the one action that lifts it.
private struct ActionBar: View {
    let message: LocalizedStringKey
    let button: LocalizedStringKey
    let errorTitle: LocalizedStringKey
    let action: @MainActor () async throws -> Void

    @State private var server = ServerAction()

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                server.run(action)
            } label: {
                if server.isBusy { ProgressView() } else { Text(button) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(server.isBusy)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .errorAlert(errorTitle, $server.error)
    }
}

/// What the chat's header shows, in the iPhone's navigation bar and at the top of the Mac window.
struct ChatIdentity {
    let title: String
    let seed: String
    let imageURL: URL?
    let presence: ContactPresence?
    let isGroup: Bool
    let subtitle: Text?

    func avatar(size: CGFloat) -> some View {
        AvatarView(name: title, seed: seed, imageURL: imageURL, presence: presence, isGroup: isGroup)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    func subtitleLine(_ font: Font) -> some View {
        if let subtitle {
            subtitle
                .font(font)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }
}

/// The chat's picture with its name and status line beneath.
private struct ConversationTitle: View {
    let identity: ChatIdentity
    /// The Mac's header has the room for a bigger picture and name.
    var isLarge = false

    var body: some View {
        HStack(spacing: 8) {
            // Keeps its size, so the bar's narrow slot can't squeeze the
            // picture over the name when the layout is mirrored.
            identity.avatar(size: isLarge ? 40 : 32)
                .fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                Text(identity.title).font(isLarge ? .title3.weight(.semibold) : .headline).lineLimit(1)
                identity.subtitleLine(.caption)
            }
        }
        .animation(.default, value: identity.subtitle == nil)
    }
}

/// The search field over the top of a chat, with the count and the buttons
/// that step through the matches, newest first.
private struct ChatSearchBar: View {
    @Bindable var search: ChatSearch
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search in Chat", text: $search.query)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { search.goOlder() }
                    .onKeyPress(.escape) {
                        search.close()
                        return .handled
                    }
                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(search.summary)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Up goes to the older match, down to the newer, like a list read from the top.
            Button("Older Match", systemImage: "chevron.up") { search.goOlder() }
                .disabled(!search.canGoOlder)
            Button("Newer Match", systemImage: "chevron.down") { search.goNewer() }
                .disabled(!search.canGoNewer)
            Button("Cancel") { search.close() }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .task { isFocused = true }
    }
}

/// On the Mac, where the chat opens beside the list rather than pushed in,
/// its messages rise into place once laid out, instead of popping up, while
/// the header and the composer stay where they were. Waiting for the layout
/// keeps the motion clear of the work of opening the chat.
private struct MacArrival: ViewModifier {
    let isReady: Bool
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if Platform.isMac {
            content
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived || reduceMotion ? 0 : 8)
                .onChange(of: isReady, initial: true) { _, ready in
                    guard ready, !arrived else { return }
                    withAnimation(.easeOut(duration: 0.2)) { arrived = true }
                }
        } else {
            content
        }
    }
}
