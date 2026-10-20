import Combine
import GRDB
import SwiftUI
import UIKit
import YapnestKit

/// How far back the list has got, shown above the oldest message.
enum OlderMessages: Equatable {
    case idle
    /// Waiting on the server's archive.
    case loading
    case failed
    /// Nothing older exists.
    case complete
}

extension Notification.Name {
    /// Posted with the model as its object when the pointer moves in the
    /// conversation after a hover bar's menu was open.
    static let hoverMenuClosed = Notification.Name("YapnestHoverMenuClosed")
}

/// A request for the emoji picker to react to a message with.
struct EmojiPickerRequest: Equatable {
    var id: Int64
    /// Where in the window the Mac's character viewer should open: by the
    /// button that asked for it. Nil from the menu, which has no button to point at.
    var anchor: CGRect?
}

/// One conversation's messages and everything the screen does with them: what
/// is observed from the database and how it's windowed, grouped and
/// scrolled to, reading, sending and the composer's state. The views only draw
/// what's published here and call back into it.
@MainActor
@Observable
final class ConversationModel {
    /// Something to ask or tell the user about.
    enum Prompt: Equatable {
        case error(String)
        case notice(title: String, message: String)
        /// Whether to show link previews in this chat.
        case linkPreviews
        /// A message that failed to send, with its way to try again.
        case failure(Int64)
        case confirmRetraction(Int64)
        /// Whether a moderator takes someone else's message back for everyone.
        case confirmModeration(Int64)
        case reactions(Int64)
        case quoteNotFound
    }

    let session: XMPPSession
    let peer: JID
    /// Whether the list is upside down, with each row turned back (see
    /// `MessageList`). The newest message is then at scroll offset 0, the
    /// scroll view's own resting point, and older ones are appended past the
    /// far end. Every place that measures or aims the list in "bottom" and
    /// "top" terms means the visual ones, and goes through this.
    let isFlipped: Bool
    /// Group chats name the sender above their messages. Known once `start`
    /// has read it, before any message is drawn.
    private(set) var isGroup = false
    /// A moderator's removal of a message is waiting for the room.
    private(set) var isRemovingForEveryone = false
    @ObservationIgnored private var previews: LinkPreviewer?

    // MARK: What the views draw

    private(set) var rows: [MessageRow] = []
    /// Messages that have just come in at the bottom, which slide in. Any
    /// other row the list creates during an animation (one scrolled into view
    /// as the keyboard moves) appears in place.
    private(set) var arrivingIDs: Set<Int64> = []
    /// Counts the messages from the contact that arrived while the chat was
    /// in front of the user, one step per burst. The glow over the list
    /// plays on each step.
    private(set) var receivedPulse = 0
    @ObservationIgnored private var lastPulse: ContinuousClock.Instant?
    /// Messages closer together than this share one pulse, which is about as
    /// long as the glow lasts: it must not pile up or restart on every line.
    static let pulseWindow = Duration.milliseconds(1200)
    private(set) var hasLoaded = false
    /// False while the list is being scrolled to the first unread message,
    /// which it takes a few tries to land on: the rows above are still
    /// estimates when it's first asked. The list stays hidden until then.
    private(set) var isPositioned = true
    private(set) var olderState = OlderMessages.idle
    /// Whether messages may still be on their way from the server: while
    /// connecting, catching up on the archive, or joining the group.
    private(set) var isFetchingHistory = false
    private(set) var unreadCount = 0
    private(set) var isSearching = false
    /// Where the list is scrolled to. Set along with the rows when a change
    /// has to move it (a jump, a message of ours, older messages above), so
    /// both land in the same frame. The scroll view writes to it as it
    /// scrolls; that mustn't redraw the list, which would ask it to scroll
    /// again, so only the model's own writes count as changes.
    @ObservationIgnored private var position: ScrollPosition
    private(set) var scrollRevision = 0
    /// How many times in a row `reanchorWhenStill` has nudged the margin.
    @ObservationIgnored private var nudges = 0
    /// A point added to the list's top margin and taken off again, see `reanchorWhenStill`.
    private(set) var layoutNudge: CGFloat = 0
    var scroll: ScrollPosition {
        get { position }
        set {
            position = newValue
            scrollRevision += 1
        }
    }

    /// The scroll view's own update of its position.
    func scrollViewMoved(_ new: ScrollPosition) {
        position = new
    }

    /// The message that was just jumped to, briefly emphasised.
    private(set) var flashID: Int64?
    /// Shown instead of the messages' bottom edge while the user is away from it.
    private(set) var isAwayFromBottom = false
    var prompt: Prompt?
    /// The row the list measures, to put it back where it was when older
    /// messages come in above it.
    private(set) var anchorID: Int64?
    /// The topmost row the user last had on screen. Unlike `anchorID` it
    /// outlives a blank list, which is what a recovery needs to know.
    @ObservationIgnored private var lastReadID: Int64?
    /// Whether any part of any row is on screen, which the scroll view reports
    /// at a hundredth of a row rather than half. Two tall rows can each be
    /// less than half in view and cover the screen, so a blank list is told
    /// by this and not by the rows reported as visible.
    @ObservationIgnored private(set) var anyRowVisible = true
    /// The message to bring the emoji keyboard up for, to pick a reaction.
    var emojiPicker: EmojiPickerRequest?
    /// The row the pointer last entered on the Mac, the only one that shows
    /// its hover bar. A row can miss the pointer leaving, as when its bar's
    /// menu was open, so the next row entered takes the bar from it.
    var hoveredRow: Int64?
    /// A hover bar's More menu was opened and the pointer hasn't moved in the
    /// conversation since. Not observed: the rows hear of the menu closing
    /// by `hoverMenuClosed` instead, so none of them reads this.
    @ObservationIgnored var hoverMenuOpen = false
    /// The contact whose OMEMO devices are listed, in a sheet.
    var devicesSheet: JID?
    var showsLocationPicker = false
    var showsGifPicker = false
    /// A key is built in and the setting is on.
    @ObservationIgnored private var gifsAvailable = false
    let transfers = TransferProgress()
    let composer = ComposerHandle()

    /// Photos and files being read and encoded before they show up as messages.
    var preparingAttachments = 0 {
        didSet { composer.bar?.setPreparingAttachment(preparingAttachments > 0) }
    }

    /// What was added to the composer, in the order it will go out with the
    /// next send. Not kept: it only lives as long as the model does.
    var pendingAttachments: [PendingAttachment] = [] {
        didSet {
            stagedFiles = pendingAttachments.compactMap { if case .file(let file, _) = $0.content { file } else { nil } }
            composer.bar?.setPendingAttachments(pendingAttachments)
        }
    }
    /// The copies behind `pendingAttachments`, for `deinit`, which can't read it.
    @ObservationIgnored nonisolated(unsafe) private var stagedFiles: [URL] = []
    /// False while the chat can't be written to (a blocked contact, a left
    /// group), when anything added to the composer is turned away.
    var canSendAttachments = true
    /// Something to send is being dragged over the composer.
    var composerDropTargeted = false

    private(set) var replyingTo: ConversationItem? {
        didSet { updateComposerBanner() }
    }
    /// One of our messages whose text the composer is changing.
    private(set) var editingItem: ConversationItem? {
        didSet { updateComposerBanner() }
    }

    /// The first message that was unread when the chat opened. The divider
    /// stays above it until the user leaves, however much gets read meanwhile.
    private(set) var unreadDividerId: Int64?

    // MARK: Internals

    /// What "today" is, for the day headers. Tests move it.
    @ObservationIgnored var now: () -> Date = Date.init

    @ObservationIgnored private var items: [Int64: ConversationItem] = [:]
    @ObservationIgnored private var order: [Int64] = []
    /// Where each id is in `order`, for the lookups the visible rows ask for.
    @ObservationIgnored private var orderIndex: [Int64: Int] = [:]
    @ObservationIgnored private var rowsByID: [Int64: MessageRow] = [:]
    @ObservationIgnored private var textCache: [Int64: CachedText] = [:]
    @ObservationIgnored private let tasks = TaskBag()
    @ObservationIgnored private var started = false
    /// Where the observed window of messages starts; nil while it's just the
    /// newest few hundred. Scrolling back moves it further back.
    @ObservationIgnored private var windowStart: MessageCursor?
    /// Where the observed window ends; nil while it runs through the newest
    /// message. A jump far back opens a window around its target, which is
    /// bounded like this, and scrolling down extends it until it reaches the
    /// newest. Tracked, as the scroll-to-end button shows while it's set.
    private var windowEnd: MessageCursor?
    /// The conversation's real end isn't loaded.
    var isBounded: Bool { windowEnd != nil }
    /// Moves with each `observeMessages`, so that an emission from an
    /// observation that has been replaced is ignored: it can arrive after the
    /// replacement was asked for, and carry a window nobody wants any more.
    @ObservationIgnored private var generation = 0
    /// The next window arriving is the bounded one grown further down. Its rows
    /// are added below what the user is looking at, which must stay put.
    @ObservationIgnored private var isExtending = false
    /// The next window arriving is the newest messages, asked for by the
    /// scroll-to-end button or a send: the list lands at its bottom.
    @ObservationIgnored private var pendingBottom = false
    /// A message to scroll to once the window has grown to include it.
    @ObservationIgnored private var pendingJump: Int64?
    /// The message the screen was asked to open on, until `start` arranges it.
    @ObservationIgnored private var openingMessage: Int64?
    /// From asking for a bigger window until it arrives, so scrolling in
    /// between doesn't ask again.
    @ObservationIgnored private var isWidening = false
    /// The server couldn't be asked just now (offline, still catching up);
    /// the connection changing is what tries again.
    @ObservationIgnored private var olderWaitsForConnection = false
    /// Set when the window is cut back to the newest messages, whose update
    /// shouldn't animate.
    @ObservationIgnored private var isTrimming = false
    /// How many older messages one step back adds to the window.
    private static let windowGrowth = 200
    /// How close to the window's oldest message a row has to be drawn for the
    /// next page to be fetched, whatever the scroll geometry says. The lazy
    /// stack guesses the length of the rows it hasn't measured, and that
    /// guess is thousands of points too long until the last rows are drawn, so
    /// a flick could reach the window's end before the list looked near the
    /// top at all. On iOS 26.5 the stack then swapped its guess for the real
    /// length mid-flick and the main thread stopped for minutes (the fuzz
    /// test's seed 19). With the page already on its way, that end is never
    /// reached with more history behind it.
    private static let olderPrefetchRows = 30
    /// A window longer than this is cut back when the user returns to the
    /// newest messages: every change re-reads all of it.
    private static let windowLimit = 1500
    /// Links whose previews were already asked for.
    @ObservationIgnored private var requestedLinks: Set<String> = []
    /// Display names by JID, so building a row doesn't read the database.
    @ObservationIgnored private var contactNames: [JID: String] = [:]
    /// The conversation's link preview choice; nil until the user makes it.
    @ObservationIgnored private var linkPreviewsAllowed: Bool?
    /// The app-wide choice, which overrides the chat's.
    @ObservationIgnored private var linkPreviewSetting: LinkPreviewSetting = .askPerConversation

    // What the list reports about itself.
    @ObservationIgnored private var geometry: ScrollGeometry?
    @ObservationIgnored var scrollPhase = ScrollPhase.idle
    #if DEBUG
    /// What the list did frame by frame, for UI tests. Nil unless asked for.
    @ObservationIgnored let recorder = ScrollRecorder.makeIfEnabled()
    #endif
    @ObservationIgnored private var isNearTop = false
    /// A jump has just scrolled the list. The near-top and near-end flags the
    /// list reported before it are stale until it has landed, and growing the
    /// window on them would shift the rows around the target.
    @ObservationIgnored private var jumpSettling = false
    @ObservationIgnored private var anchorFrame: (id: Int64, frame: CGRect)?
    /// The rows the scroll view says are mostly in view.
    @ObservationIgnored private var reportedVisibleIDs: [Int64] = []
    /// The rows that cover at least half of what the user sees. The scroll view
    /// reports a row once half of the row is in view, which a row taller than
    /// two screens never is.
    @ObservationIgnored private var fillingIDs: Set<Int64> = []
    /// The rows the lazy stack has built right now. The scroll view's reports
    /// of what is in view, and a row's own report of filling it, can both
    /// stay silent after a scroll that ends on a row (the scroll to latest
    /// onto a tall newest message): neither says anything, though the row is
    /// drawn. A row that exists is the one thing that is told whenever it
    /// comes and goes.
    @ObservationIgnored private var builtIDs: Set<Int64> = []
    /// A recovery was held back because an animated scroll was still moving
    /// the list, and is due once it settles.
    @ObservationIgnored private var reanchorWaitsForSettle = false
    @ObservationIgnored private(set) var visibleIDs: [Int64] = []
    /// The list is meant to show the newest message: it was opened there, the
    /// user scrolled back down to it, or the app took it there. The scroll
    /// view's own idea of the bottom moves as it measures rows, so this is
    /// what decides to go back, rather than where the offset happens to be.
    @ObservationIgnored private(set) var followsBottom = true
    @ObservationIgnored private var userMoved = false
    /// Whether the list followed the bottom when the current interaction started.
    @ObservationIgnored private var followedBeforeInteraction = false
    /// Whether the list's room (container height or top inset) changed during
    /// that interaction, which is the keyboard being dragged away.
    @ObservationIgnored private var roomChangedWhileInteracting = false

    /// We're in the group, as last observed; false for a chat with one person.
    @ObservationIgnored private var isActiveGroup = false
    /// What the connection and the room last said, to look again at when the group changes.
    @ObservationIgnored private var history: (state: XMPPSession.State, room: RoomStatus?)?

    // Reading.
    @ObservationIgnored private var marking: Task<Void, Never>?
    @ObservationIgnored private var pendingRead: Message?
    /// Messages older than what was already announced as read, which only
    /// the database needs to hear about.
    @ObservationIgnored private var pendingLateRead: Message?
    /// The newest message we've asked to be read, so scrolling doesn't ask
    /// for the same one on every frame.
    @ObservationIgnored private var readRequestedThrough: Date?
    /// Late messages (older than `readRequestedThrough`) already asked for,
    /// for the same reason.
    @ObservationIgnored private var lateReadRequested: Set<Int64> = []
    @ObservationIgnored private var isOnScreen = false

    // Chat states.
    /// What we last told the contact, so keystrokes don't ask the session
    /// (which reads the database) to decide that nothing needs sending.
    @ObservationIgnored private(set) var chatState: InboundMessage.ChatState?
    /// The devices we know of for senders whose messages the menu was opened
    /// on; observed, so a menu waiting for one fills in.
    private var senderDevices: [JID: [OMEMODevice]] = [:]
    @ObservationIgnored private var loadingDevices: Set<JID> = []
    @ObservationIgnored private var chatStateTail: Task<Void, Never>?
    /// Turns typing into "paused" after a few seconds of nothing. Both timers
    /// are only used on the main thread; deinit just has to stop them.
    @ObservationIgnored nonisolated(unsafe) private var pausedTimer: Timer?
    /// Turns a chat left open and untouched into "inactive".
    @ObservationIgnored nonisolated(unsafe) private var idleTimer: Timer?
    private static let pausedDelay: TimeInterval = 5
    private static let idleDelay: TimeInterval = 2 * 60

    /// Sending writes to the database, so it runs off the main thread. Each
    /// send waits for the one before, which keeps messages in the order they
    /// were typed.
    @ObservationIgnored private var sendTail: Task<Void, Never>?
    /// What was typed in the composer when an edit began, which the edit
    /// replaces and putting the edit away brings back.
    @ObservationIgnored private var draftBeforeEdit: String?

    /// The draft stored for this chat, read with the rest in `start`. It
    /// goes into the composer once, and only if the user hasn't typed.
    @ObservationIgnored private var storedDraft: String?
    @ObservationIgnored private var hasReadDraft = false
    @ObservationIgnored private var draftOffered = false
    /// The latest count of unread messages in the whole conversation.
    @ObservationIgnored private var observedUnread: Int?
    /// What the composer holds, apart from an edit's text, and what of it
    /// still has to be written. Read by `deinit`, which saves what the user
    /// left behind. The composer is made again when the bar under the list is
    /// swapped for another and comes back blank, and `composerText` is what
    /// it is given back.
    @ObservationIgnored nonisolated(unsafe) private var drafts = DraftTracker()
    private static let draftDelay: Duration = .seconds(1)
    /// A message made through this model is on its way, so the list follows
    /// it to the bottom. One that arrives from elsewhere (another device, the
    /// share extension, the archive) doesn't pull the reader away.
    @ObservationIgnored private var followsOwnSend = false

    /// The menu's row of quick reactions, five to leave room for one more to
    /// pick any emoji: the ones the user reaches for most, see
    /// `ReactionRanking`. It's a snapshot that changes only once a pick has
    /// been counted, which is after the menu has gone, so a menu never
    /// reshuffles while it's showing.
    private(set) var quickReactions = ReactionRanking.defaults

    /// `openingAt` is a message to open on instead of the first unread one,
    /// as when it was found by searching.
    init(session: XMPPSession, peer: JID, openingAt: Int64? = nil, isFlipped: Bool = Platform.flipsMessageList) {
        self.session = session
        self.peer = peer
        self.openingMessage = openingAt
        self.isFlipped = isFlipped
        self.position = ScrollPosition(edge: isFlipped ? .top : .bottom)
    }

    deinit {
        pausedTimer?.invalidate()
        idleTimer?.invalidate()
        // Through the shared writer, so an earlier flush can't land after it.
        if let text = drafts.flush() { DraftWriter.shared.save(text, for: peer, to: session.database) }
        // Leaving the chat drops what was staged, and nothing else owns the copies.
        for file in stagedFiles { AttachmentPicker.discardCopy(file) }
    }

    // MARK: Starting

    /// Opens the observations. Done once the screen is there rather than when
    /// the model is made, which SwiftUI may do more often than it keeps one.
    func start(previews: LinkPreviewer?) {
        guard !started else { return }
        started = true
        FrameLog.begin()
        loadQuickReactions()
        self.previews = previews
        let session = session, peer = peer
        let target = openingMessage
        openingMessage = nil
        let windowLimit = Self.windowLimit
        // Everything the first frame needs is read off the main thread. Until
        // it arrives nothing is loaded, which the screen shows as its
        // placeholder, and the calls that wait on a loaded list do nothing.
        tasks["start"] = Task { [weak self] in
            let initial = await Task.detached(priority: .userInitiated) { () -> Initial in
                let database = session.database
                var initial = Initial(
                    linkPreviewsAllowed: (try? database.linkPreviews(peer: peer)) ?? nil,
                    linkPreviewSetting: database.linkPreviewSetting,
                    contactNames: (try? database.contactNames()) ?? [:],
                    // Reach back far enough to open at the first unread message,
                    // however old, so there's no settling for the oldest one loaded.
                    openingStart: (try? database.openingWindow(peer: peer))?.start,
                    group: try? database.groupChat(peer),
                )
                // A draft still on its way to the database is newer than what's in it.
                initial.draft = DraftWriter.shared.current(for: peer, in: database)
                if let target, let window = try? database.window(peer: peer, around: target, boundedBeyond: windowLimit) {
                    initial.target = target
                    initial.targetWindow = window
                }
                return initial
            }.value
            guard !Task.isCancelled else { return }
            self?.finishStart(initial)
        }
    }

    /// What `start` reads before it can open the observations.
    private struct Initial: Sendable {
        var linkPreviewsAllowed: Bool?
        var linkPreviewSetting: LinkPreviewSetting
        var contactNames: [JID: String]
        var openingStart: MessageCursor?
        var group: GroupChat?
        var draft: String?
        var target: Int64?
        var targetWindow: (start: MessageCursor, end: MessageCursor?)?
    }

    private func finishStart(_ initial: Initial) {
        let database = session.database
        isGroup = initial.group != nil
        // So the first menu on a message from the contact has their device.
        if !isGroup { loadDevices(of: peer) }
        linkPreviewsAllowed = initial.linkPreviewsAllowed
        linkPreviewSetting = initial.linkPreviewSetting
        contactNames = initial.contactNames
        windowStart = initial.openingStart
        storedDraft = initial.draft
        hasReadDraft = true
        offerDraft()
        if let target = initial.target, let window = initial.targetWindow {
            // The window may need to reach further back than it would; the
            // first apply finds the message in it and scrolls there. Far back,
            // it's a window around the message instead.
            if window.end == nil {
                let alreadyReaches = windowStart.map { ($0.timestamp, $0.id) <= (window.start.timestamp, window.start.id) } ?? false
                if !alreadyReaches { windowStart = window.start }
            } else {
                windowStart = window.start
                windowEnd = window.end
            }
            pendingJump = target
        }
        observeMessages()
        session.downloadMissedImages(in: peer)

        // Apart from the window, so a message arriving past its end is counted.
        let unread = database.observeUnreadMessageCount(peer: peer)
        tasks["unread"] = Task { [weak self] in
            await database.forEachValue(of: unread, "Unread count") { self?.unreadCountObserved($0) }
        }

        let linkPreviews = database.observeLinkPreviews(peer: peer)
        tasks["linkPreviews"] = Task { [weak self] in
            await database.forEachValue(of: linkPreviews, "Link preview setting") { self?.linkPreviewsChanged($0) }
        }

        let linkPreviewSetting = database.observeLinkPreviewSetting()
        tasks["linkPreviewSetting"] = Task { [weak self] in
            await database.forEachValue(of: linkPreviewSetting, "Link preview app setting") { self?.linkPreviewSettingChanged($0) }
        }

        let gifsEnabled = database.observeGifsEnabled()
        tasks["gifsEnabled"] = Task { [weak self] in
            await database.forEachValue(of: gifsEnabled, "GIF setting") { self?.gifsEnabledChanged($0) }
        }

        // "Today" and "Yesterday" in the day headers go stale at midnight, and
        // when the clock or time zone changes. The times in the bubbles keep
        // the 12 or 24 hour format they were drawn with until the locale
        // changes too.
        for (key, name) in [
            ("dayChanged", Notification.Name.NSCalendarDayChanged),
            ("timeChanged", UIApplication.significantTimeChangeNotification),
            ("localeChanged", NSLocale.currentLocaleDidChangeNotification),
        ] {
            tasks[key] = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                    self?.dayChanged()
                }
            }
        }

        let names = database.observeContactNames()
        tasks["contactNames"] = Task { [weak self] in
            await database.forEachValue(of: names, "Contact names") { self?.contactNamesChanged($0) }
        }

        if isGroup {
            isActiveGroup = initial.group?.hasLeft == false
            let group = database.observeGroupChat(peer)
            tasks["group"] = Task { [weak self] in
                await database.forEachValue(of: group, "Group") { self?.groupChanged($0) }
            }
        }

        let transferUpdates = session.transfers.values
        tasks["transfers"] = Task { [weak self] in
            for await progress in transferUpdates {
                self?.transfers.update(progress)
            }
        }

        let history = session.state.combineLatest(session.rooms).values
        let peer = peer
        tasks["history"] = Task { [weak self] in
            for await (state, rooms) in history {
                self?.historyChanged(state, room: rooms[peer])
            }
        }
    }

    // MARK: Data

    /// One observation of the window of messages; asking for a different
    /// window replaces it.
    private func observeMessages() {
        generation += 1
        let generation = generation
        let observation = session.database.observeConversation(peer: peer, me: session.account, since: windowStart, until: windowEnd)
        let database = session.database
        tasks["messages"] = Task { [weak self] in
            await database.forEachValue(of: observation, "Conversation") { items in
                // Link detection is slow, and on the main actor it blocked the
                // first frames of the push into a conversation. Render what the
                // rows need here, so `apply` finds it all cached.
                guard let self else { return }
                let missing: [(id: Int64, key: TextKey)] = items.compactMap { item in
                    self.textKey(for: item).flatMap { key in self.textCache[item.id]?.key == key ? nil : (item.id, key) }
                }
                if !missing.isEmpty {
                    let rendered = await Task.detached(priority: .userInitiated) { Self.renderTexts(missing) }.value
                    guard generation == self.generation else { return }
                    for (id, cached) in rendered { self.textCache[id] = cached }
                }
                self.apply(items, generation: generation)
            }
        }
    }

    private func groupChanged(_ group: GroupChat?) {
        let active = group?.hasLeft == false
        guard active != isActiveGroup else { return }
        isActiveGroup = active
        if let history { historyChanged(history.state, room: history.room) }
    }

    private func historyChanged(_ state: XMPPSession.State, room: RoomStatus?) {
        history = (state, room)
        let fetching = switch state {
        case .connecting, .connected(isSyncing: true): true
        case .connected(isSyncing: false):
            // Until we're in, a group's messages come with joining.
            isGroup && isActiveGroup
                && (room.map { $0.phase == .joining || $0.isSyncing } ?? true)
        case .disconnected, .failed: false
        }
        // Back online, or through catching up: older messages were waiting on that.
        if case .connected(isSyncing: false) = state, !fetching {
            olderWaitsForConnection = false
            loadOlderIfNeeded()
        }
        guard fetching != isFetchingHistory else { return }
        isFetchingHistory = fetching
    }

    private func apply(_ newItems: [ConversationItem], generation: Int) {
        guard generation == self.generation else { return }
        let wasNearBottom = isNearBottom
        let previousOrder = order
        let old = items
        FrameLog.event("apply begin items=\(newItems.count) previous=\(previousOrder.count)")
        defer { FrameLog.event("apply end rows=\(rows.count)") }
        // Older messages came in above: the ones on screen have to stay put.
        let prepended = hasLoaded && (previousOrder.first.flatMap { first in newItems.firstIndex { $0.id == first } } ?? 0) > 0
        let trimming = isTrimming
        isTrimming = false
        let extending = isExtending
        isExtending = false
        let toNewest = pendingBottom
        pendingBottom = false
        // Below the window there are messages the list doesn't show, so it
        // isn't at the end of the conversation wherever it's scrolled.
        let bounded = windowEnd != nil

        if !hasLoaded {
            // The window was opened to reach the first unread message. Only
            // with more unread than the window may hold does the divider go
            // above the oldest one loaded.
            unreadDividerId = newItems.first { $0.message.direction == .incoming && !$0.message.isRead }?.id
        }
        items = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        order = newItems.map(\.id)
        orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        // A removed row never reports again.
        if !fillingIDs.isEmpty { fillingIDs.formIntersection(orderIndex.keys) }
        if !builtIDs.isEmpty { builtIDs.formIntersection(orderIndex.keys) }
        // A bounded window leaves out unread messages below it: those are
        // counted in the database, not in the rows.
        if bounded, let observedUnread { unreadCount = observedUnread }
        if !bounded || !hasLoaded { unreadCount = newItems.count { $0.message.direction == .incoming && !$0.message.isRead } }
        // Only what is new or whose link or preview changed can need a fetch;
        // anything else was looked at on an earlier emission.
        fetchMissingPreviews(in: newItems.lazy.filter { item in
            guard let before = old[item.id] else { return true }
            return before.message.link != item.message.link || before.preview != item.preview
        })

        let lastIsMine = !extending && !bounded && followsOwnSend && (newItems.last.map { $0.message.direction == .outgoing && $0.id != previousOrder.last } ?? false)
        if lastIsMine { followsOwnSend = false }
        let reshapeOnly = previousOrder == order
            && order.contains { id in old[id].map { $0.preview != items[id]?.preview || $0.attachment != items[id]?.attachment } ?? false }

        var jumped = false
        // The window asked for with the jump has arrived. If the target isn't
        // in it (deleted or purged meanwhile) there's nothing to scroll to,
        // and holding the jump would stop older messages from loading.
        let jump = pendingJump
        pendingJump = nil
        // The scroll position goes out with the rows, never after them: the
        // list would draw a frame in the wrong place in between.
        if !hasLoaded {
            if let jump, items[jump] != nil {
                // Flashed once the list is shown: while it's hidden only the
                // shrink would be seen.
                settleOpeningScroll(at: jump, anchor: .center, flashing: jump)
                beginJumpSettling()
            } else if let id = unreadDividerId, !Self.dividerIsAmongLast(id, in: order) {
                settleOpeningScroll(at: id, anchor: .top)
            } else {
                scroll = ScrollPosition(edge: newestEdge)
            }
        } else if let jump, items[jump] != nil {
            jumped = true
            followsBottom = false
            FrameLog.event("scroll.scrollTo jump id=\(jump) center")
            scroll.scrollTo(id: jump, anchor: .center)
            beginJumpSettling()
            flash(jump)
        } else if toNewest {
            scrollToBottom(animated: false, reason: "toNewest")
        } else if extending {
            // Rows added below would push the ones on screen up, as the list
            // follows its bottom edge.
            keepAnchorInPlace()
        } else if lastIsMine || (wasNearBottom && !isAtBottomEdge && !bounded) {
            scrollToBottom(animated: !reshapeOnly && !prepended && !trimming, reason: "rowsChanged.follow")
        } else if prepended, !wasNearBottom || bounded, !isFlipped {
            // Flipped, older rows come in past the far end of the scroll
            // view and leave every offset where it is.
            keepAnchorInPlace()
        }
        if bounded { followsBottom = false }

        #if DEBUG
        // Where the anchor row is now is what the recorder measures its move from.
        if prepended { recorder?.update { $0.olderRowsComing() } }
        #endif
        let previousRows = rowsByID
        let built = buildRows()
        // Rows the user sees changing in place animate, and so do new ones.
        // Not older rows, a trimmed window or a jump, which move rows that
        // must stay put. Nor a bubble whose text or media changed: it resizes
        // in one frame and its bottom edge sinks below the screen until the
        // scroll view catches up, which looks worse than not animating.
        let resizes = built.contains { row in
            previousRows[row.id].map {
                $0.content.text != row.content.text || $0.content.preview != row.content.preview
                    || $0.content.attachment != row.content.attachment || $0.content.location != row.content.location
            } ?? false
        }
        // Scrolled up, rows added below or rows changing height there make
        // the bottom-anchored list shift what's on screen up. Nothing is
        // done when the list is near the bottom (it follows, or the cases
        // above scroll), and not for a change that moves nothing.
        let appendedBelow = previousOrder.last.flatMap { orderIndex[$0] }.map { $0 < order.count - 1 } ?? false
        let changesHeight = resizes || built.contains { row in
            previousRows[row.id].map { $0.content.item.reactions.isEmpty != row.content.item.reactions.isEmpty } ?? false
        }
        let holdsAnchor = hasLoaded && (!wasNearBottom || bounded) && !prepended && !trimming && !jumped && !extending && !toNewest && !lastIsMine
            && (appendedBelow || changesHeight && scrollPhase == .idle)
        if holdsAnchor { keepAnchorInPlace() }
        if hasLoaded, !prepended, !trimming, !jumped, !resizes, !extending, !toNewest, !holdsAnchor {
            // A reaction under the newest bubble makes the list longer at the
            // bottom. Scrolling to the newest row in the same animation keeps
            // its bottom edge where it is the whole way.
            let holdsBottom = wasNearBottom && isAtBottomEdge && !lastIsMine
            let lastBefore = previousOrder.last.flatMap { orderIndex[$0] }
            let arriving = Set(order.enumerated().compactMap { index, id in
                previousRows[id] == nil && lastBefore.map { index > $0 } ?? false ? id : nil
            })
            notePulse(for: arriving)
            withAnimation(.easeOut(duration: 0.25)) {
                if arrivingIDs != arriving { arrivingIDs = arriving }
                replaceRows(built)
                // Flipped, the newest row's end is the scroll view's resting
                // point, and it grows away from it.
                if holdsBottom, !isFlipped, let last = order.last {
                    FrameLog.event("scroll.scrollTo holdsBottom id=\(last) bottom")
                    scrollToNewestRow(last)
                }
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if !arrivingIDs.isEmpty { arrivingIDs = [] }
                replaceRows(built)
            }
        }
        if !arrivingIDs.isEmpty {
            // Once they've slid in, so a row that scrolls back into view later doesn't.
            tasks["arriving"] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                tasks.finish("arriving")
                arrivingIDs = []
            }
        }
        hasLoaded = true
        isWidening = false
        markVisibleRead()
        if prepended {
            // Whether the list is still near the top is only known once it
            // has placed the rows that came in above: asking now, with the
            // answer from before, loads the same page twice.
            isNearTop = false
            recheckNearTopSoon()
        } else {
            loadOlderIfNeeded()
        }
        loadNewerIfNeeded()
    }

    /// Starts a pulse for a message from the contact that landed at the
    /// bottom of a chat the user is looking at. Our own messages, including
    /// copies from our other devices, are not news to them, and nobody sees
    /// the glow in the background.
    private func notePulse(for arriving: Set<Int64>) {
        guard isOnScreen, UIApplication.shared.applicationState == .active,
              arriving.contains(where: { items[$0]?.message.direction == .incoming }) else { return }
        let now = ContinuousClock.now
        if let lastPulse, now - lastPulse < Self.pulseWindow { return }
        lastPulse = now
        receivedPulse += 1
    }

    /// After older messages came in, looks at where the list is once it has
    /// settled and goes on loading if it's still near the top: a window that
    /// fits the screen, or a user waiting at the top. The list only reports
    /// a change of answer, so a "still near" would never be heard.
    private func recheckNearTopSoon() {
        tasks["nearTop"] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            tasks.finish("nearTop")
            if let geometry { isNearTop = Self.isNearTop(geometry, flipped: isFlipped) }
            loadOlderIfNeeded()
        }
    }

    static func isNearTop(_ geometry: ScrollGeometry, flipped: Bool) -> Bool {
        distanceFromTop(geometry, flipped: flipped) < geometry.containerSize.height * 1.5
    }

    /// The database's count, which the rows can't give while a bounded window
    /// leaves out what's below it. It's only used then: with the whole tail
    /// loaded the rows already say it.
    private func unreadCountObserved(_ count: Int) {
        observedUnread = count
        if windowEnd != nil { unreadCount = count }
    }

    /// Holds back growing the window until the jump has landed and the list
    /// has reported where it is, then looks again, so a target that really is
    /// near the window's edge still extends it.
    private func beginJumpSettling() {
        jumpSettling = true
        tasks["jumpSettle"] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            tasks.finish("jumpSettle")
            jumpSettling = false
            loadOlderIfNeeded()
            loadNewerIfNeeded()
        }
    }

    /// Whether the unread divider is so near the end that opening at the
    /// bottom shows it anyway. Then no rows above it need measuring, so the
    /// list needn't be hidden while it finds its place. The last few rows are
    /// a count, not a height, as the rows aren't measured yet: three can't
    /// outgrow a screen unless they are all photos, and then the newest
    /// message is still what the user comes to see.
    private static func dividerIsAmongLast(_ id: Int64, in order: [Int64]) -> Bool {
        guard let index = order.firstIndex(of: id) else { return false }
        return order.count - index <= 3
    }

    /// Asks again for the message to open on while the rows around it are
    /// measured, then shows the list.
    private func settleOpeningScroll(at id: Int64, anchor: UnitPoint, flashing: Int64? = nil) {
        let anchor = flipped(anchor)
        isPositioned = false
        followsBottom = false
        tasks["opening"] = Task { [weak self] in
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                FrameLog.event("scroll.scrollTo opening id=\(id)")
                self.scroll.scrollTo(id: id, anchor: anchor)
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.isPositioned = true
            if let flashing { self.flash(flashing) }
            // What the list reported while hidden was its default place at the
            // bottom; what's on screen now is what the user is looking at.
            self.markVisibleRead()
            self.loadNewerIfNeeded()
        }
    }

    private func replaceRows(_ new: [MessageRow]) {
        guard new != rows else { return }
        rows = new
    }

    // MARK: Rows

    private struct TextKey: Hashable, Sendable {
        var body: String
        var kind: MessageText.Kind
        /// Whether a long body is shown cut short.
        var collapsed: Bool

        var opened: TextKey {
            var key = self
            key.collapsed = false
            return key
        }
    }

    /// A body's rendering, with the words read out for accessibility, kept
    /// for as long as the body and its kind stay the same.
    private struct CachedText: Sendable {
        var key: TextKey
        var text: RenderedText
        var spoken: String
        /// The whole of a body that `text` shows cut short. It is rendered
        /// here anyway for `spoken`, and keeping it lets Show more swap it in
        /// without rendering a long body again on the main actor.
        var whole: RenderedText?
    }

    /// Whether a row shows a location or text, and the text's key if so.
    private struct TextPlan {
        var location: GeoLocation?
        var key: TextKey?
    }

    private func textPlan(for item: ConversationItem) -> TextPlan {
        let message = item.message
        // A call's body is only a fallback for clients that show no calls.
        guard message.call == nil else { return TextPlan() }
        let isOutgoing = message.direction == .outgoing
        // A file message's body is just the file's URL.
        let bodyIsFile = item.attachment.map { message.body.isEmpty || message.body == $0.url } ?? false
        let location = item.attachment == nil && !message.isRetracted && message.encryption != .omemoUndecryptable && message.meAction == nil
            ? GeoLocation(body: message.body) : nil
        guard location == nil, !bodyIsFile else { return TextPlan(location: location, key: nil) }
        let kind: MessageText.Kind = if message.isRetracted {
            message.isModerated ? .moderated : .retracted(outgoing: isOutgoing)
        } else if message.encryption == .omemoUndecryptable {
            .undecryptable
        } else if message.meAction != nil {
            .action(name: isOutgoing ? String(localized: "You") : authorName(for: message.author))
        } else {
            .normal
        }
        return TextPlan(location: nil, key: TextKey(body: message.body, kind: kind, collapsed: !showsEveryBodyWhole && !showingWhole.contains(item.id)))
    }

    /// The key of the text a row shows; nil when it shows none.
    private func textKey(for item: ConversationItem) -> TextKey? {
        textPlan(for: item).key
    }

    private nonisolated static func renderText(_ key: TextKey) -> CachedText {
        let rendered = MessageText.render(key.body, kind: key.kind, collapsed: key.collapsed)
        // VoiceOver reads the whole body: the cut is for the eye, and a
        // reader who can't see it would hear a message that stops short.
        let whole = rendered.isCollapsed ? MessageText.render(key.body, kind: key.kind) : rendered
        return CachedText(
            key: key, text: rendered,
            spoken: whole.segments.map { String($0.text.characters) }.joined(separator: "\n"),
            whole: rendered.isCollapsed ? whole : nil,
        )
    }

    private nonisolated static func renderTexts(_ keys: [(id: Int64, key: TextKey)]) -> [Int64: CachedText] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0.id, renderText($0.key)) })
    }

    /// The messages whose long bodies the reader opened, for as long as the
    /// conversation is.
    @ObservationIgnored private var showingWhole: Set<Int64> = []
    #if DEBUG
    /// UI tests of rows taller than the screen need them to stay that tall.
    private let showsEveryBodyWhole = ProcessInfo.processInfo.environment["YAPNEST_DEV_SHOW_WHOLE"] == "1"
    #else
    private let showsEveryBodyWhole = false
    #endif

    /// Opens a long body that was cut short.
    func showWholeBody(of id: Int64) {
        guard showingWhole.insert(id).inserted else { return }
        rebuildRows()
    }

    private func rebuildRows() {
        replaceRows(buildRows())
    }

    /// What of a message's neighbour decides how it is drawn: whether they
    /// are grouped, where the day changes, and whether the bubbles join.
    private struct Neighbour: Equatable {
        var direction: Message.Direction
        var author: Author
        var timestamp: Date
        var hasReactions: Bool

        init(_ item: ConversationItem) {
            direction = item.message.direction
            author = item.message.author
            timestamp = item.message.timestamp
            hasReactions = !item.reactions.isEmpty
        }
    }

    /// Everything `makeContent` reads for one row, apart from what is fixed
    /// for the screen's life (the account, whether it's a group, the link
    /// preview service) and the time zone and locale, which `buildRows`
    /// checks once for all rows. A row whose inputs are equal to those it
    /// was last built from has the same content, so it isn't built again.
    /// Anything new that `makeContent` reads belongs here.
    private struct RowInputs: Equatable {
        var item: ConversationItem
        var previous: Neighbour?
        var next: Neighbour?
        var hasUnreadDivider: Bool
        var showsWholeBody: Bool
        /// Nothing is newer, so a message's suggested replies are still on offer.
        var isNewest: Bool
        /// Names, the chat's link preview choice and the app's: see `inputsEpoch`.
        var epoch: Int
    }

    /// Bumped when something row-wide that isn't in a row's item changes: the
    /// contacts' names, or the link preview choices.
    @ObservationIgnored private var inputsEpoch = 0
    @ObservationIgnored private var inputsByID: [Int64: RowInputs] = [:]
    /// The time zone and locale the rows were last built in.
    @ObservationIgnored private var builtIn: (calendar: Calendar, locale: Locale)?

    private func buildRows() -> [MessageRow] {
        var built: [MessageRow] = []
        built.reserveCapacity(order.count)
        var newTexts: [Int64: CachedText] = [:]
        var byID: [Int64: MessageRow] = [:]
        byID.reserveCapacity(order.count)
        var newInputs: [Int64: RowInputs] = [:]
        newInputs.reserveCapacity(order.count)
        let environment = (calendar: Calendar.current, locale: Locale.current)
        let sameEnvironment = builtIn.map { $0.calendar == environment.calendar && $0.locale == environment.locale } ?? false
        builtIn = environment
        let neighbours = order.map { Neighbour(items[$0]!) }
        for index in order.indices {
            let id = order[index]
            let item = items[id]!
            let inputs = RowInputs(
                item: item,
                previous: index > 0 ? neighbours[index - 1] : nil,
                next: index + 1 < order.count ? neighbours[index + 1] : nil,
                hasUnreadDivider: id == unreadDividerId,
                showsWholeBody: showingWhole.contains(id),
                isNewest: index == order.count - 1 && !isBounded,
                epoch: inputsEpoch,
            )
            newInputs[id] = inputs
            if sameEnvironment, let existing = rowsByID[id], inputsByID[id] == inputs {
                built.append(existing)
                byID[id] = existing
                newTexts[id] = textCache[id]
                continue
            }
            let content = makeContent(at: index, isNewest: inputs.isNewest, texts: &newTexts)
            let row: MessageRow
            if let existing = rowsByID[id], existing.content == content {
                row = existing
            } else {
                row = MessageRow(content: content, revision: (rowsByID[id]?.revision ?? 0) + 1)
            }
            built.append(row)
            byID[id] = row
        }
        rowsByID = byID
        inputsByID = newInputs
        textCache = newTexts
        return built
    }

    private func makeContent(at index: Int, isNewest: Bool, texts: inout [Int64: CachedText]) -> MessageRow.Content {
        let item = items[order[index]]!
        let message = item.message
        let isOutgoing = message.direction == .outgoing
        let previous = index > 0 ? items[order[index - 1]] : nil
        let next = index + 1 < order.count ? items[order[index + 1]] : nil
        let calendar = Calendar.current
        func grouped(_ a: ConversationItem?, _ b: ConversationItem?) -> Bool {
            guard let a, let b else { return false }
            return a.message.direction == b.message.direction
                && a.message.author == b.message.author
                && abs(a.message.timestamp.timeIntervalSince(b.message.timestamp)) < 120
                && calendar.isDate(a.message.timestamp, inSameDayAs: b.message.timestamp)
        }
        let showsDay = previous.map { !calendar.isDate($0.message.timestamp, inSameDayAs: message.timestamp) } ?? true
        let startsRun = !grouped(previous, item) || showsDay
        let layout = MessageRow.Layout(
            dayHeader: showsDay ? message.timestamp.dayHeaderFormatted(now: now()) : nil,
            showsUnreadDivider: item.id == unreadDividerId,
            joinsPrevious: grouped(previous, item),
            joinsNext: grouped(item, next) && next?.reactions.isEmpty != false && item.reactions.isEmpty,
        )

        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        if let call = message.call {
            return MessageRow.Content(
                item: item, kind: .call(call), layout: layout, quoteAuthor: "", quoteText: "", time: time,
                security: message.security, preview: .none, accessibilityLabel: [call.title, time].joined(separator: ", "),
            )
        }

        let attachment = attachmentDisplay(for: item)
        let plan = textPlan(for: item)
        var text: RenderedText?
        var spoken: String?
        if plan.location != nil {
            spoken = String(localized: "Location")
        } else if let key = plan.key {
            let cached: CachedText
            let existing = textCache[item.id]
            if let existing, existing.key == key {
                cached = existing
            } else if let existing, let whole = existing.whole, existing.key.opened == key {
                // Show more: the full rendering was made with the cut one.
                cached = CachedText(key: key, text: whole, spoken: existing.spoken)
            } else {
                // Only reached for a key that changed outside the observation,
                // which renders ahead of `apply`: a contact's name, say.
                cached = Self.renderText(key)
            }
            texts[item.id] = cached
            text = cached.text
            spoken = cached.spoken
        }

        let who = isOutgoing ? String(localized: "You") : authorName(for: message.author)
        // A file's own summary starts with an emoji and a bare file message has
        // no words, so VoiceOver gets the kind and name spelled out instead.
        let attachmentSpoken = attachment.map { display -> String in
            let file = display.attachment
            let kind = file.isImage ? String(localized: "Photo")
                : file.isVideo ? String(localized: "Video")
                : file.isContact ? String(localized: "Contact: \(file.contactName)")
                : String(localized: "File: \(file.name)")
            return [kind, display.sizeText].compactMap { $0 }.joined(separator: ", ")
        }
        let state: String? = if isOutgoing && message.status == .failed {
            String(localized: "Not sent")
        } else if message.editedAt != nil {
            String(localized: "Edited")
        } else {
            nil
        }
        let preview = previewDisplay(for: item)
        let previewTitle: String? = switch preview {
        case .page(let preview, _), .image(let preview, _): preview.title
        case .none, .ask: nil
        }
        let replying: String? = item.quote.map { quote in
            let author = item.quote?.author.map(authorName(for:))
            let summary = quote.text.trimmingBlankEdgeLines
            return author.map { String(localized: "Replying to \($0): \(summary)") } ?? String(localized: "Replying to: \(summary)")
        }
        let reactions: String? = item.reactions.isEmpty ? nil
            : String(localized: "Reactions: \(item.reactions.map { "\($0.emoji) \($0.senders.count)" }.joined(separator: ", "))")
        let words = [replying, spoken ?? attachmentSpoken, previewTitle, reactions, state, time].compactMap { $0 }.joined(separator: ", ")
        let showsName = isGroup && !isOutgoing && startsRun
        return MessageRow.Content(
            item: item,
            layout: layout,
            senderName: showsName ? authorName(for: message.author) : nil,
            quoteAuthor: item.quote?.author.map(authorName(for:)) ?? "",
            quoteText: item.quote?.text.trimmingBlankEdgeLines ?? "",
            senderColor: showsName ? SenderColor.color(for: message.author) : nil,
            time: time,
            security: message.security,
            text: text,
            preview: preview,
            attachment: attachment,
            location: plan.location,
            showsResponses: isNewest && !isOutgoing,
            isBare: MessageRow.drawsWithoutBubble(
                isEmojiOnly: text?.isEmojiOnly ?? false, isRetracted: message.isRetracted, isAction: message.meAction != nil,
                isUndecryptable: message.encryption == .omemoUndecryptable, hasQuote: item.quote != nil,
                hasAttachment: attachment != nil, hasLocation: plan.location != nil, preview: preview,
            ),
            accessibilityLabel: [who, words].joined(separator: ": "),
        )
    }

    /// In groups, the nickname people chose there; in 1:1 chats, the contact's name.
    func authorName(for author: Author) -> String {
        if author.jid == session.account { return String(localized: "You") }
        if isGroup, let nick = author.nick { return nick }
        return contactNames[author.jid] ?? author.jid.shortName
    }

    private func attachmentDisplay(for item: ConversationItem) -> AttachmentDisplay? {
        guard let attachment = item.attachment else { return nil }
        let file = attachment.state == .ready || attachment.state == .pendingUpload ? session.attachments.url(for: attachment) : nil
        return AttachmentDisplay(attachment: attachment, fileURL: file)
    }

    // MARK: Link previews

    private func previewDisplay(for item: ConversationItem) -> PreviewDisplay {
        guard item.message.link != nil, let previews else { return .none }
        switch decision(for: item.message) {
        case .ask: return .ask
        case .off: return .none
        case .show:
            guard let preview = item.preview else { return .none }
            let image = previews.imageURL(for: preview)
            switch preview.kind {
            case .image: return image.map { .image(preview, $0) } ?? .none
            case .page: return .page(preview, image)
            case .none: return .none
            }
        }
    }

    private func decision(for message: Message) -> LinkPreviewPolicy.Decision {
        LinkPreviewPolicy.decide(global: linkPreviewSetting, chat: linkPreviewsAllowed,
                                  isOurs: Message.isTrustedOutgoing(isOutgoing: message.direction == .outgoing, isWrittenHere: message.isWrittenHere, inGroup: isGroup))
    }

    private func fetchMissingPreviews() {
        fetchMissingPreviews(in: items.values)
    }

    private func fetchMissingPreviews(in candidates: some Sequence<ConversationItem>) {
        guard let previews else { return }
        for item in candidates where item.preview == nil {
            // Asked for once per link: this runs on every emission.
            guard let string = item.message.link, !requestedLinks.contains(string),
                  decision(for: item.message) == .show, let link = URL(string: string) else { continue }
            requestedLinks.insert(string)
            previews.fetchIfNeeded(link)
        }
    }

    private func dayChanged() {
        inputsEpoch += 1
        rebuildRows()
    }

    private func contactNamesChanged(_ names: [JID: String]) {
        guard names != contactNames else { return }
        contactNames = names
        inputsEpoch += 1
        rebuildRows()
    }

    private func linkPreviewsChanged(_ allowed: Bool?) {
        guard allowed != linkPreviewsAllowed else { return }
        linkPreviewsAllowed = allowed
        inputsEpoch += 1
        redrawLinkedMessages()
    }

    private func linkPreviewSettingChanged(_ setting: LinkPreviewSetting) {
        guard setting != linkPreviewSetting else { return }
        linkPreviewSetting = setting
        inputsEpoch += 1
        redrawLinkedMessages()
    }

    private func gifsEnabledChanged(_ enabled: Bool) {
        gifsAvailable = enabled && Klipy.apiKey != nil
        composer.bar?.setGifsAvailable(gifsAvailable)
    }

    private func redrawLinkedMessages() {
        fetchMissingPreviews()
        rebuildRows()
    }

    func askForLinkPreviews() {
        prompt = .linkPreviews
    }

    func setLinkPreviews(_ allowed: Bool) {
        write { [database = session.database, peer] in
            try database.setLinkPreviews(allowed, peer: peer)
        }
    }

    // MARK: Scrolling

    /// Called by the list as it scrolls or resizes.
    func geometryChanged(_ geometry: ScrollGeometry) {
        FrameLog.geometry(geometry, model: self)
        let previous = self.geometry
        self.geometry = geometry
        let resized = previous.map { $0.containerSize.height != geometry.containerSize.height } ?? false
        let insetChanged = previous.map { Self.topInset($0, flipped: isFlipped) != Self.topInset(geometry, flipped: isFlipped) } ?? false
        if scrollPhase == .interacting, resized || insetChanged {
            roomChangedWhileInteracting = true
        }
        guard hasLoaded, scrollPhase != .interacting else { return }
        // The keyboard and the composer change the room the list has. The lazy
        // stack then places its rows again from guessed heights, which with
        // rows of very different heights can leave the newest far from where
        // the list ends. The delayed run looks at the settled geometry and
        // puts right a list that is off; during the relayout the stack
        // reports transient estimates that swing by thousands of points, and
        // scrolling to the bottom of one of them draws a jump.
        // A flipped list that follows its end can also move away from it
        // while at rest. After an animated scroll to a tall newest row, iOS 27
        // reports the animation done at the start, then moves the offset by
        // itself as the lazy stack replaces its guess of the row's height (196,
        // then 918 points, the content unchanged). The scroll phase never
        // changes again, so `scrollSettled` doesn't see it, and the list rests
        // short of the newest message.
        let atRest = scrollPhase == .idle
        let driftedFromNewest = isFlipped && atRest && !isAtBottomEdge
        let pastAnEnd = atRest && (bottomDistance(geometry) < -1.5 || Self.distanceFromTop(geometry, flipped: isFlipped) < -1.5)
        if followsBottom && (resized || insetChanged || driftedFromNewest) || pastAnEnd {
            reanchorWhenStill()
        }
    }

    /// Scrolls to the newest row once the list's size has stopped changing,
    /// if the rows the user should see aren't there. While the keyboard is
    /// dragged away by hand, every frame changes the list's height, and the
    /// bottom anchor already holds the end in place. Jumping to the newest row
    /// on each of those frames made the lazy stack swap between two guesses
    /// of its height, a few hundred points apart, so the offset swung between
    /// them and every other frame showed no rows: a black flash, or a blank
    /// list when it stopped on the wrong one. Each change pushes this back.
    private func reanchorWhenStill() {
        let offsetAtStart = geometry?.contentOffset.y
        tasks["reanchor"] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            // `.animating` too: the phase can stay there after an animated scroll to the latest message.
            guard let self, !Task.isCancelled, hasLoaded, [.idle, .animating].contains(scrollPhase), let geometry, let last = order.last else { return }
            // An animated scroll that is still going gets the list to the
            // newest row by itself, and the rows it passes over are reported
            // as none for a moment while the stack lays out guesses. Nudging
            // then only adds a layout in the middle of the flight; looking
            // again when it settles covers a list it leaves blank.
            if scrollPhase == .animating, geometry.contentOffset.y != offsetAtStart {
                reanchorWaitsForSettle = true
                return
            }
            let distance = bottomDistance(geometry)
            let pastEnd = distance < -1.5 && geometry.contentSize.height > geometry.containerSize.height
            // Two cases of an empty report. The newest row is taller than the
            // scroll view's half-in-view rule can ever report, it fills the
            // view, and the list sits at its end: nothing is wrong, and
            // nudging would make the stack lay out from guesses for a frame.
            // Anything else is recovered as before, since a row that filled
            // the view may have been released since without saying so, and a
            // stale fill must not hide a blank list or one off its end.
            //
            // The newest row counts as in view too when the lazy stack has it
            // built and the list rests at its end: it is then at the very
            // place the list rests, whether or not anything reported it.
            let present = isDrawn(last, atDistance: distance) ? presentIDs + (presentIDs.contains(last) ? [] : [last]) : reportedVisibleIDs
            let newestMissing = followsBottom && (!present.contains(last) || distance > 1.5)
            if !present.isEmpty { nudges = 0 }
            FrameLog.event("reanchorWhenStill distance=\(distance) pastEnd=\(pastEnd) newestMissing=\(newestMissing) present=\(present.count) nudge=\((pastEnd || newestMissing) && present.isEmpty && nudges < 6)")
            if pastEnd || newestMissing {
                if present.isEmpty, nudges < 6 {
                    nudges += 1
                    // When the lazy stack has dropped all its rows it can stay
                    // that way whatever the scroll position is asked to do. A
                    // change of the content margin is what makes it lay them
                    // out again: a point is invisible. A few tries, so a list
                    // that never comes back doesn't toggle forever.
                    layoutNudge = layoutNudge == 0 ? 1 : 0
                    #if DEBUG
                    if abs(distance) <= 1.5 { recorder?.update { $0.nudged() } }
                    #endif
                }
                scrollToBottom(animated: false, reason: "reanchor")
            } else if let recovery = Self.blankRecovery(geometry, flipped: isFlipped, reportsRows: anyRowVisible, nudges: nudges), !followsBottom {
                // Far up the history the lazy stack revises its guess of the
                // content's height as it measures, down by half or more, and
                // the offset it left behind is then past the end, with no
                // rows there. The row the user was reading is the nearest
                // real place; the newest message is not.
                switch recovery {
                case .scrollToAnchor:
                    guard let lastReadID, items[lastReadID] != nil else { return }
                    nudges += 1
                    FrameLog.event("scroll.scrollTo blank-recovery id=\(lastReadID)")
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scroll.scrollTo(id: lastReadID, anchor: flipped(.top)) }
                case .nudge:
                    nudges += 1
                    layoutNudge = layoutNudge == 0 ? 1 : 0
                }
                // No rows may come of it either, and nothing reports then.
                reanchorWhenStill()
            }
        }
    }

    enum BlankRecovery: Equatable {
        /// Scroll to the row the user was reading.
        case scrollToAnchor
        /// Change the content margin by a point, which makes the lazy stack lay its rows out again.
        case nudge
    }

    /// What to do for a list that is at rest away from the newest end and
    /// shows no rows, if anything: take it back from past its far end, or
    /// prod the lazy stack awake. A few tries, so a list that never comes
    /// back doesn't toggle forever.
    static func blankRecovery(_ geometry: ScrollGeometry, flipped: Bool, reportsRows: Bool, nudges: Int) -> BlankRecovery? {
        guard !reportsRows, nudges < 6, geometry.contentSize.height > geometry.containerSize.height else { return nil }
        // Past the end, or after a nudge that brought nothing, the row is
        // asked for again: the lazy stack places it from guesses that the
        // first try may have changed.
        return distanceFromTop(geometry, flipped: flipped) < -1.5 || nudges % 2 == 1 ? .scrollToAnchor : .nudge
    }

    func awayFromBottomChanged(_ away: Bool) {
        guard away != isAwayFromBottom else { return }
        // A bubble growing for a frame reads as being away from the bottom.
        // Hiding is immediate; showing waits to see that it lasts.
        if !away {
            isAwayFromBottom = false
            tasks.cancel("away")
            return
        }
        tasks["away"] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, let geometry = self.geometry, Self.isAway(geometry, flipped: isFlipped) else { return }
            self.isAwayFromBottom = true
        }
    }

    static func isAway(_ geometry: ScrollGeometry, flipped: Bool) -> Bool {
        distanceFromBottom(geometry, flipped: flipped) > 120
    }

    /// How far the list is from its newest message, as the user sees it:
    /// zero at rest, negative when pulled past the end.
    static func distanceFromBottom(_ geometry: ScrollGeometry, flipped: Bool) -> CGFloat {
        // The offset is measured from the top of the content under the top
        // inset; the container is what the insets leave. Flipped, the newest
        // message is at the offset's start instead of its end.
        flipped ? startDistance(geometry) : endDistance(geometry)
    }

    /// How far the list is from its oldest loaded message, as the user sees it.
    static func distanceFromTop(_ geometry: ScrollGeometry, flipped: Bool) -> CGFloat {
        flipped ? endDistance(geometry) : startDistance(geometry)
    }

    /// The scroll offset's distance from its start.
    private static func startDistance(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }

    /// The scroll offset's distance from its end.
    private static func endDistance(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top - geometry.contentOffset.y
    }

    /// The inset at the visual top of the list, where the bars and the band
    /// above the screen are: the scroll view's bottom one when flipped.
    static func topInset(_ geometry: ScrollGeometry, flipped: Bool) -> CGFloat {
        flipped ? geometry.contentInsets.bottom : geometry.contentInsets.top
    }

    /// Whether the row is in view for want of any report: it fills the view
    /// or, on the flipped list, the lazy stack has it built, and the list rests
    /// at its end, where the newest row is. The unflipped list can be blank
    /// with rows built, so a built row says nothing there.
    private func isDrawn(_ id: Int64, atDistance distance: CGFloat) -> Bool {
        (fillingIDs.contains(id) || (isFlipped && builtIDs.contains(id))) && abs(distance) <= 1.5
    }

    private func bottomDistance(_ geometry: ScrollGeometry) -> CGFloat {
        Self.distanceFromBottom(geometry, flipped: isFlipped)
    }

    /// Exactly at the bottom, where the list follows content as it grows
    /// without being told.
    private var isAtBottomEdge: Bool {
        geometry.map { bottomDistance($0) < 1.5 } ?? true
    }

    /// Within reach of the bottom, which is also where a list that hasn't
    /// reported yet is.
    private var isNearBottom: Bool {
        geometry.map { !Self.isAway($0, flipped: isFlipped) } ?? true
    }

    func nearTopChanged(_ near: Bool) {
        isNearTop = near
        if near { loadOlderIfNeeded() }
    }

    func nearEndChanged(_ near: Bool) {
        if near { loadNewerIfNeeded() }
    }

    /// The list stopped moving: a good moment to cut a long window back.
    ///
    /// A keyboard dragged away by swiping down on the list is an interaction
    /// too, and it changes the list's room under the finger. The drag scrolls
    /// the list and the stepping inset carries the content, so the list is
    /// seldom at its edge when it settles. The swipe was meant for the
    /// keyboard, so a list that followed the bottom goes back to it.
    func scrollSettled() {
        if reanchorWaitsForSettle {
            reanchorWaitsForSettle = false
            reanchorWhenStill()
        }
        if userMoved {
            userMoved = false
            if roomChangedWhileInteracting, followedBeforeInteraction, !isBounded {
                roomChangedWhileInteracting = false
                scrollToBottom(animated: false, reason: "settled.room")
            } else {
                roomChangedWhileInteracting = false
                followsBottom = isAtBottomEdge && !isBounded
            }
        } else if followsBottom, !isAtBottomEdge {
            // An animated scroll aims at where the lazy stack guessed the
            // newest row would be, and can stop short of it.
            scrollToBottom(animated: false, reason: "settled.short")
        }
        // A list that went empty while it coasted was looked at then, when
        // it was still moving, and nothing reports an empty list again.
        if !anyRowVisible { reanchorWhenStill() }
        trimWindowIfAtBottom()
    }

    func userStartedScrolling() {
        followedBeforeInteraction = followsBottom
        nudges = 0
        roomChangedWhileInteracting = false
        userMoved = true
        followsBottom = false
        noteInteraction()
    }

    /// Scrolls to the newest row by its id rather than to the bottom edge:
    /// the edge is where the lazy stack guesses its content ends, and before
    /// it has measured the rows around it that guess can be past the real end.
    func scrollToBottom(animated: Bool, reason: StaticString = "other", byID: Bool = false) {
        guard let last = order.last else { return }
        FrameLog.event("scrollToBottom animated=\(animated) reason=\(reason)")
        followsBottom = !isBounded
        if animated {
            withAnimation { scrollToNewestRow(last, byID: byID) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollToNewestRow(last, byID: byID) }
        }
    }

    /// The edge the newest message is at.
    var newestEdge: Edge { isFlipped ? .top : .bottom }

    /// A point of a row in the visual terms of the user, as the scroll view
    /// takes it: upside down when the list is.
    private func flipped(_ anchor: UnitPoint) -> UnitPoint {
        isFlipped ? UnitPoint(x: anchor.x, y: 1 - anchor.y) : anchor
    }

    /// Takes the list to the bottom of the newest row. Flipped that is the
    /// scroll view's start, which is exact however the rows are measured; the
    /// other way round it's the row by its id, since the end is guessed.
    ///
    /// `byID` asks for the row there too. A long way off, iOS 27 takes the
    /// start in one jump to a place where the lazy stack lays out nothing it
    /// reports, and the list is left without any rows reported; the row by
    /// its id brings it in.
    private func scrollToNewestRow(_ last: Int64, byID: Bool = false) {
        if isFlipped, !byID {
            scroll.scrollTo(edge: .top)
        } else {
            scroll.scrollTo(id: last, anchor: flipped(.bottom))
        }
    }

    /// What the scroll-to-end button does: takes the list to the newest
    /// message, loading the window that ends there first if the one shown
    /// doesn't.
    func scrollToLatest() {
        #if DEBUG
        recorder?.update { $0.latestTapped() }
        #endif
        FrameLog.event("scrollToLatest bounded=\(isBounded) positioned=\(isPositioned) settling=\(jumpSettling) phase=\(scrollPhase)")
        if isBounded { showNewest() } else { scrollToBottom(animated: true, reason: "latest", byID: true) }
    }

    /// Replaces a bounded window with the newest messages, and lands at their
    /// bottom when they arrive.
    private func showNewest() {
        guard isBounded else { return }
        tasks.cancel("reveal")
        tasks.cancel("older")
        tasks.cancel("newer")
        if olderState == .loading || olderState == .complete { olderState = .idle }
        windowStart = nil
        windowEnd = nil
        pendingJump = nil
        followsBottom = true
        pendingBottom = true
        isWidening = true
        observeMessages()
    }

    /// The topmost message on screen is the one to keep still when older
    /// ones come in above it.
    func visibleChanged(_ reported: [Int64]) {
        FrameLog.event("visibleChanged count=\(reported.count) includesNewest=\(order.last.map { reported.contains($0) } ?? false)")
        reportedVisibleIDs = reported
        applyVisible()
    }

    func anyVisibleChanged(count: Int) {
        anyRowVisible = count > 0
        // The report can come after the list came to rest, when nothing else
        // looks at it again.
        if !anyRowVisible { reanchorWhenStill() }
    }

    /// Called by a row as it starts or stops covering half of what the user sees.
    func rowFillsViewChanged(_ id: Int64, _ fills: Bool) {
        if id == order.last { FrameLog.event("rowFillsViewChanged newest fills=\(fills)") }
        let changed = fills ? fillingIDs.insert(id).inserted : fillingIDs.remove(id) != nil
        if changed {
            applyVisible()
        }
    }

    /// Called by a row as the lazy stack builds it or lets it go.
    func rowBuiltChanged(_ id: Int64, _ built: Bool) {
        if built { builtIDs.insert(id) } else { builtIDs.remove(id) }
        if built, let index = orderIndex[id], index < Self.olderPrefetchRows { loadOlderIfNeeded(ignoringDistance: true) }
    }

    /// The rows the scroll view reported and the ones that fill the view, in
    /// list order.
    private var presentIDs: [Int64] {
        guard !fillingIDs.isEmpty else { return reportedVisibleIDs }
        let extra = fillingIDs.subtracting(reportedVisibleIDs)
        guard !extra.isEmpty else { return reportedVisibleIDs }
        return (reportedVisibleIDs + extra).sorted { (indexOf($0) ?? .max) < (indexOf($1) ?? .max) }
    }

    private func applyVisible() {
        let ids = presentIDs
        visibleIDs = ids
        let first = ids.min { (indexOf($0) ?? .max) < (indexOf($1) ?? .max) }
        if first != anchorID { anchorID = first }
        if let first { lastReadID = first }
        markVisibleRead()
        // Measuring the rows it builds can move the lazy stack's guess of where
        // its content ends, after the list was already held to the newest row.
        // It then keeps the new guess's bottom in view and draws nothing there.
        if ids.isEmpty { reanchorWhenStill() }
    }

    /// Called by the anchor's row with where it sits in the list.
    func anchorMeasured(id: Int64, frame: CGRect) {
        anchorFrame = (id, frame)
    }

    private func indexOf(_ id: Int64) -> Int? {
        orderIndex[id]
    }

    /// Scrolls the anchor row to the very place it is, which makes the list
    /// hold it there as rows are inserted above in the same update. The
    /// position is given as a point in the list's visible area that the row's
    /// matching point lands on, so the row doesn't shift by the part of it
    /// that was scrolled out of view.
    private func keepAnchorInPlace() {
        guard let (id, frame) = anchorFrame, id == anchorID, let geometry, items[id] != nil else { return }
        let top = geometry.contentInsets.top
        let visibleHeight = geometry.containerSize.height
        let slack = visibleHeight - frame.height
        let fraction = abs(slack) < 1 ? 0 : (frame.minY - top) / slack
        guard fraction.isFinite else { return }
        FrameLog.event("scroll.scrollTo keepAnchorInPlace id=\(id) fraction=\(fraction)")
        scroll.scrollTo(id: id, anchor: UnitPoint(x: 0.5, y: min(max(fraction, 0), 1)))
    }

    // MARK: Older messages

    func retryOlder() {
        guard olderState == .failed else { return }
        olderState = .idle
        loadOlderIfNeeded()
    }

    /// Near the top, widens the window by what's stored, and when that
    /// runs out, asks the server's archive for another page. One step at a
    /// time; each ends by looking again. `ignoringDistance` is for a page
    /// fetched ahead of the list getting there (`olderPrefetchRows`).
    private func loadOlderIfNeeded(ignoringDistance: Bool = false) {
        guard hasLoaded, !jumpSettling, tasks["older"] == nil, tasks["newer"] == nil, tasks["reveal"] == nil, tasks["quoteSearch"] == nil, pendingJump == nil, !isWidening,
              !olderWaitsForConnection, olderState == .idle, isNearTop || ignoringDistance,
              let oldest = order.first.flatMap({ items[$0] })?.cursor else { return }
        let session = session, peer = peer, growth = Self.windowGrowth, generation = generation
        let hook = olderLoadHook
        tasks["older"] = Task { [weak self] in
            // Reading the database and asking the server don't belong on the main thread.
            let step = await Task.detached(priority: .userInitiated) { () -> OlderStep in
                await hook?()
                do {
                    if let older = try session.database.olderCursor(peer: peer, before: oldest, count: growth) {
                        return .widen(older.cursor)
                    }
                    if try session.database.historyState(peer: peer).isComplete { return .complete }
                } catch {
                    return .failed
                }
                return .askServer
            }.value
            guard let self, !Task.isCancelled else { return }
            switch step {
            case .widen where self.generation != generation || self.pendingJump != nil:
                // The window was replaced meanwhile (a jump, a trim): this
                // step's start belongs to the old one.
                self.tasks.finish("older")
            case .widen(let start):
                FrameLog.event("older widen")
                self.windowStart = start
                self.isWidening = true
                self.observeMessages()
                self.tasks.finish("older")
            case .complete:
                self.olderState = .complete
                self.tasks.finish("older")
            case .failed:
                self.olderState = .failed
                self.tasks.finish("older")
            case .askServer:
                self.olderState = .loading
                await self.askServerForOlder(peer: peer)
                // A jump cancelled this step: the task that replaced it is not ours to finish.
                guard !Task.isCancelled else { return }
                self.tasks.finish("older")
                // What came back is stored: look for it, or ask again.
                if self.olderState == .loading { self.olderState = .idle }
                self.loadOlderIfNeeded()
            }
        }
    }

    /// Runs inside an older-page load, after it has started and before it
    /// reports back, so a test can hold the load while something else happens.
    @ObservationIgnored var olderLoadHook: (@Sendable () async -> Void)?

    private enum OlderStep: Sendable {
        case widen(MessageCursor)
        case askServer
        case complete
        case failed
    }

    private func askServerForOlder(peer: JID) async {
        let session = session
        do {
            _ = try await Task.detached(priority: .userInitiated) { try await session.loadOlderHistory(for: peer) }.value
        } catch HistoryError.notReady {
            // Offline, or catching up: the connection changing asks again.
            olderWaitsForConnection = true
            olderState = .idle
        } catch HistoryError.busy {
            // An earlier look at this chat is still on its way.
            olderState = .idle
            try? await Task.sleep(for: .seconds(1))
        } catch HistoryError.noArchive {
            olderState = .complete
        } catch {
            olderState = .failed
        }
    }

    /// Near the last row of a bounded window, grows it by what's stored
    /// further on; once that reaches the newest message the window is no longer
    /// bounded. One step at a time, and not while the window is being replaced.
    private func loadNewerIfNeeded() {
        // The list's own report of being near the end only says when it changed,
        // so this looks at where it is now.
        guard hasLoaded, isPositioned, !jumpSettling, isBounded, let geometry, bottomDistance(geometry) < geometry.containerSize.height * 1.5, !pendingBottom, tasks["newer"] == nil, tasks["older"] == nil, tasks["reveal"] == nil,
              pendingJump == nil, !isWidening, let newest = order.last.flatMap({ items[$0] })?.cursor else { return }
        let session = session, peer = peer, growth = Self.windowGrowth, generation = generation
        tasks["newer"] = Task { [weak self] in
            let step = await Task.detached(priority: .userInitiated) { () -> NewerStep in
                do {
                    guard let newer = try session.database.newerCursor(peer: peer, after: newest, count: growth) else { return .reachedNewest }
                    return newer.found < growth ? .reachedNewest : .extend(newer.cursor)
                } catch {
                    return .failed
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.tasks.finish("newer")
            guard self.generation == generation, self.pendingJump == nil, self.isBounded else { return }
            switch step {
            case .extend(let end): self.windowEnd = end
            case .reachedNewest: self.windowEnd = nil
            // The next scroll or change looks again.
            case .failed: return
            }
            self.isExtending = true
            self.isWidening = true
            self.observeMessages()
        }
    }

    private enum NewerStep: Sendable {
        case extend(MessageCursor)
        case reachedNewest
        case failed
    }

    /// Cuts a long window back to the newest messages once the user is
    /// there again, so every change doesn't re-read thousands of them.
    private func trimWindowIfAtBottom() {
        guard windowStart != nil, !isBounded, order.count > Self.windowLimit, isNearBottom, tasks["older"] == nil, tasks["reveal"] == nil, pendingJump == nil, !isWidening else { return }
        windowStart = nil
        isTrimming = true
        if olderState == .complete { olderState = .idle }
        observeMessages()
    }

    // MARK: Quotes

    /// Jumps to the message `id` quotes. One older than the window grows it
    /// to include it, and one we don't have is looked for in the server's
    /// archive, a few pages back.
    func scrollToQuoted(of id: Int64) {
        guard let item = items[id], let quote = item.quote, tasks["quoteSearch"] == nil else { return }
        if let target = quote.messageId {
            reveal(target)
        } else if let reference = item.message.replyToId {
            searchForQuoted(reference)
        }
    }

    /// Scrolls to `target` and highlights it, whether it is in the window or not.
    func reveal(_ target: Int64) {
        followsBottom = false
        if items[target] != nil {
            tasks.cancel("reveal")
            // The scroll may cross the near-top threshold and start loading
            // older rows, which would pin whatever row is topmost mid-flight.
            tasks.cancel("older")
            tasks.cancel("newer")
            if olderState == .loading { olderState = .idle }
            beginJumpSettling()
            FrameLog.event("scroll.scrollTo reveal id=\(target) center")
            withAnimation { scroll.scrollTo(id: target, anchor: .center) }
            flash(target)
            return
        }
        // Stored, but outside the window. A newer jump replaces an earlier
        // one, and stops a step that would change the window under it.
        tasks.cancel("older")
        tasks.cancel("newer")
        if olderState == .loading { olderState = .idle }
        let session = session, peer = peer, limit = Self.windowLimit
        tasks["reveal"] = Task { [weak self] in
            let window = await Task.detached(priority: .userInitiated) {
                try? session.database.window(peer: peer, around: target, boundedBeyond: limit)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.tasks.finish("reveal")
            guard let window else { return }
            self.windowStart = window.start
            self.windowEnd = window.end
            self.pendingJump = target
            self.isWidening = true
            self.observeMessages()
        }
    }

    private func flash(_ id: Int64) {
        tasks["flash"] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.flashID = id
            try? await Task.sleep(for: .milliseconds(400))
            if self.flashID == id { self.flashID = nil }
        }
    }

    /// How many pages of the archive a search for a quoted message reads.
    private static let quoteSearchPages = 6

    private func searchForQuoted(_ reference: String) {
        let session = session, peer = peer
        isSearching = true
        tasks["quoteSearch"] = Task { [weak self] in
            var found: Int64?
            var failure: Error?
            var pages = 0
            var isExhausted = false
            while !Task.isCancelled {
                found = await Task.detached(priority: .userInitiated) { try? session.database.referencedMessage(peer: peer, id: reference)?.id }.value
                // Once the archive has no more pages, this look was at what the last one held.
                if found != nil || pages >= Self.quoteSearchPages || isExhausted { break }
                do {
                    let more = try await Task.detached(priority: .userInitiated) { try await session.loadOlderHistory(for: peer) }.value
                    pages += 1
                    isExhausted = !more
                } catch HistoryError.busy {
                    // Scrolling back is loading too: wait for it.
                    try? await Task.sleep(for: .seconds(1))
                } catch {
                    failure = error
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.tasks.finish("quoteSearch")
            self.isSearching = false
            if let found {
                self.reveal(found)
            } else if let failure {
                self.prompt = .error(failure.localizedDescription)
            } else {
                self.prompt = .quoteNotFound
            }
            self.loadOlderIfNeeded()
        }
    }

    // MARK: Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let editing = editingItem
        // An edit only applies the edit; what is staged stays for the next message.
        let staged = editing == nil ? pendingAttachments : []
        guard !trimmed.isEmpty || !staged.isEmpty else { return }
        guard staged.isEmpty || refuseUnlessCanSend() else { return }
        // The message goes at the end, which a bounded window doesn't reach.
        if editing == nil { showNewest() }
        if editing == nil { followsOwnSend = true }
        let session = session, peer = peer
        let replying = trimmed.isEmpty ? nil : replyingTo
        if editing == nil {
            // The session counts the message as telling them we're active.
            // This comes before clearing the composer, whose change would
            // otherwise send "paused" ahead of every message.
            pausedTimer?.invalidate()
            chatState = .active
        }
        // The composer clears at once; it gets the text back if sending fails.
        // After an edit it goes back to what was being typed before it.
        composer.bar?.setText(editing == nil ? "" : takeDraft(), notify: false)
        if editing == nil, drafts.typed("", editing: false) { noteDraft() }
        noteInteraction()
        editingItem = nil
        // Staged files can't carry a reply, so it waits for the text that can.
        if !trimmed.isEmpty { replyingTo = nil }
        if editing == nil { pendingAttachments = [] }
        // Sent, so no longer a draft. After an edit the composer is back to
        // what was being typed before it, which stays the draft.
        noteDraft()
        flushDraft()
        let previous = sendTail
        // Holds the model until it's done: the user already sent these, so
        // leaving the chat mustn't drop the rest, and nothing else would
        // discard their copies once `pendingAttachments` is empty. The task
        // ends on its own, which releases the model.
        sendTail = Task { [self] in
            await previous?.value
            for item in staged {
                switch item.content {
                case .file(let file, let isPhoto): await sendFile(file, asPhoto: isPhoto, isTemporaryCopy: true)
                case .location(let location): await sendLocation(location)
                }
            }
            guard !trimmed.isEmpty else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    if let editing {
                        try session.edit(editing.message, to: trimmed)
                    } else {
                        _ = try session.send(trimmed, to: peer, replyingTo: replying?.message)
                    }
                }.value
            } catch {
                restoreComposer(text: trimmed, editing: editing, replying: replying, error: error)
            }
        }
    }

    /// Puts back what a failed send took out, unless the user has moved on:
    /// what they've typed since stays, after the text that didn't send.
    private func restoreComposer(text: String, editing: ConversationItem?, replying: ConversationItem?, error: Error) {
        if editingItem == nil && replyingTo == nil {
            editingItem = editing
            replyingTo = replying
        }
        let typed = composer.bar?.text ?? ""
        if let editing, editingItem?.id == editing.id {
            // The edit is back, and what was in the composer is the draft it displaced.
            draftBeforeEdit = typed.isEmpty ? nil : typed
            drafts.typed(typed, editing: false)
            composer.bar?.setText(text, notify: false)
        } else {
            let restored = typed.isEmpty ? text : text + "\n" + typed
            composer.bar?.setText(restored, notify: false)
            drafts.typed(restored, editing: editingItem != nil)
        }
        noteDraft()
        followsOwnSend = false
        prompt = .error(error.localizedDescription)
    }

    /// Sent as a plain message, apart from the composer. It runs within
    /// `send`'s turn on `sendTail`, so it keeps its place among the rest.
    func sendLocation(_ location: GeoLocation) async {
        let session = session, peer = peer, body = location.uri
        showNewest()
        followsOwnSend = true
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try session.send(body, to: peer)
            }.value
        } catch {
            reportSendFailure(error)
        }
    }

    /// Reading and re-encoding a big photo takes a moment; keep it off the
    /// main thread.
    ///
    /// The session copies the file into its own store before this returns, so
    /// a temporary copy made for sending (`isTemporaryCopy`) is of no use
    /// afterwards, whether it was sent or not.
    func sendFile(_ file: URL, asPhoto: Bool, isTemporaryCopy: Bool = false) async {
        let session = session, peer = peer
        showNewest()
        followsOwnSend = true
        preparingAttachments += 1
        defer {
            preparingAttachments -= 1
            if isTemporaryCopy { AttachmentPicker.discardCopy(file) }
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try await session.sendFile(at: file, asPhoto: asPhoto, to: peer)
            }.value
        } catch {
            reportSendFailure(error)
        }
    }

    func reportSendFailure(_ error: Error) {
        followsOwnSend = false
        prompt = .notice(title: String(localized: "Couldn't send"), message: error.localizedDescription)
    }

    /// Why each attachment in the alert on screen failed. Several files
    /// that fail together would otherwise replace each other's alert, and only
    /// the last would be seen.
    @ObservationIgnored private var attachFailures: [String] = []
    @ObservationIgnored private var attachFailureTitle: String?

    func reportAttachFailure(_ error: Error) {
        // Joins the alert still showing, not one the user has dismissed.
        if case .notice(let title, _)? = prompt, title == attachFailureTitle {} else { attachFailures = [] }
        attachFailures.append(error.localizedDescription)
        let title = attachFailures.count == 1
            ? String(localized: "Couldn't attach")
            : String(localized: "\(attachFailures.count) files couldn't be attached")
        var reasons: [String] = []
        for reason in attachFailures where !reasons.contains(reason) { reasons.append(reason) }
        attachFailureTitle = title
        prompt = .notice(title: title, message: reasons.joined(separator: "\n"))
    }

    /// Sends one of a message's suggested replies as the text the user typed.
    /// The composer is left as it is: a half-written message stays.
    func sendQuickResponse(_ value: String) {
        guard refuseUnlessCanSend() else { return }
        followsOwnSend = true
        write { [session, peer] in _ = try session.send(value, to: peer, replyingTo: nil) }
    }

    /// Which actions are waiting on the server, by message and action id.
    private var choosingActions: Set<ActionKey> = []

    private struct ActionKey: Hashable {
        var messageID: Int64
        var actionID: String
    }

    func isChoosingAction(_ actionID: String, on id: Int64) -> Bool {
        choosingActions.contains(ActionKey(messageID: id, actionID: actionID))
    }

    func chooseAction(_ actionID: String, on id: Int64) {
        guard let message = items[id]?.message else { return }
        let key = ActionKey(messageID: id, actionID: actionID)
        guard choosingActions.insert(key).inserted else { return }
        write({ [session] in
            try session.chooseAction(actionID, on: message)
        }, then: { [weak self] in
            self?.choosingActions.remove(key)
        }, onFailure: { [weak self] error in
            self?.choosingActions.remove(key)
            self?.prompt = .error(error.localizedDescription)
        })
    }

    func react(_ emoji: String, to id: Int64) {
        guard let item = items[id] else { return }
        let message = item.message
        // Only adding a reaction is a pick; tapping one of ours to take it back isn't.
        let isPick = !item.reactions.contains { $0.emoji == emoji && $0.includesMe }
        write({ [session, peer] in
            try session.toggleReaction(emoji, on: message, peer: peer)
            if isPick { try session.database.recordReactionPick(emoji) }
        }, then: { [weak self] in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isPick { self?.loadQuickReactions() }
        })
    }

    /// Reads the ranking off the main thread and shows its row in the next menu.
    func loadQuickReactions() {
        Task { [weak self, database = session.database] in
            let row = await Task.detached { database.reactionRanking().row(at: Date()) }.value
            self?.quickReactions = row
        }
    }

    /// Turns down a contact's file offer, or stops it if it's coming in.
    func declineOffer(_ id: Int64) {
        guard let attachment = items[id]?.attachment else { return }
        write { [session] in session.declineOffer(attachment) }
    }

    func retry(_ id: Int64) {
        guard let message = items[id]?.message else { return }
        write { [session] in try session.retry(message) }
    }

    /// Writes for something the user did, off the main thread. Each waits for
    /// the one before, so a reaction toggled twice or a message retracted
    /// right after being sent lands in that order.
    private func write(
        _ work: @escaping @Sendable () throws -> Void,
        then success: @escaping () -> Void = {},
        onFailure: ((Error) -> Void)? = nil,
    ) {
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority: .userInitiated, operation: work).value
                success()
            } catch {
                if let onFailure {
                    onFailure(error)
                } else {
                    self?.prompt = .error(error.localizedDescription)
                }
            }
        }
    }

    func explainFailure(of id: Int64) {
        prompt = .failure(id)
    }

    func failureText(of id: Int64) -> String {
        items[id]?.message.error ?? String(localized: "The message couldn't be delivered.")
    }

    func reply(to id: Int64) {
        guard let item = items[id], !item.message.isRetracted else { return }
        if editingItem != nil { cancelReplyOrEdit() }
        replyingTo = item
        composer.bar?.focus()
        // The answer goes at the bottom, and the message it answers shows
        // above the composer, so that's where the user looks next. At the
        // bottom already, the list stays there as the composer grows; an
        // animated scroll on top of that would fight it.
        if !(followsBottom && isAtBottomEdge) { scrollToLatest() }
    }

    func startEditing(_ id: Int64) {
        guard let item = items[id] else { return }
        replyingTo = nil
        if editingItem == nil { draftBeforeEdit = drafts.composerText }
        editingItem = item
        composer.bar?.setText(item.message.body, notify: false)
        composer.bar?.focus()
    }

    func cancelReplyOrEdit() {
        if editingItem != nil {
            editingItem = nil
            composer.bar?.setText(takeDraft(), notify: false)
            // An edit begun before the composer existed held the draft back,
            // and nothing else would offer it now.
            offerDraft()
        } else {
            replyingTo = nil
        }
    }

    private func takeDraft() -> String {
        defer { draftBeforeEdit = nil }
        return draftBeforeEdit ?? ""
    }

    /// Mirrors `XMPPSession.canEdit` from what the row already holds, since
    /// the session asks the database whether the message has an attachment.
    func canEdit(_ item: ConversationItem) -> Bool {
        let message = item.message
        return message.direction == .outgoing && !message.isRetracted && message.encryption != .omemoUndecryptable
            && message.id != nil && item.attachment == nil
    }

    private func updateComposerBanner() {
        guard let bar = composer.bar else { return }
        if let editingItem {
            bar.setReply((String(localized: "Edit Message"), editingItem.message.body.trimmingBlankEdgeLines))
        } else {
            bar.setReply(replyingTo.map { (authorName(for: $0.message.author), $0.quoteSummary.trimmingBlankEdgeLines) })
        }
    }

    /// Where a tapped link goes. The screen sets it to the app's handler, so
    /// `xmpp:` links are confirmed by the chat list and never handed to
    /// another app; anything else goes to the system.
    @ObservationIgnored var linkHandler: ((URL) -> Void)?

    func open(link url: URL) {
        if url.scheme?.lowercased() == "xmpp", let linkHandler {
            linkHandler(url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// What the composer holds once `body` is added: below the text already
    /// there, which stays, or alone when the composer is empty.
    nonisolated static func composerText(adding body: String, to existing: String) -> String {
        existing.isEmpty ? body : existing + "\n" + body
    }

    @ObservationIgnored private var queuedPrefill: String?

    /// Puts `body` in the open composer, as an `xmpp:` link with a body asks
    /// for. It is a draft like any other: saved, and not sent.
    func prefill(_ body: String) {
        // The stored draft isn't in the composer yet, and the body goes below it.
        guard draftOffered else {
            queuedPrefill = queuedPrefill.map { Self.composerText(adding: body, to: $0) } ?? body
            return
        }
        if editingItem != nil {
            // The composer holds the edit; the body waits with the draft it displaced.
            draftBeforeEdit = Self.composerText(adding: body, to: draftBeforeEdit ?? "")
            drafts.typed(draftBeforeEdit ?? "", editing: false)
        } else {
            let text = Self.composerText(adding: body, to: composer.bar?.text ?? drafts.composerText)
            composer.bar?.setText(text, notify: false)
            drafts.typed(text, editing: false)
        }
        noteDraft()
    }

    /// The composer came on screen: it starts out blank, so it's told what
    /// the model has been holding for it.
    func composerAttached() {
        guard let bar = composer.bar else { return }
        bar.setPreparingAttachment(preparingAttachments > 0)
        bar.setPendingAttachments(pendingAttachments)
        bar.setGifsAvailable(gifsAvailable)
        updateComposerBanner()
        // Whether this is a group isn't known until `finishStart` has read it,
        // which can be after the composer appears; `suggestMentions` checks.
        bar.onMentionQuery = { [weak self] query in self?.suggestMentions(for: query) }
        if let editingItem {
            bar.setText(editingItem.message.body, notify: false)
        } else if !drafts.composerText.isEmpty {
            bar.setText(drafts.composerText, notify: false)
        } else {
            offerDraft()
        }
    }

    /// Puts the stored draft in the composer once both are there, unless the
    /// user got to typing first or is editing a message.
    private func offerDraft() {
        guard hasReadDraft, !draftOffered, let bar = composer.bar else { return }
        draftOffered = true
        defer {
            if let body = queuedPrefill {
                queuedPrefill = nil
                prefill(body)
            }
        }
        guard let draft = storedDraft, !draft.isEmpty, editingItem == nil, drafts.composerText.isEmpty, bar.text.isEmpty else { return }
        drafts.restore(draft)
        bar.setText(draft, notify: false)
    }

    /// Notes what the composer holds as the draft and saves it a moment after
    /// the typing stops.
    private func noteDraft() {
        guard drafts.isDirty else { return }
        // Before the write, so a chat reopened in the meantime finds it.
        DraftWriter.shared.note(drafts.draftText, for: peer)
        tasks["draft"] = Task { [weak self] in
            try? await Task.sleep(for: Self.draftDelay)
            guard let self, !Task.isCancelled else { return }
            tasks.finish("draft")
            flushDraft()
        }
    }

    /// Writes the draft now if it changed. Off the main thread, one write
    /// after the other, so an older text can't land over a newer.
    private func flushDraft() {
        tasks.cancel("draft")
        guard let text = drafts.flush() else { return }
        DraftWriter.shared.save(text, for: peer, to: session.database)
    }

    func confirmRetraction(of id: Int64) {
        prompt = .confirmRetraction(id)
    }

    /// A group's moderator may take other people's messages back (XEP-0425),
    /// if the room offers it.
    func canModerate(_ message: Message) -> Bool {
        isGroup && session.canRetractForEveryone(message, in: peer)
    }

    func confirmModeration(of id: Int64) {
        prompt = .confirmModeration(id)
    }

    /// Asks the room, which can say no, so it shows progress and reports a failure.
    func removeForEveryone(_ id: Int64) {
        guard let message = items[id]?.message, !isRemovingForEveryone else { return }
        isRemovingForEveryone = true
        Task { [session] in
            do {
                try await session.retractForEveryone(message)
            } catch {
                prompt = .error(error.localizedDescription)
            }
            isRemovingForEveryone = false
        }
    }

    func retract(_ id: Int64) {
        guard let message = items[id]?.message else { return }
        write({ [session] in
            try session.retract(message)
        }, then: { [weak self] in
            if self?.editingItem?.id == id { self?.cancelReplyOrEdit() }
        })
    }

    func showReactions(for id: Int64) {
        prompt = .reactions(id)
    }

    /// Who reacted how, for the sheet that lists them.
    func reactionChoices(for id: Int64) -> [(emoji: String, names: String, includesMe: Bool)] {
        (items[id]?.reactions ?? []).map { group in
            (group.emoji, group.senders.map(authorName(for:)).joined(separator: ", "), group.includesMe)
        }
    }

    // MARK: Attachments

    func attachmentTapped(_ id: Int64) {
        guard let attachment = items[id]?.attachment, !transfers.isTransferring(id) else { return }
        switch attachment.state {
        case .remote, .downloadFailed, .offered:
            session.download(attachment)
        case .unavailable:
            break
        case .ready, .pendingUpload:
            if let file = session.attachments.url(for: attachment) {
                QuickLookPresenter.show(file, title: attachment.name, from: id)
            }
        }
    }

    /// The device an encrypted message came from, while we still know it.
    /// Read from a cache, as the key store is in the database: a sender not
    /// seen yet is loaded in the background, and the menu shows the device
    /// once it has.
    func sendingDevice(of message: Message) -> OMEMODevice? {
        guard message.direction == .incoming, message.encryption == .omemo, let id = message.omemoDevice else { return nil }
        guard let devices = senderDevices[message.sender] else {
            loadDevices(of: message.sender)
            return nil
        }
        return devices.first { $0.id == id }
    }

    private func loadDevices(of jid: JID) {
        guard loadingDevices.insert(jid).inserted else { return }
        Task { [session, weak self] in
            let devices = await Task.detached(priority: .userInitiated) { session.devices(of: jid) }.value
            guard let self else { return }
            loadingDevices.remove(jid)
            if senderDevices[jid] != devices { senderDevices[jid] = devices }
        }
    }

    func setTrust(_ trust: OMEMODevice.Trust, for device: OMEMODevice) {
        // It reads and writes the key store and the database.
        write({ [session] in session.setTrust(trust, for: device) }, then: { [weak self] in
            self?.loadDevices(of: device.jid)
        })
    }

    func shareableFile(of item: ConversationItem) -> URL? {
        guard let attachment = item.attachment, attachment.localFile != nil else { return nil }
        return session.attachments.url(for: attachment)
    }

    // MARK: Reading

    func setOnScreen(_ onScreen: Bool) {
        isOnScreen = onScreen
        if onScreen {
            markVisibleRead()
            if UIApplication.shared.applicationState == .active { becomeActive() }
        } else {
            becomeInactive()
            flushDraft()
        }
    }

    /// Reads what the user can see: up to the newest incoming message that's
    /// mostly on screen, while this chat is in front and its window has focus.
    /// Messages below stay unread until they're scrolled to. Nothing is read
    /// while the list is still being taken to the first unread message, as
    /// the rows it reports then aren't the ones the user will see.
    func markVisibleRead() {
        guard hasLoaded, isPositioned, isOnScreen, UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              let message = newestVisibleUnread() else { return }
        if message.timestamp > (readRequestedThrough ?? .distantPast) {
            readRequestedThrough = message.timestamp
            pendingRead = message
        } else if let id = message.id, !lateReadRequested.contains(id) {
            // It arrived after we'd read past its time (archive catch-up, room
            // history). Marking it read is only local: the marker we sent for
            // a newer message already covers it, and one for this message
            // would move the read point back for the peer and our devices.
            lateReadRequested.insert(id)
            pendingLateRead = message
        } else {
            return
        }
        markRead()
    }

    /// The newest unread incoming message that's mostly on screen. The
    /// list reports the messages with at least half of them showing.
    private func newestVisibleUnread() -> Message? {
        guard unreadCount > 0 else { return nil }
        var newest: (index: Int, message: Message)?
        for id in visibleIDs {
            guard let index = orderIndex[id], index > (newest?.index ?? -1),
                  let message = items[id]?.message, message.direction == .incoming, !message.isRead else { continue }
            newest = (index, message)
        }
        return newest?.message
    }

    /// Marking is a write, and scrolling asks for it again and again: off the
    /// main thread, and once for all that was asked meanwhile, which only
    /// matters for the newest message.
    private func markRead() {
        guard marking == nil else { return }
        let session = session
        marking = Task {
            while pendingRead != nil || pendingLateRead != nil {
                if let message = pendingRead {
                    pendingRead = nil
                    let succeeded = await Task.detached(priority: .utility) {
                        guard let conversation = try? session.database.reader.read({ try Conversation.fetchOne($0, key: message.conversationId) }) else { return false }
                        return (try? session.markRead(conversation, through: message)) != nil
                    }.value
                    // Asking again for the same message has to be possible.
                    if !succeeded { readRequestedThrough = nil }
                }
                if let message = pendingLateRead {
                    pendingLateRead = nil
                    let succeeded = await Task.detached(priority: .utility) {
                        (try? session.database.markRead(conversationId: message.conversationId, through: message.timestamp)) != nil
                    }.value
                    if !succeeded, let id = message.id { lateReadRequested.remove(id) }
                }
            }
            marking = nil
        }
    }

    func sceneActivated() {
        markVisibleRead()
    }

    func appBecameActive() {
        if isOnScreen { becomeActive() }
        markVisibleRead()
    }

    func appWillResignActive() {
        if isOnScreen { becomeInactive() }
    }

    // MARK: Chat states

    func textChanged(_ text: String) {
        // An edit's text isn't a draft; what was there before it stays.
        if drafts.typed(text, editing: editingItem != nil) { noteDraft() }
        guard isOnScreen else { return }
        noteInteraction()
        pausedTimer?.invalidate()
        if text.isEmpty {
            setChatState(.paused)
        } else {
            setChatState(.composing)
            pausedTimer = Timer.scheduledTimer(withTimeInterval: Self.pausedDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setChatState(.paused) }
            }
        }
    }

    /// The chat is in front of the user: looking at it, until they go quiet.
    private func becomeActive() {
        setChatState(.active)
        restartIdleTimer()
    }

    /// The user has left the chat or the app, so nothing can be pending.
    private func becomeInactive() {
        pausedTimer?.invalidate()
        idleTimer?.invalidate()
        setChatState(.inactive)
    }

    /// Typing and scrolling show we're here, which matters after the idle
    /// timer has said otherwise.
    private func noteInteraction() {
        guard isOnScreen else { return }
        if chatState == .inactive { setChatState(.active) }
        restartIdleTimer()
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.becomeInactive() }
        }
    }

    private func setChatState(_ state: InboundMessage.ChatState) {
        // Paused only follows typing; the session would drop it anyway.
        guard state != chatState, state != .paused || chatState == .composing else { return }
        chatState = state
        // The session reads the roster and a setting, so this is off the main
        // thread. Each waits for the one before, which keeps the states in the
        // order they were set: the session drops "paused" unless "composing"
        // was sent first.
        let previous = chatStateTail
        chatStateTail = Task { [session, peer] in
            await previous?.value
            await Task.detached(priority: .userInitiated) { session.sendChatState(state, to: peer) }.value
        }
    }

    /// Who's in the group whose nickname starts with what follows the "@".
    private func suggestMentions(for query: String?) {
        guard isGroup, let query, let status = session.roomStatus(peer) else {
            composer.bar?.setSuggestions([])
            return
        }
        let nicks = status.occupants.keys
            .filter { $0 != status.nickname && (query.isEmpty || $0.range(of: query, options: [.caseInsensitive, .anchored]) != nil) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        composer.bar?.setSuggestions(Array(nicks.prefix(8)))
    }
}

/// The composer, which is UIKit, as the model reaches it.
@MainActor
final class ComposerHandle {
    weak var bar: ConversationInputBar?
}
