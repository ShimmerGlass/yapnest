import Combine
import CryptoKit
import Foundation
import Network
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import os

/// One account's connection: keeps the database in sync with the server and
/// sends what the UI asks for.
///
/// Martin delivers stanzas on its own queues; everything here is either
/// immutable, goes through the (thread-safe) database, or is guarded by `lock`.
public final class XMPPSession: @unchecked Sendable {
    public struct Credentials: Sendable {
        public var jid: JID
        public var password: String
        /// Overrides SRV lookup.
        public var host: String?
        public var port: Int?
        /// Skips STARTTLS. Only for local development servers.
        public var disableTLS: Bool
        /// The new password of a change whose outcome the app never learned
        /// (the request timed out or the connection dropped). Tried once if the
        /// sign-in with `password` is refused.
        public var candidatePassword: String?

        public init(jid: JID, password: String, host: String? = nil, port: Int? = nil, disableTLS: Bool = false, candidatePassword: String? = nil) {
            self.jid = jid
            self.password = password
            self.candidatePassword = candidatePassword
            self.host = host
            self.port = port
            self.disableTLS = disableTLS
        }

        /// These credentials once a sign-in has shown `password` to be the
        /// account's: it is kept, and the candidate dropped.
        public func confirming(_ password: String) -> Credentials {
            var confirmed = self
            confirmed.password = password
            confirmed.candidatePassword = nil
            return confirmed
        }
    }

    public enum State: Sendable, Equatable {
        /// `error` describes why the last connection attempt dropped, if known.
        case disconnected(error: String?)
        case connecting
        /// Connected; `isSyncing` while catching up on the archive.
        case connected(isSyncing: Bool)
        case failed(String)

        /// Which case it is, without the error text, so it's safe to log.
        public var caseName: String {
            switch self {
            case .disconnected: "disconnected"
            case .connecting: "connecting"
            case .connected: "connected"
            case .failed: "failed"
            }
        }
    }

    /// What the session is for.
    public enum Mode: Sendable {
        /// The app's own: present, in its groups, sending.
        case app
        /// The notification extension's: catches up on what arrived without
        /// telling anyone it's here, so the server keeps pushing to the app's
        /// session (see `catchUpOnce`).
        case notificationService
        /// The share extension's: connects to send what was shared and
        /// disconnects. Like the notification extension's it stays out of
        /// presence and carbons, and it skips the catch-up too, as it only
        /// writes (see `ShareSender`).
        case share
    }

    public enum Event: Sendable {
        case newMessage(Message)
        /// An incoming correction was applied to a message we hold.
        case editedMessage(Message)
        case chatState(JID, InboundMessage.ChatState)
        /// A group invitation is waiting for the user's answer, to be notified about.
        case invitationHeld
    }

    public let account: JID
    public let database: AppDatabase
    public let mode: Mode
    let policy: Policy
    let resumeTickets: ResumeTicketStore?
    /// What an extension on the app's stream keeps of it for the app (`ResumeJournal`).
    let journal: ResumeJournal?
    /// What an extension's wake read from the stream, by kind, logged as it leaves (`StreamTally`).
    let streamTally = StreamTally()
    /// The XEP-0357 app server that wakes this device.
    let pushRelay: JID
    public let state = CurrentValueSubject<State, Never>(.disconnected(error: nil))
    /// Whether a liveness check has been sent and neither answered nor given
    /// up on: a request written then may go down a dead stream.
    let livenessPending = CurrentValueSubject<Bool, Never>(false)
    public let events = PassthroughSubject<Event, Never>()
    /// How the room answered a subject change, which only comes back as a
    /// message: its echo, or an error.
    let subjectOutcomes = PassthroughSubject<SubjectOutcome, Never>()
    /// What went wrong on this account that the user should hear of, shown above the chat list.
    public let warnings = AccountWarnings()
    /// Contacts who are online with a device we can call (`canCall`), which
    /// becomes known when the device's capabilities arrive, after its presence.
    /// Always empty in a session without media.
    public let callablePeers = CurrentValueSubject<Set<JID>, Never>([])
    /// The callable peers whose same device can also take video.
    public let videoCallablePeers = CurrentValueSubject<Set<JID>, Never>([])
    public let avatars: AvatarStore
    public let attachments: AttachmentStore
    let fileHasher = FileHasher()
    /// Development servers without TLS serve encrypted files over plain HTTP too.
    let allowsInsecureTransfers: Bool
    /// This client's XEP-0484 token, for signing in without the password.
    let fastTokens: FastTokenStore
    /// The strongest sign-in that has worked, which none may fall below.
    let signInRecords: SignInRecordStore
    /// Where `setAway`'s presences go out, one after the other.
    let presenceQueue = DispatchQueue(label: "Yapnest.presence", qos: .userInitiated)
    /// Progress (0...1) of uploads and downloads under way, by message id.
    public let transfers = CurrentValueSubject<[Int64: Double], Never>([:])
    /// Group chats we're joining or in on this connection.
    public let rooms = CurrentValueSubject<[JID: RoomStatus], Never>([:])
    /// Each change to one room's state as it's published, with nil for a room
    /// that's gone. The app follows this rather than `rooms`, as handing it
    /// whole dictionaries would have it compare every room at every change.
    public let roomUpdates = PassthroughSubject<RoomUpdate, Never>()
    /// Each change to one contact's availability or status as it's published,
    /// with a nil presence once the session has none for them. The app follows
    /// this rather than whole tables, as comparing every contact's at each
    /// presence cost the square of their number at sign-in.
    public let peerUpdates = PassthroughSubject<PeerUpdate, Never>()
    /// The call under way, or the one that just ended, until the next. Nil in
    /// sessions without media, and before the first call.
    public let callState = CurrentValueSubject<CallState?, Never>(nil)
    /// Makes the media of each call. Without it, the session offers no calls.
    let callMedia: (any CallMediaFactory)?
    /// What encrypts and decrypts a call's fingerprints, in place of OMEMO's
    /// when a test wants to supply the keys.
    var callCipherForTesting: CallFingerprintCipher?

    let client = XMPPClient()
    let omemo: OMEMOEncryption
    let logger = Logger(subsystem: "Yapnest", category: "XMPPSession")
    let lock = OSAllocatedUnfairLock(initialState: Mutable())
    /// Keeps the sender's choice of the next block change and its marking as
    /// in flight, and a queued change's check of that mark, from interleaving.
    let blockQueueLock = NSLock()
    /// Runs in the sender between choosing a block change and marking it as
    /// in flight, for tests to make a change at that moment.
    var afterBlockChangeChosenForTesting: (@Sendable () -> Void)?
    /// The same for the queued roster changes: the sender's choice of the
    /// next one and its marking as in flight, and a queued change's check of it.
    let rosterQueueLock = NSLock()
    var afterRosterChangeChosenForTesting: (@Sendable () -> Void)?
    /// One change of the old bookmarks at a time, each reading the list and writing it back. The
    /// session's own: a queue shared by every session would make one that waits out a timeout
    /// hold up all the others.
    let legacyBookmarkQueue = DispatchQueue(label: "Yapnest.XMPPSession.legacyBookmarks")
    /// Where `connect()` settles the resume ticket and logs in, off the caller's thread.
    let loginQueue = DispatchQueue(label: "Yapnest.XMPPSession.login")
    /// Where the app's ticket is written, read and removed, so that one written as the stream moves on
    /// (`keepTicketCurrent`) can't land after the suspension's or the settling's.
    private let ticketQueue = DispatchQueue(label: "Yapnest.XMPPSession.ticket")
    /// Orders what `reportClientState` decides and writes.
    private let clientStateLock = NSLock()
    /// Keep a snapshot's sends in the order the snapshots were built: see
    /// `publish`. One per subject, so unrelated subjects don't wait on each other.
    let roomsPublishLock = NSRecursiveLock()
    let transfersPublishLock = NSRecursiveLock()
    let presencesPublishLock = NSRecursiveLock()
    let callPublishLock = NSRecursiveLock()
    let callablePublishLock = NSRecursiveLock()
    /// Where caps results update `callablePeers`, one run for however many
    /// arrived meanwhile.
    let callableQueue = DispatchQueue(label: "Yapnest.callable")
    let occupantQueue = DispatchQueue(label: "Yapnest.occupants")
    /// How long occupants' presences are gathered before they are applied.
    var occupantWindow: TimeInterval = 0.05
    /// Runs the count of who is in each group: see `XMPPSession+Roster.swift`.
    let rosterQueue = DispatchQueue(label: "Yapnest.roster")
    /// Touched only on `rosterQueue`.
    let rosterRemovals = RosterRemovals()
    let callableUpdatePending = OSAllocatedUnfairLock(initialState: false)
    /// The relays found for calls.
    let iceServerCache = IceServerCache()
    /// File transfers over Jingle, live only (see `FileTransferSession`).
    let fileTransfers = FileTransfers()
    /// Runs what a call's machine asks for, in the order it asked.
    let callQueue = DispatchQueue(label: "Yapnest.calls")

    /// Builds a snapshot under `lock` and sends it, in one step per
    /// `publishLock`. Two updates from different threads could otherwise build
    /// A then B and send B then A, leaving the stale one as the last value.
    /// The state lock is released before sending, as subscribers run
    /// arbitrary code that may call back into the session; the publishing
    /// lock is recursive for the same reason. Nothing may take a publishing
    /// lock while holding `lock`. `build` returns what to hand back, and the
    /// snapshot to send, or nil to send nothing. `after` runs under the
    /// publishing lock once the snapshot is sent, for what must follow it in
    /// the same order.
    @discardableResult
    func publish<Value, Result>(
        _ subject: CurrentValueSubject<Value, Never>,
        under publishLock: NSRecursiveLock,
        after: (Result) -> Void = { _ in },
        _ build: (inout Mutable) -> (result: Result, snapshot: Value?),
    ) -> Result {
        publishLock.lock()
        defer { publishLock.unlock() }
        let (result, snapshot) = lock.withLockUnchecked { build(&$0) }
        if let snapshot { subject.send(snapshot) }
        after(result)
        return result
    }
    private var cancellables = Set<AnyCancellable>()
    private var pathMonitor: NWPathMonitor?

    /// Holds a Combine subscription in `Mutable`, which must be Sendable.
    final class SubscriptionBox: @unchecked Sendable {
        let subscription: AnyCancellable
        init(_ subscription: AnyCancellable) { self.subscription = subscription }
    }

    struct Probation {
        var id: String
        var token: Int
    }

    /// A run that coalesces the requests made while it goes: however many
    /// ask, one runner goes round until nobody asked during its last round.
    /// A round starts with `beginRound`, which absorbs the requests made so
    /// far, since it is about to read the work they are about. Otherwise a
    /// request made just before the round would leave a second, needless one.
    struct CoalescedRun {
        private enum Phase { case idle, running, runAgain }
        private var phase = Phase.idle
        /// The runner, for a caller that waits for it.
        var task: Task<Void, Never>?

        /// True when no runner goes, so the caller starts one.
        mutating func request() -> Bool {
            defer { phase = phase == .idle ? .running : .runAgain }
            return phase == .idle
        }

        mutating func beginRound() { phase = .running }

        /// True when a request came during the round, so another follows.
        mutating func endRound() -> Bool {
            if phase == .runAgain {
                phase = .running
                return true
            }
            phase = .idle
            task = nil
            return false
        }
    }

    /// Starts the runner of `run` going round, or has the one under way go
    /// round again, and returns it. Weak, so a session that is gone ends it.
    @discardableResult
    func coalesced(
        _ run: WritableKeyPath<Mutable, CoalescedRun> & Sendable,
        priority: TaskPriority? = nil,
        round: @escaping @Sendable (XMPPSession) async -> Void
    ) -> Task<Void, Never> {
        lock.withLock { state in
            guard state[keyPath: run].request() else { return state[keyPath: run].task! }
            // Created under the lock, which the runner takes first, so it
            // can't finish before it is kept here.
            let task = Task(priority: priority) { [weak self] in
                while let self {
                    lock.withLock { $0[keyPath: run].beginRound() }
                    await round(self)
                    guard lock.withLock({ $0[keyPath: run].endRound() }) else { return }
                }
            }
            state[keyPath: run].task = task
            return task
        }
    }

    struct Mutable {
        var isSyncing = false
        var heldRun = CoalescedRun()
        /// What the send queues have taken up, and edits made before that.
        var sends = SendClaims()
        /// The stanzas of reactions, corrections and retractions written this
        /// session and not yet acknowledged, so none is written twice.
        var pendingStanzas = PendingLedger()
        /// Who the errors that bounce our stanzas belong to.
        var bounces = BounceRouter()
        /// Stanzas a passing bounce made pending again, until they are written
        /// again. The server's acknowledgement of the earlier write may still
        /// come, and must not undo that.
        var repended: Set<String> = []
        /// How long a bounce that may pass waits before the item is sent again;
        /// doubled for each time it bounces.
        var bounceBackoff: TimeInterval = 5
        /// The wait before `retryingPassingErrors` makes a request again; tests lower it.
        var retryBackoff: TimeInterval = ServerRetry.backoff
        /// How long `setSubject` waits for the room's echo; tests lower it.
        var subjectTimeout: TimeInterval = XMPPSession.subjectTimeout
        /// A password that may be the account's now (see `Credentials.candidatePassword`).
        var candidatePassword: String?
        /// The candidate is in the connection's configuration, in place of the stored password.
        var usesCandidate = false
        /// The candidate has been tried, so a second refusal is final.
        var triedCandidate = false
        /// Told which password a new session signed in with, when a candidate was in play.
        var passwordConfirmed: (@Sendable (_ password: String, _ wasCandidate: Bool) -> Void)?
        /// How many times the server closed the stream with an error while a stanza of ours,
        /// by its id, was the oldest it hadn't acknowledged. An acknowledgement clears it.
        /// Kept across reconnects: that is where the count comes from.
        var streamErrorStrikes: [String: Int] = [:]
        /// The stanza with a strike that the session is sending alone, with everything else held
        /// until it is acknowledged, gives the stream error again, or the wait is over.
        var probation: Probation?
        var probationToken = 0
        /// How long it is sent alone before the rest follows regardless: what a ping for
        /// confirmation waits, past which it is as good as unanswered. Holding everything else
        /// for good would be worse than the strike it avoids.
        var probationTimeout = XMPPSession.confirmationTimeout
        /// Whether we should be connected; drives automatic reconnection.
        var wantsConnection = false
        /// The generation of the resume ticket the app saved as it suspended:
        /// a ticket of another is one an extension wrote, which used the stream.
        var savedTicketGeneration: UInt64?
        /// The stream as last acknowledged, waiting to be written to the ticket; a write already queued
        /// takes the newest one.
        var pendingTicket: StreamManagementModule.Snapshot?
        /// The ticket is the app's to keep current: from this connection's settling, which takes whatever
        /// an extension left, to the suspension. An ack the closing stream still reads after that, while
        /// the user returns, would otherwise write over a ticket an extension saved meanwhile.
        var ticketFollowsStream = false
        /// The groups an extension's stream delivered something from, whose archives its catch-up reads.
        var roomsHeardLive: Set<JID> = []
        /// What an extension kept of the stream while the app was away (`ResumeJournal`), until it is replayed
        /// into the resumed stream, or its calls are rung for in a new session.
        var journaled: [JournalEntry] = []
        /// The app's stream was adopted from the ticket, so the journal belongs in it.
        var replaysJournal = false
        /// The stream an extension's session was given to resume, until it knows whether the server took it.
        var seededStreamId: String?
        /// What the ticket it was given said of the earlier wakes: the app's count of what arrived, and
        /// whether their journal is incomplete, which this wake's ticket carries on.
        var seededAppHandled: UInt32?
        var seededJournalLost = false
        /// The session was on a stream at some point, so what its counters say is the stream's.
        var reachedStream = false
        /// The `h` of the first `<resumed>` of the app's stream in this process, which says how many of the
        /// app's own stanzas had arrived by then. A drop and a second resume in the same wake would
        /// move the stream's own `resumedH` on, to a count that includes this wake's stanzas.
        var firstResumedH: UInt32?
        /// The app's session has been asked to connect since it last saved the ticket, so it has the
        /// session lock and the stream is its own to leave: what `saveResumeTicket` may write. A session
        /// that never connected (the app opened while an extension held the lock, or woken in the
        /// background, which doesn't connect) knows nothing the ticket and journal don't.
        var holdsStream = false
        /// The extension's first resumed stream has started its catch-up, which a
        /// resumed stream doesn't start by itself.
        var resumedCatchUpStarted = false
        var reconnectAttempt = 0
        /// Identifies the pending backoff timer, so one that a path change
        /// overtook doesn't log in again later.
        var reconnectToken = 0
        /// Set when a path change dropped an attempt, so the drop reconnects
        /// at once instead of backing off.
        var retryNow = false
        /// Counts connection attempts, so a stale watchdog can tell it's stale.
        var attempt = 0
        /// When the login in flight began, for the durations in the diagnostics log.
        var connectStartedAt: Date?
        /// Waits for the connector to come up, to start the watchdog.
        var watchdogSubscription: SubscriptionBox?
        /// Set when the connection dropped under the account's catch-up, which
        /// a resumed stream doesn't start again; `resumeInterruptedCatchUps`
        /// does.
        var catchUpInterrupted = false
        /// Rooms whose catch-up was cut off the same way.
        var interruptedRooms: Set<JID> = []
        /// Rooms we left while the stream was down, with the nickname we were in
        /// them under. A resumed stream still has our presence there, and tells
        /// them we're gone; a new one has lost it.
        var withdrawnWhileDown: [JID: String] = [:]
        /// The introduction of this device written to a room and not yet
        /// echoed back, with the members it holds keys for.
        var pendingIntroductions: [JID: PendingIntroduction] = [:]
        /// When a member was last introduced to again, by room and member.
        var reintroductions: [String: Date] = [:]
        /// Why we're tearing the connection down ourselves, which Martin
        /// would otherwise report as a plain disconnect.
        var pendingFailure: Failure?
        /// The (address, hash) pairs of photos asked for with a vCard, kept
        /// whether or not the answer was usable.
        var vCardAvatarAttempts: Set<String> = []
        /// The chats whose avatar was asked for because they began today.
        var avatarsAskedAtStart: Set<JID> = []
        /// Each contact's connected resources and what they say.
        var resources: [JID: [String: ResourcePresence]] = [:]
        /// Orders resources' presences, so of equally available ones the
        /// newest speaks for the contact.
        var presenceCounter = 0
        /// The server's XEP-0363 service, once discovered on this connection.
        var uploadService: UploadService?
        /// Messages whose file is being uploaded or downloaded.
        var transferProgress: [Int64: Double] = [:]
        /// Group chats' live state, by room.
        var rooms: [JID: RoomStatus] = [:]
        /// Occupants' arrivals and departures not yet applied to `rooms`: a
        /// room sends everyone present on joining, and applying each at once
        /// copied the room's state every time.
        var pendingOccupantChanges: [JID: [OccupantChange]] = [:]
        var occupantDrainScheduled = false
        /// Every group chat we have a conversation for, joined or not, so
        /// their stanzas aren't taken for 1:1 ones.
        var knownRooms: Set<JID> = []
        /// Automatic rejoins of failed rooms that are waiting, and how many
        /// have been tried since each room last worked.
        var rejoinTasks: [JID: Task<Void, Never>] = [:]
        var rejoinAttempts: [JID: Int] = [:]
        /// Posts a warning for each new device of ours until the session ends.
        var ownDeviceNoticeTask: Task<Void, Never>?
        /// Device lists heard and not yet recorded, the JIDs whose first list
        /// is recorded, and whether a run is recording them: see `deviceListHeard`.
        var deviceListsHeard: [String: [Int32]] = [:]
        var deviceListsNoted: Set<String> = []
        var isNotingDeviceLists = false
        /// The server's group chat service, once discovered on this connection.
        var mucService: String?
        /// A new session waits for account discovery before catching up.
        var awaitsAccountDiscovery = false
        /// The server's clock less ours, read from the database on first use
        /// and kept current as the server's answer is recorded: see
        /// `XMPPSession+ServerClock`.
        var clockOffset: TimeInterval?
        var clockEstimate: Task<Void, Never>?
        /// What a resumed stream does again, as nothing else would before the
        /// next new session; a new session does all of it itself.
        var owedOnResume: OwedOnResume = []
        /// The archive version our server speaks, from account discovery.
        var archiveVersion: MessageArchiveManagementModule.Version?
        /// The run sending queued blocks and unblocks.
        var blockRun = CoalescedRun()
        /// The person whose block or unblock is on its way to the server.
        var blockInFlight: JID?
        /// The run sending queued roster changes, and the one on its way to the server.
        var rosterRun = CoalescedRun()
        var rosterInFlight: Int64?
        /// A new session's roster hasn't arrived yet. The queued changes wait
        /// for it, as removing and renaming need the item and accepting
        /// checks the request against it. A read that fails ends the wait.
        var awaitsRoster = false
        /// The run sending the bookmarks we owe, and the task doing it.
        var bookmarkRun = CoalescedRun()
        /// The run sending our avatar and name changes, and the task doing it.
        var profileRun = CoalescedRun()
        /// By warning key, what the server refused for good, until the user's
        /// Retry asks about it (bookmarks, profile, roster changes, blocks).
        var refusals: [String: Error] = [:]
        /// The run publishing the read states owed, and the task doing it.
        var readStateRun = CoalescedRun()
        /// Fetches of the read states under way. While one is, what the server
        /// holds is not all known, so nothing is published.
        var displayedFetches = 0
        /// The last read message the server holds for each chat, as far as we
        /// know (XEP-0490): from our publishes, the fetch and notifications.
        var publishedDisplayed: [JID: String] = [:]
        /// Chats owing a read state while the state the server holds names a
        /// message we haven't stored. Storing a message for one starts a round.
        var readStatesAwaitingMessage: Set<JID> = []
        /// Reconfigurations of a PEP node under way, so publishes that all
        /// meet the same refusal ask the server once. See `configurePEPNode`.
        var nodeReconfigurations: [NodeConfiguration: (id: UUID, task: Task<Void, Error>)] = [:]
        /// Where our settings node stands this session: see `SettingsSyncState`.
        var settingsSync = SettingsSyncState()
        /// Contact requests the server sent on this session.
        var repeatedContactRequests: Set<JID> = []
        /// Whether those are all the server has: a new session's initial
        /// presence makes it send every unanswered one.
        var prunesContactRequests = false
        /// Whether the user is looking at the app (XEP-0352). A new session
        /// starts active on the server's side.
        var isActive = true
        /// Whether the Mac's screen is locked. Only the client state looks at
        /// it: the Mac is "active" otherwise, whatever the window is doing.
        var isScreenLocked = false
        /// When the user left the app (XEP-0012's idle time); nil while in it.
        var idleSince: Date?
        /// What the server may be holding back while we're inactive.
        var held = HeldNotifications()
        /// Whether the user isn't there, which shows us away: see `setAway`.
        var isAway = false
        /// The seconds since the user last touched the machine, where the app
        /// can tell, in place of `idleSince`.
        var idleSource: (@Sendable () -> TimeInterval)?
        /// When contacts' last seen was last asked for.
        var lastSeenSchedule = LastSeenSchedule()
        /// The liveness check in flight, so one runs at a time.
        var livenessCheck: UUID?
        /// How long an action that needs the connection waits for it to come
        /// back before it fails as offline. Tests shrink it.
        var connectionGrace: TimeInterval = XMPPSession.defaultConnectionGrace
        /// How long a call waits for the peer's presence and capabilities,
        /// which come back some moments after a new session. Tests shrink it.
        var callablePeerGrace: TimeInterval = XMPPSession.defaultCallablePeerGrace
        /// Chat states (XEP-0085) by contact.
        var chatStates: [JID: ChatStateTracker] = [:]
        /// Archive results of the pages being fetched, each stored with the
        /// rest of its query's page when that ends. Queries run at once, so
        /// each result says which one it belongs to.
        var archiveBuffer: [ArchivedInbound] = []
        /// Calls signalled in those messages, applied after them.
        var archivedCallSignals: [ArchivedCallSignal] = []
        /// The live call signals an extension read, for `ringForIncomingCalls`.
        var heardCallSignals: [CallSignal] = []
        /// The calls that function told the caller about.
        var incomingCalls: [IncomingCall] = []
        /// Queries whose results were dropped by a flush in the middle of a
        /// page, so the page's end must not count as stored.
        var failedArchiveQueries: Set<String> = []
        /// Ids of the queries for older history, whose results are stored
        /// quietly.
        var historyQueries: Set<String> = []
        /// Chats whose older history is being fetched.
        var historyLoading: Set<JID> = []
        /// Each chat's outgoing messages go out one at a time, in order,
        /// since encrypting one may wait on the network. Chats don't wait
        /// on each other.
        var sendQueues: [JID: DispatchQueue] = [:]
        /// Edits, retractions and reactions waiting for their room to be ready.
        var deferredSends: [JID: [@Sendable () -> Void]] = [:]
        /// The last message we sent each contact a displayed marker for.
        var sentDisplayed: [JID: String] = [:]
        /// The call under way, or the last one.
        var call: ActiveCall?
        /// Messages that end a call, which couldn't be written, for when the
        /// stream is back.
        var unsentCallMessages: [UnsentCallMessage] = []
    }

    /// An archived message parsed and decrypted, waiting to be stored, and
    /// what to do once it is.
    struct ArchivedInbound {
        var query: String
        var inbound: InboundMessage
        var stored: @Sendable (IngestResult) -> Void
    }

    struct ArchivedCallSignal {
        var query: String
        var signal: CallSignal
        var isHistory: Bool
    }

    enum Failure {
        /// Retrying won't help until the user changes something.
        case fatal(String)
        case transient(String)
    }

    /// How long a server may take, once the connection is up, to bind a session.
    /// Before that, Martin bounds each endpoint it tries by its own timeout.
    static let connectTimeout: TimeInterval = 30

    /// How long a ping that stands in for an acknowledgement may take.
    static let confirmationTimeout: TimeInterval = 30
    /// How many pings are sent, one after another, for the server to confirm a stanza without stream management.
    static let confirmationPings = 2

    /// How far back the first archive sync goes.
    static let initialSyncWindow: TimeInterval = 7 * 24 * 3600

    /// The window the account's first sync reads. Tests narrow it, as the
    /// server's archive can't be backdated.
    var accountSyncWindow = XMPPSession.initialSyncWindow

    /// Jingle file offers up to this size are accepted without asking. Tests lower it.
    var autoAcceptedOfferSize = XMPPSession.autoDownloadSize

    public convenience init(
        credentials: Credentials,
        resource: String,
        database: AppDatabase,
        avatars: AvatarStore = .temporary(),
        attachments: AttachmentStore = .temporary(),
        mode: Mode = .app,
        pushRelay: JID = XMPPSession.defaultPushRelay,
        fastTokens: FastTokenStore = MemoryFastTokenStore(),
        signInRecords: SignInRecordStore = MemorySignInRecordStore(),
        callMedia: (any CallMediaFactory)? = nil,
        identityKeys: (any IdentityKeyStore)? = nil,
        boundResource: String? = nil,
        resumeTickets: ResumeTicketStore? = nil,
    ) throws {
        try self.init(
            credentials: credentials, resource: resource, database: database, avatars: avatars, attachments: attachments,
            mode: mode, policy: nil, pushRelay: pushRelay, fastTokens: fastTokens, signInRecords: signInRecords,
            callMedia: callMedia, identityKeys: identityKeys, boundResource: boundResource, resumeTickets: resumeTickets,
        )
    }

    /// `policy` replaces the mode's, for a test to run as another platform.
    /// `resource` names the client for sign-in (its FAST token and user agent);
    /// `boundResource`, if given, is the one the session binds, as an extension
    /// that takes the place of the app's session binds the app's. `resumeTickets`
    /// is where the app's stream is handed between the app and an extension.
    init(
        credentials: Credentials,
        resource: String,
        database: AppDatabase,
        avatars: AvatarStore = .temporary(),
        attachments: AttachmentStore = .temporary(),
        mode: Mode = .app,
        policy: Policy?,
        pushRelay: JID = XMPPSession.defaultPushRelay,
        fastTokens: FastTokenStore = MemoryFastTokenStore(),
        signInRecords: SignInRecordStore = MemorySignInRecordStore(),
        callMedia: (any CallMediaFactory)? = nil,
        identityKeys: (any IdentityKeyStore)? = nil,
        boundResource: String? = nil,
        resumeTickets: ResumeTicketStore? = nil,
    ) throws {
        let policy = policy ?? mode.policy
        self.resumeTickets = resumeTickets
        self.journal = policy.resumesSharedStream ? resumeTickets.map { ResumeJournal(store: $0) } : nil
        self.callMedia = callMedia
        self.account = credentials.jid
        self.database = database
        self.mode = mode
        self.policy = policy
        self.pushRelay = pushRelay
        self.fastTokens = fastTokens
        self.signInRecords = signInRecords
        self.avatars = avatars
        self.attachments = attachments
        self.allowsInsecureTransfers = credentials.disableTLS
        database.allowsInsecureLinks = credentials.disableTLS
        self.omemo = try OMEMOEncryption(database: database, account: credentials.jid, identityKeys: identityKeys ?? Self.identityKeys(for: credentials.jid, in: database), rotatesSignedPreKey: mode == .app)

        client.connectionConfiguration.userJid = credentials.jid.martin
        client.connectionConfiguration.credentials = .password(password: credentials.password)
        client.connectionConfiguration.resource = boundResource ?? resource
        client.connectionConfiguration.disableTLS = credentials.disableTLS
        let domain = credentials.jid.domain
        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnectorNetwork.Options.self) { options in
            options.connectionTimeout = 15
            options.diagnostics = { Self.logConnect($0) }
            options.sslCertificateValidation = .customValidator { trust in Self.validate(trust, domain: domain) }
        }
        if let host = credentials.host {
            let port = credentials.port ?? 5222
            client.connectionConfiguration.modifyConnectorOptions(type: SocketConnectorNetwork.Options.self) { options in
                options.dnsResolver = FixedHostResolver(host: host, port: port, directTLS: port == 5223)
            }
        }

        lock.withLock { $0.candidatePassword = credentials.candidatePassword }
        registerModules(requireTLS: !credentials.disableTLS, resource: resource)
        client.context.module(.streamFeatures).stanzaRefused = { _, bytes, limit in
            DiagLog.error(.send, "Stanza over the server's limit", .size("bytes", bytes), .int("limit", limit))
        }
        subscribe()
        reloadKnownRooms()
        monitorNetwork()
        if mode == .app { warnOfNewOwnDevices() }
    }

    /// Martin's default validation checks the certificate with a client-side
    /// SSL policy, which rejects server certificates that lack the clientAuth
    /// usage (all current Let's Encrypt ones). Validate it as a server for the
    /// account's domain, as RFC 6120 requires.
    ///
    /// `anchors` is only ever given by tests, so the live tests can run over
    /// TLS against a dev server's certificate from a local CA. With none,
    /// the system's trust store decides.
    static func validate(_ trust: SecTrust, domain: String, anchors: [SecCertificate] = []) -> Bool {
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString))
        return SecTrustEvaluateWithError(trust, nil)
    }

    #if DEBUG
    /// Gives the session a stream to resume, as one that connected, so that suspending it leaves a ticket,
    /// for the app's tests, whose session is only handed to a stand-in for `connect()`.
    public func seedStreamForTesting(id: String) {
        client.module(.streamManagement).seed(.init(id: id, incoming: 1, outgoing: 1))
        lock.withLock { $0.holdsStream = true }
    }

    /// Runs the stream as one with a server that has no stream management,
    /// which the dev servers all offer. Internal on purpose, for the tests.
    func withoutStreamManagementForTesting() {
        client.modulesManager.unregister(client.module(.streamManagement))
    }

    /// Trusts certificates chaining to `anchors` instead of the system's
    /// roots, for the tests against the dev servers' local CA. Internal on
    /// purpose: the app has no way to widen what it trusts.
    func trustOnly(_ anchors: [SecCertificate]) {
        let domain = account.domain
        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnectorNetwork.Options.self) { options in
            options.sslCertificateValidation = .customValidator { trust in Self.validate(trust, domain: domain, anchors: anchors) }
        }
    }
    #endif

    /// The SASL2 user-agent id (XEP-0388) of the client signing in with
    /// `resource`: stable across launches, different for the app and the
    /// notification extension, and a UUID as the XEP wants.
    public static func userAgentId(account: JID, resource: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(account)/\(resource)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0f | 0x40
        bytes[8] = bytes[8] & 0x3f | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }

    private func registerModules(requireTLS: Bool, resource: String) {
        let modules = client.modulesManager
        modules.register(AuthModule())
        if requireTLS {
            modules.register(RequireTLSStreamFeaturesModule(
                isTLSActive: { [weak self] in self?.client.connector?.activeFeatures.contains(.TLS) ?? false },
                onInsecure: { [weak self] in self?.abort(.fatal("The server doesn't support encryption."), because: .insecure) },
            ))
        } else {
            modules.register(StreamFeaturesModule())
        }
        let sasl = SaslModule()
        sasl.signInRecordChanged = { [signInRecords] mechanism in Self.raise(signInRecords, to: mechanism) }
        modules.register(sasl)
        // Signs in, binds and resumes in one round trip where the server
        // can (XEP-0388, XEP-0386), with a FAST token after the first time.
        let sasl2 = Sasl2Module()
        sasl2.userAgent = .init(id: Self.userAgentId(account: account, resource: resource), software: "Yapnest")
        sasl2.bindTag = "Yapnest"
        sasl2.enableCarbons = policy.enablesCarbons
        sasl2.tokenChanged = { [fastTokens] token in fastTokens.save(token) }
        sasl2.signInRecordChanged = { [signInRecords] mechanism in Self.raise(signInRecords, to: mechanism) }
        modules.register(sasl2)
        modules.register(ResourceBinderModule())
        modules.register(SessionEstablishmentModule())
        modules.register(StreamManagementModule())
        modules.register(DiscoveryModule(identity: .init(category: "client", type: Self.clientType, name: "Yapnest")))
        modules.register(PingModule())
        let presence = PresenceModule()
        // Without presence, the server sends nothing live, nor the messages it
        // stored offline: the archive has them, and the app gets them later.
        presence.initialPresence = policy.announcesPresence
        modules.register(presence)
        let roster = RosterModule(rosterManager: RosterManagerBase(store: DatabaseRosterStore(database: database, subscriptionEnded: { [omemo] jid in
            // Their device lists stop coming by notification with their presence.
            omemo.module.listNoLongerNotified(for: BareJID(jid.description))
        })))
        // The session asks itself (`fetchRoster`), to retry and to say when it fails.
        roster.requestsRosterOnConnect = false
        modules.register(roster)
        modules.register(MessageModule(chatManager: AnyPeerChatManager()))
        modules.register(MessageCarbonsModule())
        modules.register(MessageArchiveManagementModule())
        modules.register(ClientStateIndicationModule())
        modules.register(PubSubModule())
        // Their features reach our capabilities through the modules.
        if callMedia != nil || mode == .app { registerJingleModules() }
        // What we understand, which other clients check before using it with
        // us: Martin's modules for these aren't used, so they don't add them.
        let additional = (Self.messageFeatures + (mode == .app ? JingleFile.features : []))
            .map { CapabilitiesModule.AdditionalFeatures(rawValue: $0) }
        let caps: CapabilitiesModule
        if callMedia != nil {
            // Whether a contact can be called is known once their caps arrive.
            let cache = ReportingCapabilitiesCache()
            cache.stored = { [weak self] in self?.scheduleCallableUpdate() }
            caps = CapabilitiesModule(cache: cache, additionalFeatures: additional)
        } else {
            caps = CapabilitiesModule(additionalFeatures: additional)
        }
        caps.nodeName = "https://yapnest.fr"
        modules.register(caps)
        modules.register(LastActivityModule(
            isOffered: { [weak self] in self?.offersLastActivity ?? false },
            answer: { [weak self] in self?.lastActivityAnswer(for: $0) },
        ))
        // Advertises OMEMO's devicelist+notify so the server pushes contacts'
        // (and our own) device list changes to us.
        omemo.module.publishesKeys = policy.publishesOMEMOKeys
        modules.register(omemo.module)
        // Notifies us of contacts' avatar changes (XEP-0084), with
        // vCard photos (XEP-0153) as the fallback for older clients.
        modules.register(PEPUserAvatarModule())
        modules.register(VCardTempModule())
        modules.register(HttpFileUploadModule())
        modules.register(RoomsModule())
        modules.register(BookmarksModule())
        modules.register(LegacyBookmarksModule())
        // Contacts' published names (XEP-0172).
        modules.register(NickModule())
        modules.register(DisplayedSyncModule())
        modules.register(SettingsSyncModule())
        modules.register(BlockingCommandModule())

        // Martin sends the stored presence on connect, but only runs the hook
        // that adds entity capabilities from setPresence. Caps tell the server
        // we want OMEMO device list updates.
        if policy.announcesPresence {
            // Through setPresence for the same reason, with what the user last chose.
            sendPresence()
        }
    }

    /// The message features handled here rather than by a Martin module.
    static let messageFeatures = [
        NS.receipts, NS.chatStates, NS.markers, NS.correction, NS.retraction,
        NS.reactions, NS.reply, NS.oob,
    ]

    /// XEP-0030's registry: a handheld is a "phone", the Mac a "pc".
    static var clientType: String {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        "phone"
        #else
        "pc"
        #endif
    }

    /// Whether an archive result may be applied. Martin doesn't tie results to the archive we
    /// queried, so a hostile room could forward a message from another room, and the room
    /// handler would trust the forwarded `from`. A room's results must come from that room; our
    /// own archive's must involve us, when the stanza says who it's between.
    static func archivedMessage(_ message: Martin.Message, belongsTo source: JID, isAccount: Bool) -> Bool {
        let from = message.from.flatMap { JID($0) }
        if !isAccount { return from == source }
        guard let from, let to = message.to.flatMap({ JID($0) }) else { return true }
        return from == source || to == source
    }

    private func subscribe() {
        client.$state
            .sink { [weak self] state in self?.clientStateChanged(state) }
            .store(in: &cancellables)

        if journal != nil {
            client.incomingObserver = { [weak self] stanza in self?.journalInbound(stanza) }
        }
        if policy.ownsSharedStream, resumeTickets != nil {
            client.module(.streamManagement).acknowledgedHandler = { [weak self] snapshot in self?.keepTicketCurrent(snapshot) }
        }
        if policy.ownsSharedStream {
            client.module(.streamManagement).resumedHandler = { [weak self] in self?.replayJournal() }
        } else if policy.resumesSharedStream {
            client.module(.streamManagement).resumedHandler = { [weak self] in self?.noteResumedAppStream() }
        }

        client.module(.message).messagesPublisher
            .sink { [weak self] received in self?.handleTopLevel(received.message) }
            .store(in: &cancellables)

        client.module(.mam).archivedMessagesPublisher
            .sink { [weak self] archived in
                guard let self, let source = JID(archived.source.stringValue) else { return }
                // Openfire numbers its archive results, and in a room those
                // numbers aren't the stanza-id the live copy carries. The
                // stanza-id inside, stamped by the archive's owner, is the
                // same everywhere.
                let serverId = archived.message.stanzaId?[source.martin] ?? archived.messageId
                let origin = InboundMessage.Source.archive(serverId: serverId, timestamp: archived.timestamp)
                let isHistory = self.lock.withLock { $0.historyQueries.contains(archived.query.id) }
                let isAccount = source == self.account
                guard isAccount || self.isGroup(source) else { return }
                guard Self.archivedMessage(archived.message, belongsTo: source, isAccount: isAccount) else {
                    self.logger.warning("Dropped an archive result from \(source.description, privacy: .private) about someone else's conversation")
                    return
                }
                if isAccount {
                    self.handle(archived.message, source: origin, isHistory: isHistory, query: archived.query.id)
                } else {
                    self.handleRoomStanza(archived.message, source: origin, isHistory: isHistory, query: archived.query.id)
                }
            }
            .store(in: &cancellables)

        client.modulesManager.module(RoomsModule.IDENTIFIER).messages
            .sink { [weak self] message in self?.handleRoomStanza(message, source: .live) }
            .store(in: &cancellables)

        client.modulesManager.module(BookmarksModule.IDENTIFIER).changes
            .sink { [weak self] change in self?.bookmarkChanged(change) }
            .store(in: &cancellables)

        client.modulesManager.module(LegacyBookmarksModule.IDENTIFIER).changes
            .sink { [weak self] bookmarks in self?.legacyBookmarksChanged(bookmarks) }
            .store(in: &cancellables)

        client.modulesManager.module(NickModule.IDENTIFIER).changes
            .sink { [weak self] change in self?.nicknameChanged(change.jid, to: change.nickname) }
            .store(in: &cancellables)

        client.module(.auth).$state
            .sink { [weak self] state in self?.logAuthorization(state) }
            .store(in: &cancellables)

        client.module(.blockingCommand).$blockedJids
            .sink { [weak self] jids in self?.blocklistChanged(jids) }
            .store(in: &cancellables)

        client.modulesManager.module(DisplayedSyncModule.IDENTIFIER).changes
            .sink { [weak self] state in self?.displayedChanged(state) }
            .store(in: &cancellables)

        client.modulesManager.module(SettingsSyncModule.IDENTIFIER).changes
            .sink { [weak self] change in self?.settingsChanged(change) }
            .store(in: &cancellables)

        client.module(.disco).$accountDiscoResult
            .sink { [weak self] result in self?.accountDiscovered(result) }
            .store(in: &cancellables)
        client.module(.disco).accountDiscoveryFailed = { [weak self] error in self?.accountDiscoveryFailed(error) }

        client.module(.streamManagement).ackedStanzas
            .sink { [weak self] stanza in self?.acknowledged(stanza) }
            .store(in: &cancellables)

        client.module(.presence).presencePublisher
            .sink { [weak self] change in self?.presenceChanged(change.presence) }
            .store(in: &cancellables)

        client.module(.presence).subscriptionPublisher
            .sink { [weak self] change in self?.subscriptionChanged(change) }
            .store(in: &cancellables)

        omemo.module.activeDevicesPublisher
            .sink { [weak self] change in
                // A list made up after a failed read would make every device we have look new later.
                guard change.readFromServer else { return }
                if !change.activeDevices.isEmpty, let member = JID(change.jid.description) { self?.memberMayNowHaveOMEMO(member) }
                self?.deviceListHeard(of: change.jid.description, ids: change.activeDevices)
            }
            .store(in: &cancellables)

        client.module(.pepUserAvatar).avatarChangePublisher
            .sink { [weak self] change in
                guard let self, let jid = JID(change.jid) else { return }
                self.pepAvatarChanged(jid, info: change.info)
            }
            .store(in: &cancellables)
    }

    // MARK: Connection

    /// Connects, and keeps reconnecting with backoff until `disconnect()`.
    public func connect() {
        lock.withLock {
            $0.wantsConnection = true
            if policy.ownsSharedStream { $0.holdsStream = true }
        }
        if case .disconnected = client.state {
            // Before anything can arrive, so an offer of this session isn't swept.
            if policy.ownsSharedStream {
                expireFileOffers()
                // Settling reads and decodes files and, adopting counters, acknowledges stanzas into the
                // database, which the caller's thread (the main one) mustn't. `loginQueue` is serial, so
                // two calls don't log in twice.
                loginQueue.async { [self] in
                    guard lock.withLock({ $0.wantsConnection }), case .disconnected = client.state else { return }
                    login()
                }
            } else {
                login()
            }
        }
    }

    /// With the latest FAST token: another session may have replaced it.
    /// Another client of the account may have raised the record since this
    /// one read it, so it is compared again with what is stored now.
    static func raise(_ records: SignInRecordStore, to mechanism: String) {
        if SignInPinning.recording(succeeded: mechanism, recorded: records.load()) != nil { records.save(mechanism) }
    }

    private func login() {
        // On every attempt, not only the first after a suspension: the close that `suspendImmediately()`
        // started may still be in flight when the user returns, so the attempt that follows it is a
        // reconnect, and the app would otherwise resume with the counters from before an extension used
        // the stream. A no-op when no other process wrote a ticket.
        if policy.ownsSharedStream { settleResumeTicket() }
        let token = fastTokens.load()
        client.module(.sasl2).fastToken = token
        // Likewise the latest record: another client may have raised it.
        let record = signInRecords.load()
        client.module(.sasl2).signInRecord = record
        client.module(.sasl).signInRecord = record
        let attempts = lock.withLock {
            $0.connectStartedAt = Date()
            return $0.reconnectAttempt
        }
        DiagLog.info(.connection, "Connecting", .int("reconnects", attempts), .bool("fastToken", token != nil))
        client.login()
    }

    /// Deletes a conversation from this device, with the files of its
    /// attachments. Does disk work, so call it off the main thread.
    public func deleteConversation(id: Int64) throws {
        for attachment in try database.deleteConversation(id: id) { attachments.remove(attachment) }
    }

    /// Ends the session for good: the server forgets it, and so does the
    /// ticket the extensions would resume it from.
    public func disconnect() {
        lock.withLock {
            $0.wantsConnection = false
            $0.savedTicketGeneration = nil
        }
        ticketQueue.sync {
            lock.withLock { $0.ticketFollowsStream = false }
            if policy.usesResumeTickets { resumeTickets?.delete() }
            if policy.ownsSharedStream { resumeTickets?.deleteJournal() }
        }
        _ = client.disconnect()
    }

    /// Drops the connection without ending the session: the server keeps it
    /// (XEP-0198), pushes for what arrives meanwhile, and `connect()` resumes
    /// it. For when the app goes to the background.
    ///
    /// Returns once the ticket is saved, which is after Martin has reported the connection closed: what
    /// is read or acknowledged up to then is in the counters, which a ticket saved earlier would leave
    /// behind what the server has been told. Prosody fails such a resume. It waits suspended, so the main
    /// actor isn't held, and not at all if the app reconnected meanwhile or the task was cancelled, as
    /// then the stream is in use again, or `suspendImmediately()` has saved the ticket.
    public func suspend() async {
        beginSuspension()
        await waitForDisconnectAsync()
        guard !Task.isCancelled, !lock.withLock({ $0.wantsConnection }) else { return }
        saveResumeTicket()
    }

    /// `suspend()` for when there is no time to wait: the ticket is saved at once, with the counters as
    /// they stand. A connection still closing may then have read more than the ticket says, and a server
    /// that checks (Prosody) refuses the resume, which the app answers with a new session.
    public func suspendImmediately() {
        beginSuspension()
        saveResumeTicket()
    }

    private func beginSuspension() {
        // An away presence on its way out goes before the connection does.
        presenceQueue.sync {}
        lock.withLock {
            $0.wantsConnection = false
            $0.ticketFollowsStream = false
        }
        _ = client.disconnect(true)
    }

    /// The most a forced disconnect is waited for. It is what a stalled close costs at worst: the wait
    /// ends with Martin's report that it is disconnected, which follows the last stanza it reads, so
    /// that the counters saved after it are the stream's. A ticket saved earlier on a slow device would
    /// be behind what the server was told, and Prosody refuses a resumption like that.
    private static let disconnectWait: TimeInterval = 10

    /// Until Martin reports the connection closed, or `limit`.
    ///
    /// Detached, so that a caller that is cancelled (a fetch iOS cut short) still waits for the close:
    /// the counters saved before it would be behind what the server was told. The bound is what ends a
    /// close that stalls. With `cutShortOnCancel` a cancelled caller waits a second more instead, for one
    /// that has to let go of what it holds before the process is suspended or killed (`leave`).
    private func waitForDisconnectAsync(upTo limit: TimeInterval = disconnectWait, cutShortOnCancel: Bool = false) async {
        let wait = CloseWait()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait.arm(continuation)
                Task.detached { [self] in
                    _ = try? await withTimeout(limit) { [self] in
                        for await state in client.$state.values {
                            if case .disconnected = state { return }
                        }
                    }
                    wait.finish()
                }
            }
        } onCancel: {
            if cutShortOnCancel { DispatchQueue.global().asyncAfter(deadline: .now() + 1) { wait.finish() } }
        }
    }

    /// A wait that one of several things ends: the first to call `finish` resumes it.
    private final class CloseWait: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            let ended = lock.withLock {
                if !finished { self.continuation = continuation }
                return finished
            }
            if ended { continuation.resume() }
        }

        func finish() {
            let continuation = lock.withLock {
                finished = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume()
        }
    }

    /// Leaves the stream where the notification extension can take it over,
    /// with the counters as they stand once the connection is gone.
    private func saveResumeTicket() {
        guard policy.ownsSharedStream, let store = resumeTickets else { return }
        ticketQueue.sync { saveResumeTicket(store) }
    }

    private func saveResumeTicket(_ store: ResumeTicketStore) {
        lock.withLock { $0.ticketFollowsStream = false }
        // Once per connect: after this the ticket is the stream's, which an extension may be using.
        let holdsStream = lock.withLock { state in
            defer { state.holdsStream = false }
            return state.holdsStream
        }
        guard holdsStream else { return }
        // What an earlier suspension's wakes kept is no use to this one: the app's memory is as of now.
        store.deleteJournal()
        let generation = storeResumeTicket(store, from: client.modulesManager.moduleOrNil(.streamManagement))
        lock.withLock { $0.savedTicketGeneration = generation }
    }

    /// Saves the stream's counters, or removes the ticket if there are none
    /// (`save` removes it itself when it can't write), and returns the generation.
    private func storeResumeTicket(
        _ store: ResumeTicketStore, from sm: StreamManagementModule?, appHandled: (_ stream: String) -> UInt32? = { _ in nil }, journalLost: Bool = false,
    ) -> UInt64? {
        let generation: UInt64?
        if let snapshot = sm?.snapshot {
            generation = store.save(snapshot, appHandled: appHandled(snapshot.id), journalLost: journalLost)
        } else {
            store.delete()
            generation = nil
        }
        DiagLog.info(.connection, "Resume ticket saved", .bool("saved", generation != nil))
        return generation
    }

    /// The app's ticket follows its stream while it is connected, as the server was last told it stands,
    /// so that an app killed while connected (swiped away before it suspended) still leaves the stream
    /// to the extension. Without it the extension opened a session of its own, and what the server queued
    /// for the app's, such as a call offer, reached no one. Only while the app holds the stream: from its
    /// suspension on, `saveResumeTicket` writes the last one. The extension can't take the ticket while
    /// the app runs, as the session lock is the app's.
    private func keepTicketCurrent(_ snapshot: StreamManagementModule.Snapshot) {
        guard let store = resumeTickets else { return }
        let queued = lock.withLock { state in
            defer { state.pendingTicket = snapshot }
            return state.pendingTicket != nil
        }
        guard !queued else { return }
        ticketQueue.async { [self] in
            let snapshot = lock.withLock { state -> StreamManagementModule.Snapshot? in
                defer { state.pendingTicket = nil }
                return state.ticketFollowsStream ? state.pendingTicket : nil
            }
            guard let snapshot else { return }
            let generation = store.save(snapshot)
            lock.withLock { $0.savedTicketGeneration = generation }
        }
    }

    /// The app is about to use the stream, which makes the ticket stale: its
    /// counters fall behind at once, and an extension that resumed from them
    /// would have the server replay, or on ejabberd silently lose, what the
    /// app has read since. So it goes.
    ///
    /// If another process has written one since the app saved its own, that
    /// process used the stream: what it consumed is in its journal, and its
    /// counters are the stream's now. The app resumes with those, after
    /// sending again what the server never got of its own, and replays the
    /// journal as the stream resumes (`replayJournal`), if everything allows:
    /// the ticket names the stream the app has in memory, the extension could
    /// say how much of the app's own it found arrived, and nothing is missing
    /// from the journal. Otherwise, or if there is nothing in memory (the app
    /// was evicted), the app forgets the stream and starts a new session, as
    /// it does when a resumption fails, and rings for the calls the journal
    /// holds, which a new session would read back from the archive without ringing.
    func settleResumeTicket() {
        guard let store = resumeTickets else { return }
        ticketQueue.sync {
            settleResumeTicket(store)
            lock.withLock { $0.ticketFollowsStream = true }
        }
    }

    private func settleResumeTicket(_ store: ResumeTicketStore) {
        let saved = lock.withLock { $0.savedTicketGeneration.take() }
        let ticket = store.load()
        let journal = store.readJournal()
        store.delete()
        store.deleteJournal()
        let sm = client.modulesManager.moduleOrNil(.streamManagement)
        if ticket?.generation == saved {
            // A journal without a newer ticket is an extension that didn't live to leave: the stream moved on.
            guard !journal.entries.isEmpty || !journal.isComplete else { return }
        } else if let ticket, let sm, saved != nil, let handled = ticket.appHandled, !ticket.journalLost, journal.isComplete,
                  sm.snapshot?.id == ticket.stream.id, journal.entries.allSatisfy({ $0.stream == ticket.stream.id }) {
            sm.adopt(ticket.stream, handled: handled)
            // After what an earlier adoption holds that never reached a resumption (the app was suspended
            // again first): those stanzas are still unseen, and the journal that held them is gone.
            lock.withLock {
                $0.journaled += journal.entries
                $0.replaysJournal = true
            }
            DiagLog.info(.connection, "Stream used by an extension, resuming with its counters", .int("kept", journal.entries.count))
            return
        }
        sm?.reset()
        // Of a stream that is gone, so only the calls in it are rung for; the earlier ones' too, if none was.
        lock.withLock {
            $0.journaled += journal.entries
            $0.replaysJournal = false
        }
        DiagLog.info(.connection, "Stream used by another process, starting a new session")
    }

    /// What the app's modules are to be fed from `entries`, in order, to catch up with the stream: all of
    /// it in a resumed stream, only the calls in a new session, which learns the rest itself.
    ///
    /// A call offer is dropped if the journal also holds the end of it: the extension has written the
    /// call's row, and nothing is to ring. So is its end, which has nothing left to tell. An offer from our
    /// own account is no call to answer here. One past the ring window is not dropped: the extension stores
    /// nothing for a fresh offer, since a device may still answer it, so the live path writes the missed
    /// call's row, as it does for any stale offer, and doesn't ring.
    ///
    /// An end only counts for the offer if the machine would take it: a retraction from the caller, or an
    /// answer or turning down from one of our devices. Anyone else's would only silence a call.
    static func journalReplay(
        _ entries: [JournalEntry], account: JID, now: Date, offset: TimeInterval, isRoom: (JID) -> Bool, callsOnly: Bool,
    ) -> [Element] {
        let items: [(element: Element, signal: CallSignal?)] = entries.compactMap { entry in
            let stamper = { (element: Element) -> String in
                if let from = element.getAttribute("from").flatMap({ JID($0) }), isRoom(from) { return from.description }
                return account.domain
            }
            guard let element = ResumeJournal.replayable(entry, stamper: stamper, server: account.domain, offset: offset) else { return nil }
            return (element, callSignal(in: element, account: account, now: now, offset: offset))
        }
        let signals = items.compactMap(\.signal)
        let proposes = signals.filter { if case .propose = $0.action { true } else { false } }
        return items.compactMap { element, signal in
            guard let signal else { return callsOnly ? nil : element }
            if case .propose = signal.action {
                if signal.isFromAccount || signals.contains(where: { Self.ends($0, signal) }) { return nil }
            } else if proposes.contains(where: { Self.ends(signal, $0) }) {
                return nil
            }
            return element
        }
    }

    /// Whether `end` ends the call `propose` offered, as the machine would take it: a retraction from the
    /// caller, or an answer or turning down from one of our devices. Anyone else's would only silence a call.
    static func ends(_ end: CallSignal, _ propose: CallSignal) -> Bool {
        guard end.sid == propose.sid else { return false }
        switch end.action {
        case .retract, .finish: return !end.isFromAccount && end.sender == propose.sender
        case .proceed, .accept, .reject: return end.isFromAccount
        case .propose, .ringing: return false
        }
    }

    /// The call signal a message is, also in a carbon.
    private static func callSignal(in element: Element, account: JID, now: Date, offset: TimeInterval) -> CallSignal? {
        guard element.name == "message", ResumeJournal.containsCallSignal(element),
              let message = Stanza.from(element: element) as? Martin.Message else { return nil }
        switch unwrapCarbon(message, account: account) {
        case .plain: return CallSignal(message, account: account, source: .live, now: now, clockOffset: offset)
        case .dropped: return nil
        case .carbon(let inner, let sent): return CallSignal(inner, account: account, source: .carbon(sent: sent), now: now, clockOffset: offset)
        }
    }

    /// The stream is resumed, and what the extension consumed from it is fed to the modules before anything
    /// the server sends next, so that the app sees it all in order: a presence it kept can't overwrite a
    /// newer one that followed.
    private func replayJournal() {
        let (entries, adopted) = lock.withLock { state in
            defer {
                state.journaled = []
                state.replaysJournal = false
            }
            return (state.replaysJournal ? state.journaled : [], state.replaysJournal)
        }
        guard adopted else { return }
        // A block list push is no use to the extension, which doesn't hold the list, so it isn't in the
        // journal, and replaying an iq would have the modules answer it twice: read the list again.
        let blocking = client.module(.blockingCommand)
        if blocking.isAvailable {
            blocking.reset(scopes: [.session])
            Task { [self] in await readBlocklistAgain() }
        }
        guard !entries.isEmpty else { return }
        let elements = Self.journalReplay(
            entries, account: account, now: Date(), offset: serverClockOffset, isRoom: isGroup, callsOnly: false,
        )
        DiagLog.info(.connection, "Replaying what an extension consumed", .int("stanzas", elements.count))
        for element in elements { client.replayIncoming(Stanza.from(element: element)) }
    }

    /// Reads the block list the app lost the copy of, as a new session's module does when the server
    /// announces blocking, but with the error shown: a list that stays unread leaves blocked contacts
    /// looking unblocked. What can pass is retried; a final error is a warning with a Retry.
    private func readBlocklistAgain() async {
        let key = "blocklist"
        do {
            try await retryingPassingErrors(callback: { [client] done in
                client.module(.blockingCommand).retrieveBlockedJids { done($0.map { _ in () }.mapError { $0 }) }
            })
            warnings.clear(key)
        } catch {
            // A session that ended meanwhile redoes this on its own.
            guard !(error is CancellationError) else { return }
            warnings.post(key, title: String(localized: "Block list not loaded"), friendly: String(localized: "The server wouldn't give the list of blocked contacts"), error: error) { [weak self] in
                guard let self else { return }
                try await retryingPassingErrors(callback: { [client] done in
                    client.module(.blockingCommand).retrieveBlockedJids { done($0.map { _ in () }.mapError { $0 }) }
                })
                warnings.clear(key)
            }
        }
    }

    /// Rings for the calls an extension took from the stream, in a session that didn't resume it, as
    /// a live propose would have: consent, the tie-break and the ring are the usual ones.
    ///
    /// Only called for a new session, so a replay still pending is for a resumption that failed after the
    /// app adopted the extension's counters: left set, a later resumption of this new stream would feed
    /// the old stream's journal into it.
    private func ringJournaledCalls() {
        let entries = lock.withLock { state in
            defer {
                state.journaled = []
                state.replaysJournal = false
            }
            return state.journaled
        }
        guard !entries.isEmpty else { return }
        let elements = Self.journalReplay(
            entries, account: account, now: Date(), offset: serverClockOffset, isRoom: isGroup, callsOnly: true,
        )
        for element in elements {
            if let message = Stanza.from(element: element) as? Martin.Message { handleTopLevel(message) }
        }
    }

    /// An extension keeps what the app needs to see live and the extension doesn't store. Of a stream that
    /// isn't the app's, a session of its own that the app never resumes, only the calls: everything else
    /// is read back from the archive.
    private func journalInbound(_ stanza: Stanza) {
        streamTally.count(stanza.element, account: account, isRoom: isGroup)
        if stanza.name == "message", let from = stanza.from.flatMap({ JID($0.description) }), isGroup(from) {
            lock.withLock { _ = $0.roomsHeardLive.insert(from) }
        }
        guard let journal, ResumeJournal.keeps(stanza.element, isRoom: isGroup) else { return }
        let id = client.module(.streamManagement).streamId
        guard (id != nil && id == lock.withLock { $0.seededStreamId }) || ResumeJournal.containsCallSignal(stanza.element) else { return }
        journal.append(JournalEntry(stream: id, at: Date(), xml: stanza.element.stringValue))
    }

    /// An extension's session is on the app's stream: it resumed the ticket's, and the server hasn't
    /// refused it since. What it reads there is kept for the app (`journalInbound`) rather than stored.
    var isOnAppsStream: Bool {
        guard journal != nil, let seeded = lock.withLock({ $0.seededStreamId }) else { return false }
        return client.module(.streamManagement).streamId == seeded
    }

    /// An extension's session is given the app's stream to resume, if a ticket has one.
    func seedFromTicket() {
        guard policy.resumesSharedStream, let store = resumeTickets, let ticket = store.load(),
              let sm = client.modulesManager.moduleOrNil(.streamManagement) else { return }
        sm.seed(ticket.stream)
        lock.withLock {
            $0.seededStreamId = ticket.stream.id
            $0.seededAppHandled = ticket.appHandled
            $0.seededJournalLost = ticket.journalLost
        }
        DiagLog.info(.connection, "Resuming from a ticket")
    }

    /// The server took the ticket's stream: what it says it had handled of the app's own stanzas is kept
    /// from the first time, as a drop and a second resumption in the same wake would count this wake's own.
    private func noteResumedAppStream() {
        guard let snapshot = client.module(.streamManagement).snapshot else { return }
        lock.withLock { state in
            guard state.seededStreamId == snapshot.id, state.firstResumedH == nil else { return }
            state.firstResumedH = snapshot.resumedH
        }
    }

    /// A new session came up where the ticket's stream was to be resumed: the
    /// server no longer has it, or no longer does stream management at all, in
    /// which case it never replaced what the seed put in the module.
    private func ticketFailed() {
        guard let id = lock.withLock({ $0.seededStreamId.take() }) else { return }
        DiagLog.info(.connection, "Resume refused, new session")
        resumeTickets?.delete()
        if let sm = client.modulesManager.moduleOrNil(.streamManagement), sm.snapshot?.id == id { sm.reset() }
    }

    /// Ends an extension's session the way that doesn't make the server tell
    /// the app's session that this one left: the final acknowledgement, then
    /// the connection closed without `</stream>`, which keeps the stream for
    /// the next wake, and the ticket updated. A server that can't resume
    /// streams gets the usual close.
    ///
    /// Done by `deadline` if there is one, as what runs it is cut off when its time is up: the final
    /// acknowledgement and the close share what is left of it, and the ticket, which is quick, is saved
    /// after. A caller that is cancelled has iOS about to suspend it, so it only waits a moment.
    func leave(by deadline: Date? = nil) async {
        lock.withLock { $0.wantsConnection = false }
        // What is read while the connection closes is still kept, so it is closed after that.
        defer {
            journal?.close()
            if journal != nil {
                DiagLog.info(.notificationExtension, "Read while awake", fields: [.int("total", streamTally.total)] + streamTally.fields)
            }
        }
        guard policy.resumesSharedStream, let store = resumeTickets,
              let sm = client.modulesManager.moduleOrNil(.streamManagement), sm.resumptionEnabled else { return disconnect() }
        // A session that never got onto a stream knows nothing the ticket doesn't, so it stays as it was.
        guard lock.withLock({ $0.reachedStream }) else {
            _ = client.disconnect(true)
            return
        }
        let remaining = { deadline.map { max(0, $0.timeIntervalSinceNow) } ?? .infinity }
        // An answer that comes after the final acknowledgement waits in the stream the server keeps, unacknowledged,
        // and a server set to push for everything (ejabberd's `notify_on: all`) pushes for it when the stream goes to
        // sleep: the next wake, which leaves another behind. So what was asked is waited for, within the budget, and
        // again after the acknowledgement, as a stanza read just before it can start a request (a key bundle fetched
        // for a device a room message names), which vault's log showed answered after the close.
        for round in 0..<Self.leavingRounds {
            guard isConnected else { break }
            let pending = client.pendingRequests
            if pending > 0 {
                let waitStarted = Date()
                await waitForAnswers(upTo: min(Self.answersWait, remaining() * 0.3))
                DiagLog.info(
                    .notificationExtension, "Waited for answers before leaving",
                    .int("round", round), .int("pending", pending), .int("left", client.pendingRequests), .duration("took", since: waitStarted),
                )
            } else if round > 0 {
                break
            }
            // Over, if the connection dropped meanwhile: the counters are still what this process handled.
            guard isConnected else { break }
            await sendFinalAcknowledgement(sm, wait: min(Self.finalAcknowledgementWait, remaining() * 0.3, Task.isCancelled ? 0.5 : .infinity))
            guard client.pendingRequests > 0 else { break }
        }
        _ = client.disconnect(true)
        // After the close, so that what was read up to it is in the ticket. Not none at all when there is no
        // time left: the close is written at once, and what it reads then is not in the counters, which a
        // server that checks (Prosody) answers by refusing the resume, and the app by a new session.
        await waitForDisconnectAsync(upTo: min(Self.disconnectWait, max(0.25, remaining())), cutShortOnCancel: true)
        // What the app's own stanzas had reached the server by the first wake's resume is what it needs to
        // send the rest again, and a later resume's `resumedH` counts the earlier ones' stanzas too, whether
        // it is another wake's or this wake's after a drop.
        let (seeded, seededHandled, seededLost, firstResumedH) = lock.withLock {
            ($0.seededStreamId, $0.seededAppHandled, $0.seededJournalLost, $0.firstResumedH)
        }
        _ = storeResumeTicket(
            store, from: sm, appHandled: { $0 == seeded ? seededHandled ?? firstResumedH : nil },
            journalLost: seededLost || (journal?.isLost ?? false),
        )
    }

    private static let finalAcknowledgementWait: TimeInterval = 2

    /// The most `leave` waits for answers to what the wake asked: a request the server never answers (a room's
    /// server that is down) mustn't cost the extension its budget.
    static let answersWait: TimeInterval = 1.5

    /// How many times `leave` waits and acknowledges again for requests started while it did: bounded, as a
    /// busy stream could otherwise keep the extension from ever leaving.
    static let leavingRounds = 3

    /// Until every request sent on the stream has its answer, or `limit`.
    func waitForAnswers(upTo limit: TimeInterval) async {
        let deadline = Date().addingTimeInterval(limit)
        while client.pendingRequests > 0, Date() < deadline, isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Written before the connection closes, which would cut it off; not waited
    /// for beyond a moment, as a stalled connection never completes the write. Not `withTimeout`: its
    /// group waits for the operation to end, and a write that never completes ignores cancellation.
    private func sendFinalAcknowledgement(_ sm: StreamManagementModule, wait: TimeInterval = finalAcknowledgementWait) async {
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Detached, so a cancelled fetch still sends it.
            Task.detached {
                await sm.acknowledge()
                if once.first() { continuation.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                if once.first() { continuation.resume() }
            }
        }
    }

    /// For the notification extension: resumes the app's stream if the
    /// ticket has one, otherwise connects as the app's resource, catches up on
    /// the archives and leaves the stream for the next wake (`leave`). False if
    /// that didn't finish within `timeout`, which is for all of it: the catch-up gets the part that leaves
    /// `leaveReserve` for the final acknowledgement, the close and the ticket, as a caller that is cut
    /// off after `timeout` (the extension's 30 seconds, a background task) would otherwise be killed
    /// before the ticket is saved, or the session lock released.
    public func catchUpOnce(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        seedFromTicket()
        connect()
        let finished = (try? await withTimeout(timeout - min(Self.leaveReserve, timeout / 2)) { [self] in
            for await value in state.values {
                // A catch-up cut off by a drop never reaches this state, but a
                // stale one could be read just as the stream goes.
                if value == .connected(isSyncing: false) { return isConnected }
                if case .failed = value { return false }
            }
            return false
        }) ?? false
        if isConnected { ringForIncomingCalls() }
        await leave(by: deadline)
        return finished
    }

    /// The calls this session was offered and that are still ringing, which the extension's push is the only
    /// sign of while the app isn't running: the caller is told they are, and the caller of this is given them
    /// to show. Written before `leave`, so the ticket counts what it sends.
    public var incomingCalls: [IncomingCall] { lock.withLock { $0.incomingCalls } }

    func ringForIncomingCalls(now: Date = Date()) {
        let heard = lock.withLock { $0.heardCallSignals }
        var calls: [IncomingCall] = []
        for signal in heard {
            guard case .propose(let media) = signal.action, media.contains(.audio), !signal.isFromAccount,
                  now.timeIntervalSince(signal.timestamp) < CallMachine.ringWindow,
                  !heard.contains(where: { Self.ends($0, signal) }),
                  (try? database.hasConsented(signal.sender)) == true,
                  !calls.contains(where: { $0.sid == signal.sid }) else { continue }
            if let device = signal.from { writeCall(.ringing(to: device), sid: signal.sid) }
            let name = try? database.reader.read { try Contact.fetchOne($0, key: signal.sender)?.displayName }
            calls.append(IncomingCall(sid: signal.sid, peer: signal.sender, name: name ?? signal.sender.shortName, isVideo: media.contains(.video)))
        }
        let rung = calls
        lock.withLock { $0.incomingCalls = rung }
    }

    /// What `catchUpOnce` keeps for leaving: more than a close takes when the network is good, less than
    /// `disconnectWait`, which a stalled one would use.
    static let leaveReserve: TimeInterval = 5

    /// Drops the current attempt, reporting `failure` instead of Martin's reason.
    private func abort(_ failure: Failure, because cause: AbortCause) {
        DiagLog.notice(.connection, "Dropping the connection", .value("cause", cause))
        lock.withLock { $0.pendingFailure = failure }
        _ = client.disconnect(true)
    }

    /// Martin times each endpoint's TCP and TLS connect itself, and falls back
    /// to the next record, so this must not cut that short. It guards what
    /// Martin doesn't: a server that accepts the connection and then stalls
    /// would otherwise leave us connecting forever. It starts when the
    /// connector reports its connection up, or at once if there is no
    /// connector to watch.
    private func startWatchdog() {
        let attempt = lock.withLock {
            $0.attempt += 1
            $0.watchdogSubscription = nil
            return $0.attempt
        }
        let arm = { [weak self] in
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.connectTimeout) {
                guard let self, self.lock.withLock({ $0.attempt == attempt }), case .connecting = self.client.state else { return }
                self.abort(.transient("The server didn't respond."), because: .watchdog)
            }
        }
        guard let connector = client.connector else { return arm() }
        let subscription = connector.statePublisher
            .filter { $0 == .connected }
            .first()
            .sink { _ in arm() }
        let box = SubscriptionBox(subscription)
        lock.withLock { state in
            // A newer attempt may have begun, or this one ended, meanwhile.
            if state.attempt == attempt { state.watchdogSubscription = box }
        }
    }

    /// Pings the server and, if nothing answers within `timeout`, drops the
    /// connection so the usual reconnect resumes the session. A half-open
    /// connection (a network switch, a sleeping device) reports no error, and
    /// Martin's own ping would take minutes to notice. Any reply, even an
    /// error, shows the link works. Nothing happens unless we're connected:
    /// connecting has its watchdog, and a disconnected session is already
    /// reconnecting.
    func verifyConnection(timeout: TimeInterval = 5) {
        guard policy.verifiesLiveness, isConnected else { return }
        let check = UUID()
        let attempt: Int? = lock.withLock {
            guard $0.livenessCheck == nil else { return nil }
            $0.livenessCheck = check
            return $0.attempt
        }
        guard let attempt else { return }
        livenessPending.send(true)
        // Martin only checks its timeouts every 30 seconds, so ours is separate.
        let answered = OSAllocatedUnfairLock(initialState: false)
        client.module(.ping).ping(Martin.JID(account.martin), timeout: timeout) { [weak self] result in
            if case .failure(.remote_server_timeout) = result { return }
            answered.withLock { $0 = true }
            // The connection is proven now, though the check stays until its
            // time is up so that only one runs at a time.
            self?.livenessPending.send(false)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let current = lock.withLock {
                guard $0.livenessCheck == check else { return false }
                $0.livenessCheck = nil
                // A new connection since the ping has proved itself.
                return $0.attempt == attempt
            }
            let heard = answered.withLock { $0 }
            guard current, isConnected else {
                if lock.withLock({ $0.livenessCheck == nil }) { livenessPending.send(false) }
                return
            }
            DiagLog.notice(.connection, "Liveness check finished", .value("outcome", heard ? LivenessOutcome.answered : .silent), .duration("timeout", timeout))
            guard !heard else { return }
            // A silent stream stays pending until the next connection clears
            // it: Martin may still read as connected for a moment after the
            // drop, and a waiter must not take that for an answer.
            abort(.transient("The connection was lost."), because: .noAnswer)
        }
    }

    /// What to do about a network path that has become usable.
    enum PathAction: String, DiagEnum {
        case nothing
        /// Ping the server: the old connection may be dead.
        case verify
        /// Drop the attempt in flight, which started on the old path, and begin a new one.
        case restartAttempt
        /// Skip the backoff and log in.
        case loginNow
    }

    /// - Parameter changed: whether the network differs in a way that matters. An
    ///   attempt in flight began on the network that is still there when it doesn't,
    ///   so restarting it would only cost a second.
    static func pathAction(for state: XMPPClient.State, wantsConnection: Bool, changed: Bool = true) -> PathAction {
        switch state {
        case .connected: .verify
        case .connecting: wantsConnection && changed ? .restartAttempt : .nothing
        case .disconnected: wantsConnection ? .loginNow : .nothing
        case .disconnecting: .nothing
        }
    }

    /// Reacts to the network changing. A connection that was dead, an attempt
    /// stuck on the old interface, or a backoff that grew while we were
    /// offline would each otherwise last until a timeout or the next retry,
    /// up to a minute; none of them is worth waiting for once a network is back.
    func pathBecameSatisfied(changed: Bool = true) {
        let wants = lock.withLock { $0.wantsConnection }
        let action = Self.pathAction(for: client.state, wantsConnection: wants, changed: changed)
        DiagLog.info(.network, "Network path usable", .value("action", action), .bool("wantsConnection", wants), .bool("changed", changed))
        switch action {
        case .nothing:
            break
        case .verify:
            verifyConnection()
        case .restartAttempt:
            lock.withLock { $0.retryNow = true }
            abort(.transient("The network changed."), because: .networkChanged)
        case .loginNow:
            reconnectNow()
        }
    }

    private func reconnectNow() {
        let proceed = lock.withLock {
            guard $0.wantsConnection else { return false }
            $0.retryNow = false
            $0.reconnectAttempt = 0
            $0.reconnectToken += 1
            return true
        }
        guard proceed, case .disconnected = client.state else { return }
        login()
    }

    /// Checks the connection whenever the network changes, as a switch from
    /// Wi-Fi to cellular leaves the old connection silently dead.
    private func monitorNetwork() {
        guard policy.verifiesLiveness else { return }
        let monitor = NWPathMonitor()
        // Made before the monitor starts: its updates arrive on a concurrent queue.
        let pathGate = PathUpdateGate { [weak self] changed in self?.pathBecameSatisfied(changed: changed) }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // The first update only reports the starting path, and the gate
            // returns no difference for it.
            let difference = pathGate.receive(PathSignature(path))
            // A repeat of the path already logged adds nothing; the gate notes it at debug.
            if difference?.any != false {
                DiagLog.network(difference == nil ? "Network path at start" : "Network path changed", path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        pathMonitor = monitor
    }

    deinit {
        pathMonitor?.cancel()
        lock.withLock { $0.ownDeviceNoticeTask?.cancel() }
    }

    private func scheduleReconnect() {
        let pending: (delay: TimeInterval, token: Int, attempt: Int)? = lock.withLock {
            guard $0.wantsConnection else { return nil }
            $0.reconnectAttempt += 1
            $0.reconnectToken += 1
            return (min(pow(2, Double($0.reconnectAttempt - 1)), 60), $0.reconnectToken, $0.reconnectAttempt)
        }
        guard let (delay, token, attempt) = pending else { return }
        DiagLog.info(.connection, "Reconnect scheduled", .duration("delay", delay), .int("attempt", attempt))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lock.withLock({ $0.wantsConnection && $0.reconnectToken == token }), case .disconnected = self.client.state else { return }
            self.login()
        }
    }

    /// Tells the server whether the user is looking at the app (XEP-0352), so
    /// it can hold back presence and chat-state noise while backgrounded.
    public func setActive(_ active: Bool) {
        let away = lock.withLock { state -> TimeInterval? in
            let since = state.idleSince
            state.isActive = active
            state.idleSince = active ? nil : since ?? Date()
            return active ? since.map { Date().timeIntervalSince($0) } : nil
        }
        guard isConnected else { return }
        // A suspended app's connection is often dead by the time it returns.
        if active { verifyConnection() }
        reportClientState()
        if active, Self.recheckRooms(afterAbsence: away) { selfPingRooms() }
    }

    /// Tells the server the user can't be looking at the app while the Mac's
    /// screen is locked (XEP-0352), so it holds back what only a person at
    /// the screen needs, and active again on unlock. Only the client state
    /// follows this: `isActive`, and with it everything that keys on being in
    /// the app, is unchanged.
    public func setScreenLocked(_ locked: Bool) {
        let changed = lock.withLock { state in
            defer { state.isScreenLocked = locked }
            return state.isScreenLocked != locked
        }
        guard changed, isConnected else { return }
        reportClientState()
    }

    /// How long the app is away before coming back is worth asking every
    /// room whether we are still in it. A banner, Control Center, Face ID or
    /// a Cmd-Tab on the Mac takes seconds and the stream is untouched; rooms
    /// drop us over a restart or a connection that resumed after a while.
    static let roomRecheckAbsence: TimeInterval = 60

    static func recheckRooms(afterAbsence away: TimeInterval?) -> Bool {
        away.map { $0 >= roomRecheckAbsence } ?? false
    }

    /// Tells the server whether the user is looking at the app (not on the
    /// Mac, which always says active: see `Policy.reportsInactive`). It's sent
    /// on every connect, resumed or not: a new session starts active, which is
    /// wrong on an iPhone that connects in the background, and a resumed one
    /// keeps whatever the server last had. Not while catching up, though: an
    /// inactive session has its archive results held back by the server, which
    /// stalls the catch-up for a minute; the end of the sync calls this again.
    ///
    /// What the server holds while we're inactive is owed a refetch once we
    /// say active: see `HeldNotifications`. The state is sent under
    /// `clientStateLock`, so concurrent calls reach the wire in the order
    /// they were decided in.
    private func reportClientState() {
        guard policy.reportsClientState, isConnected else { return }
        let refresh: HeldNotifications.Refresh? = clientStateLock.withLock {
            let (isActive, locked, syncing) = lock.withLock { ($0.isActive, $0.isScreenLocked, $0.isSyncing) }
            guard !syncing else { return nil }
            let active = (isActive || !policy.reportsInactive) && !locked
            // A server without CSI holds nothing.
            guard client.module(.csi).setState(active) else { return nil }
            return lock.withLock { $0.held.sent(active: active) }
        }
        if let refresh { refreshAfterHeldNotifications(refresh) }
    }

    /// Reads again what the server held: read states at once, bookmarks and
    /// settings when `HeldNotifications` says. A refresh that fails is owed
    /// again at the next return, and a return can send "active" on a stream
    /// that turns out dead.
    private func refreshAfterHeldNotifications(_ refresh: HeldNotifications.Refresh) {
        guard policy.syncsAccountState else { return }
        let generation = refresh.generation
        if refresh.readStates {
            fetchDisplayed { [weak self] succeeded in
                if !succeeded { self?.owe(.readStates, generation: generation) }
            }
        }
        switch refresh.slow {
        case .none: break
        case .now(let parts): refreshSlowNodes(parts, generation: generation)
        case .after(let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isConnected else { return }
                let due = self.lock.withLock { state in
                    ((state.isActive || !self.policy.reportsInactive) && !state.isScreenLocked) ? state.held.takeSlow(generation: generation) : []
                }
                if !due.isEmpty { self.refreshSlowNodes(due, generation: generation) }
            }
        }
    }

    /// A read that couldn't be made is owed again at the next return to the
    /// app, and the next catch-up reads everything anyway.
    private func owe(_ parts: HeldNotifications.Parts, generation: Int) {
        lock.withLock { $0.held.failed(parts, generation: generation) }
    }

    private func refreshSlowNodes(_ parts: HeldNotifications.Parts, generation: Int) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            async let bookmarks: Bool = withCheckedContinuation { continuation in
                if parts.contains(.bookmarks) {
                    self.refreshBookmarks { continuation.resume(returning: $0) }
                } else {
                    continuation.resume(returning: true)
                }
            }
            // Settings are only read again once their first sync has started,
            // as it waits for the catch-up.
            let settingsStarted = self.lock.withLock { $0.settingsSync.syncStarted }
            let settings = parts.contains(.settings) && settingsStarted ? await self.runSettingsSync() : .done
            if !(await bookmarks) { self.owe(.bookmarks, generation: generation) }
            if settings.isOwed { self.owe(.settings, generation: generation) }
        }
    }

    var isConnected: Bool {
        if case .connected = client.state { return true }
        return false
    }

    static let defaultConnectionGrace: TimeInterval = 8

    /// Whether the connection is up and trusted, waiting up to the grace for
    /// it to come back if the session is reconnecting or checking the old
    /// stream (the user has just returned to the app). False at once if it
    /// isn't going to: signed out, or the server refused the account. It
    /// doesn't wait for the archive catch-up, which these actions don't need.
    func waitForConnection() async -> Bool {
        if isConnected, !livenessPending.value { return true }
        if !isConnected {
            guard lock.withLock({ $0.wantsConnection }) else { return false }
            if case .failed = state.value { return false }
        }
        let grace = lock.withLock { $0.connectionGrace }
        let connected = try? await withTimeout(grace) { [self] () -> Bool in
            for await (value, pending) in state.combineLatest(livenessPending).values {
                if case .failed = value { return false }
                guard case .connected = value, !pending else { continue }
                // Martin publishes the state before it holds it.
                for _ in 0..<20 {
                    if isConnected { return true }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            return false
        }
        return connected ?? false
    }

    /// What Martin's connector reports about each endpoint, as the diagnostics log has it.
    static func logConnect(_ event: SocketConnectorNetwork.ConnectEvent) {
        switch event {
        case .resolved(let candidates, let fallback, let duration):
            DiagLog.info(.connection, "SRV lookup finished", .int("records", candidates), .bool("fallbackHost", fallback), .duration("took", duration))
        case .resolveTimedOut(let duration):
            DiagLog.notice(.connection, "SRV lookup timed out", .duration("took", duration))
        case .attempting(let kind, let port):
            DiagLog.info(.connection, "Trying an endpoint", .value("kind", kind), .value("portKind", PortKind(port)))
        case .ready(let kind, let port, let family, let duration):
            DiagLog.info(.connection, "Endpoint connected", .value("kind", kind), .value("portKind", PortKind(port)), .value("family", family), .duration("took", duration))
        case .failed(let kind, let port, let reason, let error, let code, let duration, let triesNext):
            var fields: [DiagField] = [.value("kind", kind), .value("portKind", PortKind(port)), .value("reason", reason), .duration("took", duration), .bool("triesNext", triesNext)]
            if let error { fields += [.value("errorKind", error), .int("errorCode", code)] }
            DiagLog.log(.error, .connection, "Endpoint failed", fields)
        }
    }

    private func logAuthorization(_ state: AuthModule.AuthorizationStatus) {
        // The module `AuthModule.login()` chose for this stream; each clears its mechanism when it starts.
        let sasl2 = client.module(.sasl2)
        let usesSasl2 = sasl2.isAvailable
        let kind = SaslKind(mechanism: usesSasl2 ? sasl2.lastMechanism : client.modulesManager.moduleOrNil(.sasl)?.lastMechanism)
        switch state {
        case .inProgress:
            DiagLog.info(.connection, "Signing in", .value("mechanism", kind))
        case .authorized:
            DiagLog.info(.connection, "Signed in", .value("mechanism", kind), .bool("withToken", usesSasl2 && sasl2.signedInWithToken))
        case .error(let error):
            DiagLog.error(.connection, "Sign-in failed", .value("mechanism", kind), .value("reason", AuthFailure(error)))
        case .notAuthorized, .expectedAuthorization:
            break
        }
    }

    func logDisconnection(_ reason: XMPPClient.State.DisconnectionReason, failure: Failure?) {
        let failureClass: FailureClass = switch failure {
        case .fatal: .fatal
        case .transient: .transient
        case nil: .none
        }
        var fields: [DiagField] = [.value("reason", DisconnectKind(reason)), .value("outcome", failureClass)]
        switch reason {
        case .streamError(let element):
            fields.append(.value("condition", StreamCondition(name: Self.streamCondition(of: element))))
        case .authenticationFailure(let error):
            fields.append(.value("auth", AuthFailure(error)))
        default:
            break
        }
        DiagLog.log(failureClass == .none ? .info : .notice, .connection, "Disconnected", fields)
    }

    /// The stream errors a server answers a stanza it dislikes with. Others (a conflict, a shutdown,
    /// a timeout, its own fault) say nothing about what we sent.
    static let streamErrorsFromStanzas: Set<StreamCondition> = [
        .policyViolation, .notWellFormed, .invalidXml, .badFormat, .restrictedXml, .improperAddressing,
        .invalidFrom, .unsupportedStanzaType, .badNamespacePrefix, .invalidNamespace,
    ]
    static let strikesToGiveUp = 3

    /// A stanza that a server keeps closing the stream on is written first again on every
    /// reconnect, and everything queued behind it never goes out. But what the server stops at is
    /// not always the cause: stanzas of other chats go out on queues of their own, and a rate
    /// limit closes the stream with `policy-violation` too. So the first stream error blames the
    /// oldest stanza the server hadn't acknowledged, as long as it is a message of ours (it
    /// acknowledged all before, see `requestAcknowledgement` before the first resend), and that
    /// puts it on probation: the next session sends it alone, first, and holds the rest. A
    /// stream error then, with nothing else of ours unacknowledged, is a confirmed strike; the
    /// third strike gives the stanza up. Anything else (another condition, other stanzas
    /// unacknowledged, a stream without stream management) gives no strike. Runs before the
    /// queue is cleared, which only a new session does.
    func blameUnacknowledged(for element: Element) {
        let condition = StreamCondition(name: Self.streamCondition(of: element))
        let probing = lock.withLock { state -> String? in
            defer { state.probation = nil; state.probationToken += 1 }
            return state.probation?.id
        }
        guard Self.streamErrorsFromStanzas.contains(condition),
              let queue = client.modulesManager.moduleOrNil(.streamManagement)?.unacknowledgedStanzas,
              let stanza = queue.first, stanza.name == "message", let id = stanza.id else { return }
        let alone = !queue.dropFirst().contains { $0.name == "message" }
        let blamed = Redacted.id(id)
        let reason = SendFailure.serverClosedStream
        let pendingKind = pendingKind(of: stanza, id: id)
        let giveUp: () -> Void
        if let pendingKind {
            giveUp = { [self] in
                switch pendingKind {
                case .reaction: DiagLog.error(.send, "Reactions given up", .id("stanza", blamed), .value("reason", reason))
                case .action: DiagLog.error(.send, "Correction or retraction given up", .id("stanza", blamed), .value("reason", reason))
                }
                giveUpPending(pendingKind, id: id, because: String(localized: "The server closed the connection each time this was sent."))
            }
        } else if let message = try? database.pendingOutgoing(remoteId: id) {
            giveUp = { [self] in
                DiagLog.error(.send, "Marked failed", .id("msg", blamed), .value("reason", reason))
                try? database.markFailed(
                    conversationId: message.conversationId, remoteId: id,
                    error: String(localized: "The server closed the connection each time this message was sent."),
                )
            }
        } else {
            return
        }
        let strikes = lock.withLock { state -> Int? in
            let before = state.streamErrorStrikes[id] ?? 0
            // On probation it counts if it was alone. Otherwise only a first strike does: one
            // that was already struck gets no more from a stream it shared with others.
            guard probing == id ? alone : (before == 0 && probing == nil) else { return nil }
            state.streamErrorStrikes[id] = before + 1 >= Self.strikesToGiveUp ? nil : before + 1
            return before + 1
        }
        guard let strikes else { return }
        DiagLog.notice(.send, "Stream closed on a stanza of ours", .id("stanza", blamed), .value("condition", condition), .int("strikes", strikes), .bool("alone", alone))
        if strikes >= Self.strikesToGiveUp { giveUp() }
    }

    /// Whether `id` waits for the stanza on probation to be settled.
    func isHeldByProbation(_ id: String) -> Bool {
        lock.withLock { state in state.probation.map { $0.id != id } ?? false }
    }

    /// Puts the first of `ids` that has a strike on probation, if none is. What else is pending
    /// stays unsent (`isHeldByProbation`) until `endProbation`.
    func beginProbation(among ids: [String]) {
        let started = lock.withLock { state -> (id: String, token: Int, wait: TimeInterval)? in
            guard state.probation == nil, let id = ids.first(where: { state.streamErrorStrikes[$0] != nil }) else { return nil }
            state.probationToken += 1
            state.probation = Probation(id: id, token: state.probationToken)
            return (id, state.probationToken, state.probationTimeout)
        }
        guard let started else { return }
        DiagLog.notice(.send, "Probation begins", .id("stanza", Redacted.id(started.id)))
        DispatchQueue.global().asyncAfter(deadline: .now() + started.wait) { [weak self] in
            self?.endProbation(token: started.token)
        }
    }

    /// Lets the held stanzas go, once the one on probation is acknowledged or the wait is over.
    func endProbation(token: Int? = nil, acknowledged id: String? = nil) {
        let ended = lock.withLock { state -> Bool in
            guard let probation = state.probation, token.map({ $0 == probation.token }) ?? true, id.map({ $0 == probation.id }) ?? true else { return false }
            state.probation = nil
            state.probationToken += 1
            return true
        }
        guard ended else { return }
        DiagLog.info(.send, "Probation ends", .bool("acknowledged", id != nil))
        // A room's catch-up can put a stanza on probation in an extension too,
        // which sends nothing it didn't write itself.
        guard policy.resendsPending else { return }
        DispatchQueue.global().async { [weak self] in self?.sendUnclaimedPending() }
    }

    private func clientStateChanged(_ state: XMPPClient.State) {
        switch state {
        case .connecting:
            startWatchdog()
            self.state.send(.connecting)
        case .disconnecting:
            break
        case .disconnected(let reason):
            // The connector it watched is gone with this attempt; holding the
            // subscription would keep it alive until the next one starts.
            lock.withLock { $0.watchdogSubscription = nil }
            cancelAllRejoins()
            iceServerCache.reset()
            failFileTransfers()
            callStep(.connectionLost)
            let failure = lock.withLock {
                $0.attempt += 1
                defer { $0.pendingFailure = nil }
                return $0.pendingFailure
            } ?? Self.failure(for: reason)
            // Not the state a session starts in, before any login.
            if lock.withLock({ $0.connectStartedAt }) != nil { logDisconnection(reason, failure: failure) }
            if case .streamError(let element) = reason, case .connected = self.state.value {
                blameUnacknowledged(for: element)
            } else {
                lock.withLock { $0.probation = nil; $0.probationToken += 1 }
            }
            if case .authenticationFailure(let error) = reason, switchToCandidatePassword(after: error) {
                // Off Martin's state callback, which login() would re-enter.
                DispatchQueue.global().async { [weak self] in self?.reconnectNow() }
                return
            }
            let retryNow = lock.withLock {
                defer { $0.retryNow = false }
                return $0.retryNow
            }
            if retryNow, case .transient(let message) = failure {
                self.state.send(.disconnected(error: message))
                // Off Martin's state callback, which login() would re-enter.
                DispatchQueue.global().async { [weak self] in self?.reconnectNow() }
                return
            }
            switch failure {
            case .fatal(let message):
                lock.withLock { $0.wantsConnection = false }
                self.state.send(.failed(message))
            case .transient(let message):
                self.state.send(.disconnected(error: message))
                scheduleReconnect()
            case nil:
                self.state.send(.disconnected(error: nil))
                scheduleReconnect()
            }
        case .connected(let resumed):
            let took = lock.withLock { $0.connectStartedAt.map { Date().timeIntervalSince($0) } }
            DiagLog.info(.connection, "Connected", .bool("resumed", resumed), .duration("took", took ?? 0))
            let attempt = lock.withLock {
                $0.watchdogSubscription = nil
                $0.reconnectAttempt = 0
                $0.attempt += 1
                return $0.attempt
            }
            callStep(.connectionRestored)
            lock.withLock { $0.reachedStream = true }
            // A resumed stream replays the journal itself, as it resumes (`replayJournal`).
            if policy.ownsSharedStream, !resumed { runOnceConnected(attempt: attempt) { [self] in ringJournaledCalls() } }
            runOnceConnected(attempt: attempt) { [self] in resolveHeldGroupMessages() }
            runOnceConnected(attempt: attempt) { [self] in sendUnsentCallMessages() }
            // A ping sent on the old stream says nothing about this one.
            livenessPending.send(false)
            if resumed, policy.resumesSharedStream, lock.withLock({ state in
                defer { state.resumedCatchUpStarted = true }
                return !state.resumedCatchUpStarted
            }) {
                // The stream was the app's: the server asks nothing and sends
                // no features again, so what a new session starts at connect
                // is started here, and the extension waits for it.
                DiagLog.info(.connection, "Resumed the app's stream")
                lock.withLock {
                    $0.isSyncing = true
                    $0.awaitsAccountDiscovery = true
                    $0.catchUpInterrupted = false
                }
                self.state.send(.connected(isSyncing: true))
                runOnceConnected(attempt: attempt) { [self] in discoverAndCatchUp() }
            } else if resumed {
                self.state.send(.connected(isSyncing: lock.withLock { $0.isSyncing }))
                // Martin publishes the state before it holds it, so in here the
                // client still reads as connecting and everything that checks
                // `isConnected` would do nothing.
                runOnceConnected(attempt: attempt) { [self] in resumeWork() }
            } else {
                ticketFailed()
                // A resumed session keeps the server's presence and room
                // state, which it won't send again; only a new one starts over.
                clearPresences()
                clearRooms()
                confirmPassword()
                lock.withLock {
                    $0.isSyncing = true
                    $0.owedOnResume = []
                    $0.catchUpInterrupted = false
                    $0.interruptedRooms = []
                    $0.withdrawnWhileDown = [:]
                    // What was unacknowledged is sent again, and claims anew.
                    $0.sends.reset()
                    $0.pendingStanzas.reset()
                    $0.deferredSends = [:]
                    $0.repended = []
                    $0.uploadService = nil
                    $0.mucService = nil
                    $0.publishedDisplayed = [:]
                    $0.readStatesAwaitingMessage = []
                    // A configuration sent on the old stream won't be answered on this one.
                    $0.nodeReconfigurations = [:]
                    $0.displayedFetches = 0
                    $0.settingsSync.startSession()
                    $0.repeatedContactRequests = []
                    $0.awaitsRoster = true
                    $0.prunesContactRequests = policy.prunesContactRequests
                    // What we last told each contact went with the old session.
                    for peer in $0.chatStates.keys { $0.chatStates[peer]?.sent = nil }
                    $0.sentDisplayed = [:]
                }
                // Anything a query that never finished left behind. New
                // queries follow, so the old ones' marks are no use.
                flushArchive()
                lock.withLock { $0.failedArchiveQueries = [] }
                self.state.send(.connected(isSyncing: true))
                if policy.enablesCarbons { enableCarbons() }
                // The archive module only knows which MAM version the server
                // speaks once account discovery returns, which Martin starts
                // itself. Asking again would make OMEMO publish its bundle
                // twice at once, and a new device's keys clobber each other.
                lock.withLock { $0.awaitsAccountDiscovery = true }
                runOnceConnected(attempt: attempt) { [self] in
                    accountDiscovered(client.module(.disco).accountDiscoResult)
                }
                runOnceConnected(attempt: attempt) { [self] in fetchRoster(attempt: attempt) }
            }
        }
    }

    /// Bind 2 enables carbons while signing in, when the server takes that
    /// inline; then a second request would only repeat it.
    func enableCarbons() {
        if client.modulesManager.moduleOrNil(Sasl2Module.IDENTIFIER)?.carbonsEnabledInline == true { return }
        let started = lock.withLock { $0.attempt }
        Task { [weak self] in
            guard let self else { return }
            await warnings.attempt(
                "carbons", title: String(localized: "Other devices' messages may not show"),
                friendly: String(localized: "The server wouldn't copy your other devices' messages here"),
                stillWanted: { [weak self] in self?.attemptIsCurrent(started) ?? false },
                retry: { [weak self] in try await self?.requestCarbons() },
            ) { [self] in try await retryingPassingErrors { try await requestCarbons() } }
        }
    }

    private func requestCarbons() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.module(.messageCarbons).enable { continuation.resume(with: $0.map { _ in () }.mapError { $0 }) }
        }
    }

    enum ConnectedStep: Equatable {
        case run
        /// Martin hasn't stored the new state yet.
        case wait
        /// Another connection came up or this one dropped.
        case abandon
    }

    static func connectedStep(isConnected: Bool, startedOn: Int, now: Int) -> ConnectedStep {
        if startedOn != now { return .abandon }
        return isConnected ? .run : .wait
    }

    /// Runs `work` off Martin's state callback, once the client reads as
    /// connected, unless the connection changed meanwhile. It waits for as
    /// long as that connection lasts, since `work` is what ends the sync or
    /// resumes the session: after `tries` quick looks, a slower one each time.
    func runOnceConnected(attempt: Int, tries: Int = 200, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            switch Self.connectedStep(isConnected: isConnected, startedOn: attempt, now: lock.withLock { $0.attempt }) {
            case .run: work()
            case .abandon: break
            case .wait:
                let wait: DispatchTimeInterval = tries > 0 ? .milliseconds(10) : .milliseconds(250)
                DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.runOnceConnected(attempt: attempt, tries: max(tries - 1, 0), work)
                }
            }
        }
    }

    /// What Martin starts itself at a new session's bind, and a resumed
    /// stream doesn't: finding out what the server offers, which the archive
    /// query needs to know, then the catch-up.
    private func discoverAndCatchUp() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await discoverAccountFeatures()
                accountDiscovered(client.module(.disco).accountDiscoResult)
            } catch {
                accountDiscoveryFailed(error)
            }
        }
    }

    /// What a resumed stream needs done, which no new session's discovery
    /// and catch-up would do for it.
    func resumeWork() {
        reportClientState()
        let owed = lock.withLock { $0.owedOnResume }
        if owed.contains(.presence) { sendPresence() }
        sendWithdrawals()
        // Rooms we were in may have dropped us while we were away.
        selfPingRooms()
        // Rooms whose join was cut off wait for answers that won't come.
        rejoinStuckRooms()
        // Discovery doesn't run again on a resumed stream, so a failed
        // key publish from before the drop would never be retried.
        omemo.module.resumeRegistrationIfNeeded()
        // Nothing runs a catch-up on a resumed stream, so what was
        // written to the dead connection, or never written, is sent
        // here; what the server may still hold is claimed and left.
        flushOutboxes()
        resumeInterruptedCatchUps()
        if owed.contains(.push) { enablePush() }
        if owed.contains(.profileAccess) {
            Task.detached(priority: .utility) { [weak self] in await self?.reconcileProfileAccess() }
        }
        // A settings sync the drop cut off never reconciled or started
        // watching for changes; one that finished only has changes to send.
        if lock.withLock({ $0.settingsSync.syncStarted && !$0.settingsSync.syncCompleted }) {
            let generation = lock.withLock { $0.held.generation }
            syncSettings { [weak self] outcome in
                if outcome.isOwed { self?.owe(.settings, generation: generation) }
            }
        } else {
            requestSettingsPublish()
        }
    }

    /// Martin resets the result at the start of each session, so any
    /// identities in it are this session's.
    private func accountDiscovered(_ result: DiscoveryModule.DiscoveryInfoResult) {
        guard !result.identities.isEmpty || !result.features.isEmpty else { return }
        warnings.clear("discovery")
        // Read here rather than from the archive module, which learns it
        // from the same result in its own time and forgets it on resets.
        let version = MessageArchiveManagementModule.Version.values.first { result.features.contains($0.rawValue) }
        estimateServerClock()
        startSync(archiveVersion: version)
    }

    private func startSync(archiveVersion version: MessageArchiveManagementModule.Version?) {
        let start = lock.withLock { state in
            state.archiveVersion = version
            defer { state.awaitsAccountDiscovery = false }
            return state.awaitsAccountDiscovery
        }
        if start {
            if policy.catchesUpOnConnect {
                catchUp()
            } else {
                lock.withLock { $0.isSyncing = false }
                state.send(.connected(isSyncing: false))
                reportClientState()
            }
        }
    }

    /// Martin's discovery got an error, or no answer, and asks nothing again
    /// itself: the session would stay syncing for good, with nothing sent,
    /// no push and no settings. It asks again while the error can pass, and
    /// then goes on without knowing the server's features, as a server that
    /// has none of them, rather than not at all.
    private func accountDiscoveryFailed(_ error: Error) {
        let attempt = lock.withLock { state -> Int? in state.awaitsAccountDiscovery ? state.attempt : nil }
        guard let attempt else { return }
        Task { [weak self] in
            guard let self else { return }
            // Whatever the error: one that kept passing through every retry is
            // still a server that never said what it supports. A success
            // returns: the answer reaches `accountDiscovered` through its subscription.
            let outcome = await warnings.attempt(
                "discovery", title: String(localized: "Server features unknown"),
                friendly: String(localized: "The server didn't say what it supports"),
                stillWanted: { [weak self] in
                    guard let self else { return false }
                    return attemptIsCurrent(attempt) && lock.withLock { $0.awaitsAccountDiscovery }
                },
                retry: { [weak self] in try await self?.discoverAccountFeatures() },
            ) { [self] in try await retryingPassingErrors(afterFailure: error) { try await discoverAccountFeatures() } }
            if case .posted = outcome { startSync(archiveVersion: nil) }
        }
    }

    private func discoverAccountFeatures() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.module(.disco).discoverAccountFeatures { continuation.resume(with: $0.map { _ in () }.mapError { $0 }) }
        }
    }

    private static func streamCondition(of element: Element) -> String? {
        // ejabberd puts its `text` first, and it is not a condition.
        element.children.first { $0.xmlns == "urn:ietf:params:xml:ns:xmpp-streams" && $0.name != "text" }?.name
    }

    private static func failure(for reason: XMPPClient.State.DisconnectionReason) -> Failure? {
        switch reason {
        case .none: nil
        case .timeout, .noRouteToServer: .transient("Couldn't reach the server.")
        // Validation fails the same way on every attempt.
        case .sslCertError: .fatal("The server's certificate isn't trusted.")
        // The same message as when the features lack STARTTLS and TLS is required.
        case .xmlError(SocketConnectorNetwork.startTLSNotOffered): .fatal("The server doesn't support encryption.")
        case .xmlError: .transient("The server sent something unexpected.")
        case .streamError(let element):
            switch Self.streamCondition(of: element) {
            case "host-unknown": .fatal("This server doesn't host that address.")
            case "conflict": .transient("Signed in from somewhere else with the same name.")
            case "system-shutdown": .transient("The server is shutting down.")
            case "policy-violation": .transient("The server refused the connection.")
            case let condition: .transient("The server closed the connection (\(condition ?? "stream error")).")
            }
        // Final, and shown as it is: no retry would change what the server
        // offers, and signing in again is the user's to decide.
        case .authenticationFailure(let weaker as WeakerSignInError): .fatal(weaker.localizedDescription)
        case .authenticationFailure(let error):
            switch error as? SaslError {
            case .not_authorized, .invalid_authzid: .fatal("Wrong address or password.")
            case .temporary_auth_failure: .transient("The server couldn't sign you in right now.")
            case .server_not_trusted: .fatal("The server failed to prove its identity.")
            case .mechanism_too_weak, .invalid_mechanism: .fatal("The server doesn't support a secure sign-in method.")
            case .aborted, .incorrect_encoding, nil: .fatal("Sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Inbound

    /// A stanza addressed to this resource: either a carbon wrapper, an archive
    /// result (handled by the MAM module), or a plain message.
    func handleTopLevel(_ stanza: Martin.Message) {
        switch Self.unwrapCarbon(stanza, account: account) {
        case .carbon(let inner, let sent):
            handle(inner, source: .carbon(sent: sent))
            return
        case .dropped:
            if let from = stanza.from { logger.warning("Dropping forged carbon from \(from.stringValue, privacy: .private)") }
            return
        case .plain:
            break
        }
        if stanza.element.children.contains(where: { $0.name == "result" && ($0.xmlns?.hasPrefix("urn:xmpp:mam:") ?? false) }) {
            return
        }
        handle(stanza, source: .live)
    }

    /// What a top-level message is as a carbon.
    enum CarbonUnwrap {
        case plain
        /// A forged or malformed carbon, which is nobody's to act on.
        case dropped
        case carbon(Martin.Message, sent: Bool)
    }

    /// The message a carbon wraps, if `stanza` is one. Only our own server may send carbons: from our bare
    /// JID, or no `from`. A resumed stream replays what the server held for it with a `<delay>` on the
    /// wrapper, which is copied onto the inner message: without it the message, and a call offer in it,
    /// would read as happening now.
    static func unwrapCarbon(_ stanza: Martin.Message, account: JID) -> CarbonUnwrap {
        guard let carbon = stanza.element.children.first(where: { $0.xmlns == MessageCarbonsModule.MC_XMLNS }) else { return .plain }
        if let from = stanza.from, from.resource != nil || JID(from) != account { return .dropped }
        guard carbon.name == "sent" || carbon.name == "received",
              let forwarded = carbon.firstChild(name: "forwarded", xmlns: "urn:xmpp:forward:0")?.firstChild(name: "message") else { return .dropped }
        forwarded.addChildren(stanza.element.filterChildren(name: "delay", xmlns: NS.delay))
        guard let inner = Stanza.from(element: forwarded) as? Martin.Message else { return .dropped }
        return .carbon(inner, sent: carbon.name == "sent")
    }

    func handle(_ stanza: Martin.Message, source: InboundMessage.Source, isHistory: Bool = false, query: String = "") {
        if Self.isInvitation(stanza) {
            // Archived ones were dealt with when they arrived.
            if source == .live { invitationReceived(stanza) }
            return
        }
        let from = stanza.from.flatMap { JID($0) }
        let to = stanza.to.flatMap { JID($0) }
        if let from, isGroup(from) {
            // Errors bounce our group messages; private messages through
            // the room aren't supported.
            if stanza.type == .error {
                handleRoomStanza(stanza, source: source, query: query)
            } else if source == .live, !Self.isDelayed(stanza), stanza.from?.resource == nil {
                // The room tells of an affiliation change of someone who isn't
                // in it (XEP-0045 9.3-9.8) in a message without a type, which
                // the groupchat route never sees. Only its bare address counts:
                // an occupant's would let anyone rewrite the member list.
                affiliationChanged(in: from, stanza)
            }
            return
        }
        if let to, isGroup(to) { return }
        if routeBounce(stanza) { return }

        // Calls are signalled in messages of their own, which carry nothing
        // else and are never encrypted.
        if let signal = CallSignal(stanza, account: account, source: source, clockOffset: serverClockOffset) {
            callSignalReceived(signal, source: source, isHistory: isHistory, query: query)
            return
        }
        if source == .live, let sid = CallSignal.proposeReceipt(in: stanza) { callProposeDelivered(sid) }

        var encryption = Message.Encryption.none
        var undecryptableReason: Message.UndecryptableReason?
        var sender: (device: Int32?, trust: OMEMODevice.Trust?)?
        if stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy) != nil {
            let from = from ?? account
            let archived = source.isArchived
            let result = omemo.decrypt(stanza, from: from, ownCopy: archived && from == account, isHistory: isHistory, sentAt: source.archivedAt ?? Date())
            switch result {
            case .decrypted(let device, let trust):
                encryption = .omemo
                sender = (device, trust)
            case .ignore, .ownCopy:
                // Still note the archive id of messages we already have, or
                // our own encrypted messages would look unsent and be resent.
                if case .archive = source, let inbound = InboundMessage(stanza, account: account, source: source, clockOffset: serverClockOffset) {
                    // After what came before it in the archive.
                    flushArchive(query: query, endsPage: false)
                    try? database.confirmArchived(inbound)
                    publishReadStateAwaiting(inbound)
                    // We wrote there, so we'd read what came before, though
                    // a new device can't read what.
                    if case .ownCopy = result { try? database.markRead(before: inbound) }
                }
                return
            case .failed, .unvouched:
                // Only a room's claim is held back, so this is a failure.
                if case .failed(let reason) = result {
                    logger.warning("Couldn't decrypt message \(stanza.id ?? "?", privacy: .private): \(reason, privacy: .private)")
                }
                encryption = .omemoUndecryptable
                if case .failed = result {
                    let holders = omemo.keyHolders(in: stanza)
                    if !holders.forThisDevice {
                        undecryptableReason = .notForThisDevice
                        ReceiveEvent.log(.notEncryptedForThisDevice(room: nil, sender: from, forOtherOwnDevices: holders.forOtherOwnDevices))
                    }
                }
                // Keep a placeholder even if the sender sent no fallback body.
                if stanza.body?.isEmpty ?? true { stanza.body = "🔒" }
            }
        }
        guard var inbound = InboundMessage(stanza, account: account, source: source, encryption: encryption, clockOffset: serverClockOffset) else { return }
        inbound.undecryptableReason = undecryptableReason
        inbound.omemoDevice = sender?.device ?? nil
        inbound.omemoTrust = sender?.trust
        inbound.isHistory = isHistory
        noteChatStates(of: inbound, source: source)
        if case .archive = source {
            bufferArchived(inbound, query: query) { [weak self, inbound] result in
                self?.publishReadStateAwaiting(inbound)
                guard !isHistory else {
                    // Old, read and long answered: only a retraction still
                    // has something to clean up.
                    if let attachment = result.retractedAttachment { self?.attachments.remove(attachment) }
                    return
                }
                self?.stored(inbound, result, source: source)
            }
            return
        }
        do {
            stored(inbound, try database.ingest(inbound), source: source)
        } catch {
            logger.error("Failed to store message: \(error)")
        }
    }

    /// What follows storing a 1:1 stanza.
    private func stored(_ inbound: InboundMessage, _ result: IngestResult, source: InboundMessage.Source) {
        publishReadStateAwaiting(inbound)
        let consented = (try? database.hasConsented(inbound.peer)) == true
        if let message = result.editedMessage { events.send(.editedMessage(message)) }
        // Connecting sent what was pending already, so this one waits for no one else.
        if result.repended, let id = inbound.id {
            lock.withLock { $0.sends.release(id) }
            resendAfterBounce(passes: 1)
        }
        if let message = result.newMessage {
            events.send(.newMessage(message))
            // Asking tells their server we're online, and from which full
            // address, so a stranger's message alone doesn't: as with
            // receipts, only for people the user accepted.
            if !inbound.isOutgoing, consented { askAvatarIfFirstContact(inbound.peer) }
            // Fetching reveals our IP address to the sender's upload
            // server, so only for people we know.
            if let attachment = result.newAttachment, Self.trustsForAutoDownload(
                isOutgoing: inbound.isOutgoing, isPrivateGroup: false, trustsGroupMembers: false,
                isTrusted: consented,
            ) {
                autoDownload(attachment)
            }
        }
        // Also for a message we already had: the notification extension
        // stores what arrives while the app is away from the archive, where
        // receipts aren't due, and the server hands the app its live copy
        // when it comes back. This is the one to acknowledge (XEP-0184).
        if source == .live, !inbound.isOutgoing, !inbound.isError, inbound.requestsReceipt, inbound.body != nil,
           result.conversationId != nil, let id = inbound.id, consented {
            write(OutboundStanza.receipt(to: inbound.peer, for: id))
        }
        if let chatState = result.chatState, Self.isCurrentChatState(inbound, source: source) {
            events.send(.chatState(inbound.peer, chatState))
        }
        if let attachment = result.retractedAttachment { attachments.remove(attachment) }
    }

    /// Whether a chat state says what the sender is doing now. One read back
    /// from the archive or stamped with a delay is old news, and would end
    /// the indicator of someone typing at this moment.
    static func isCurrentChatState(_ inbound: InboundMessage, source: InboundMessage.Source) -> Bool {
        if inbound.isDelayed { return false }
        switch source {
        case .live, .carbon(sent: false): return true
        default: return false
        }
    }

    // MARK: Archive batches

    /// Holds an archived message until its page ends, to store the page in
    /// one transaction.
    func bufferArchived(_ inbound: InboundMessage, query: String = "", then stored: @escaping @Sendable (IngestResult) -> Void) {
        lock.withLockUnchecked { $0.archiveBuffer.append(ArchivedInbound(query: query, inbound: inbound, stored: stored)) }
    }

    /// Stores what the archive has delivered so far for one query, or for all
    /// of them without one, which only a connection reset does: it would
    /// store other queries' half-delivered pages. Each page's results arrive
    /// before its answer, so a page's callback flushes its own query whole;
    /// another query's results stay for its own page to store, or lose.
    /// Returns false if the database refused the page, or an earlier flush
    /// in the middle of it (`endsPage: false`). Whoever tracks a cursor must
    /// then leave it where it was, so the next catch-up reads the page
    /// again; storing a message twice is harmless, as ingest matches it to
    /// the copy it has by its ids.
    @discardableResult
    func flushArchive(query: String? = nil, endsPage: Bool = true) -> Bool {
        let (batch, signals, failedEarlier) = lock.withLockUnchecked { state -> ([ArchivedInbound], [ArchivedCallSignal], Bool) in
            guard let query else {
                defer { state.archiveBuffer = []; state.archivedCallSignals = [] }
                return (state.archiveBuffer, state.archivedCallSignals, false)
            }
            let batch = state.archiveBuffer.filter { $0.query == query }
            let signals = state.archivedCallSignals.filter { $0.query == query }
            state.archiveBuffer.removeAll { $0.query == query }
            state.archivedCallSignals.removeAll { $0.query == query }
            return (batch, signals, endsPage && state.failedArchiveQueries.remove(query) != nil)
        }
        guard !batch.isEmpty || !signals.isEmpty else { return !failedEarlier }
        do {
            let (results, calls) = try database.ingest(batch.map(\.inbound), callSignals: signals.map { ($0.signal, $0.isHistory) }, account: account)
            for (item, result) in zip(batch, results) { item.stored(result) }
            for (row, signal) in zip(calls, signals) where !signal.isHistory {
                if let row { events.send(.newMessage(row)) }
            }
            return !failedEarlier
        } catch {
            logger.error("Failed to store archived messages: \(error)")
            // Whoever's results were dropped must not report their page stored.
            if let query {
                if !endsPage { lock.withLockUnchecked { _ = $0.failedArchiveQueries.insert(query) } }
            } else {
                let queries = Set(batch.map(\.query) + signals.map(\.query))
                lock.withLockUnchecked { $0.failedArchiveQueries.formUnion(queries) }
            }
            return false
        }
    }

    // MARK: Delivery

    /// The server has the stanza, by XEP-0198 or by `confirmByPing`: a message
    /// of ours is sent.
    func acknowledged(_ stanza: Stanza) {
        if let id = stanza.id {
            lock.withLock { _ = $0.streamErrorStrikes.removeValue(forKey: id) }
            endProbation(acknowledged: id)
            // That write bounced and is to be sent again; its acknowledgement
            // is not the new one's.
            if lock.withLock({ $0.repended.contains(id) }) { return }
        }
        if let id = stanza.id, acknowledgePending(stanza, id: id) { return }
        guard stanza.name == "message", let message = stanza as? Martin.Message, message.type == .chat || message.type == .groupchat,
              message.body != nil || message.firstChild(name: "encrypted", xmlns: NS.omemoLegacy) != nil,
              message.firstChild(name: "replace", xmlns: NS.correction) == nil,
              let id = message.id, let peer = message.to.flatMap({ JID($0) }) else { return }
        DiagLog.info(.send, "Server acknowledged", .id("msg", Redacted.id(id)))
        do {
            try database.markSent(peer: peer, remoteId: id)
        } catch {
            logger.error("Failed to mark \(id, privacy: .private) sent: \(error)")
        }
    }

    /// Without stream management the server never acknowledges a stanza, so
    /// a ping to it stands in. A stream's stanzas are handled in order, so any
    /// reply, an error from a server that doesn't know the ping too, shows it
    /// has read `stanza`. With no reply the stanza stays unacknowledged, as
    /// on a stream with management: a new session sends it again.
    private func confirmByPing(_ stanza: Stanza, attempt: Int = 1) {
        let started = Date()
        client.module(.ping).ping(Martin.JID(account.martin), timeout: Self.confirmationTimeout) { [weak self] result in
            guard let self else { return }
            if case .failure(.remote_server_timeout) = result {
                DiagLog.notice(.send, "Ping for confirmation timed out", .duration("waited", since: started))
                // A later ping's reply shows the server read this stanza too. With
                // none either, the stream is probably dead: checking it drops it,
                // and the session that follows sends the message again.
                if attempt < Self.confirmationPings {
                    confirmByPing(stanza, attempt: attempt + 1)
                } else {
                    verifyConnection()
                }
                return
            }
            DiagLog.info(.send, "Ping confirmed", .duration("took", since: started))
            acknowledged(stanza)
        }
    }

    /// Whether the stream has the server acknowledge what we write (XEP-0198).
    private var streamAcknowledges: Bool {
        client.modulesManager.moduleOrNil(.streamManagement)?.ackEnabled ?? false
    }

    /// Asks the server to acknowledge what was just written, if it will.
    func requestAcknowledgement() {
        guard streamAcknowledges else { return }
        client.modulesManager.moduleOrNil(.streamManagement)?.request()
    }

    // MARK: Presence and avatars

    /// A contact's availability, which is offline for one we have no presence of.
    public func presence(of jid: JID) -> ContactPresence {
        lock.withLock { Self.best(of: $0.resources[jid])?.availability } ?? .offline
    }

    /// The status message of a contact's most available resource, if they've set one.
    public func status(of jid: JID) -> String? {
        lock.withLock { Self.best(of: $0.resources[jid])?.status }
    }

    /// One connected resource of a contact.
    struct ResourcePresence: Sendable {
        var availability: ContactPresence
        var status: String?
        var order: Int
    }

    /// Our longest accepted status from a contact, as anyone can send any.
    static let maxContactStatusLength = 500

    /// Anyone can send presence, from as many resources and addresses as
    /// they like. Past these limits, a sender's oldest resource makes way for
    /// a new one, and a new sender is only taken if we're subscribed to them.
    static let maxResourcesPerSender = 16
    static let maxPresenceSenders = 2000

    func presenceChanged(_ presence: Presence) {
        guard let from = presence.from, let jid = JID(from), jid != account else { return }
        if isGroup(jid) {
            roomPresence(presence, room: jid)
            return
        }
        let resource = from.resource ?? ""
        // The roster is only read when the table is full, so a contact whose
        // presence beats the roster at sign-in is never turned away for it.
        let isFull = (presence.type == nil || presence.type == .available)
            && lock.withLock { $0.resources[jid] == nil && $0.resources.count >= Self.maxPresenceSenders }
        if isFull, (try? database.seesPresence(of: jid)) != true { return }
        let subscribed = isFull ? (try? database.presenceSubscriptions()) ?? [] : []
        presencesPublishLock.lock()
        // What changed, if anything: the sender's best resource before and
        // after, and the stranger who made way for them.
        let change = lock.withLock { state -> (before: ResourcePresence?, best: ResourcePresence?, evicted: JID?)? in
            var evicted: JID?
            let before = Self.best(of: state.resources[jid])
            var resources = state.resources[jid] ?? [:]
            switch presence.type {
            case .unavailable, .error:
                resources[resource] = nil
            case nil, .available:
                if isFull {
                    // Everyone kept is a contact: there's no room for another.
                    guard let stranger = Self.stalestStranger(in: state.resources, subscribed: subscribed) else { return nil }
                    state.resources[stranger] = nil
                    evicted = stranger
                }
                if resources[resource] == nil, resources.count >= Self.maxResourcesPerSender,
                   let oldest = resources.min(by: { $0.value.order < $1.value.order })?.key {
                    resources[oldest] = nil
                }
                state.presenceCounter += 1
                let availability: ContactPresence = switch presence.show {
                case .dnd: .busy
                case .away, .xa: .away
                case .chat, .online, nil: .online
                }
                resources[resource] = ResourcePresence(
                    availability: availability,
                    status: Self.normalizedStatus(presence.status, limit: Self.maxContactStatusLength),
                    order: state.presenceCounter,
                )
            default:
                return nil
            }
            state.resources[jid] = resources.isEmpty ? nil : resources
            // Only this sender's summary changes; recounting everyone's made
            // a flood of resources cost the square of its size.
            return (before, Self.best(of: resources), evicted)
        }
        guard let change else {
            presencesPublishLock.unlock()
            return
        }
        // Repeats of what's already known, which a flood of presences is
        // mostly, publish nothing.
        if change.before?.availability != change.best?.availability || change.before?.status != change.best?.status {
            peerUpdates.send(PeerUpdate(jid: jid, presence: change.best?.availability, status: change.best?.status))
        }
        if let evicted = change.evicted {
            peerUpdates.send(PeerUpdate(jid: evicted, presence: nil, status: nil))
        }
        presencesPublishLock.unlock()
        // Coalesced: a presence for each contact arrives at sign-in, and each
        // full recount checks every online contact's capabilities.
        scheduleCallableUpdate()

        if change.best != nil {
            lock.withLock { $0.lastSeenSchedule.sawArriving(jid) }
        } else if change.before != nil, presence.type == .unavailable {
            contactWentOffline(jid)
        }

        // XEP-0153: an avatar hash in presence for clients without PEP avatars.
        // Fetching it tells their server we're online, which only those the
        // user added or approved may learn.
        if presence.type == nil || presence.type == .available, let hash = presence.vcardTempPhoto, !hash.isEmpty,
           (try? database.hasConsented(jid)) == true {
            vCardAvatarAnnounced(jid, hash: hash.lowercased())
        }
    }

    /// A contact's availability and status are those of their most available
    /// resource.
    private static func best(of resources: [String: ResourcePresence]?) -> ResourcePresence? {
        resources?.values.max(by: { ($0.availability, $0.order) < ($1.availability, $1.order) })
    }

    /// The sender we're not subscribed to who was heard from longest ago.
    private static func stalestStranger(in resources: [JID: [String: ResourcePresence]], subscribed: Set<JID>) -> JID? {
        var stalest: (jid: JID, order: Int)?
        for (jid, byResource) in resources where !subscribed.contains(jid) {
            let newest = byResource.values.lazy.map(\.order).max() ?? 0
            if newest < stalest?.order ?? .max { stalest = (jid, newest) }
        }
        return stalest?.jid
    }

    func clearPresences() {
        presencesPublishLock.lock()
        defer { presencesPublishLock.unlock() }
        // Who came and went while we were away is unknown, so what we saw of
        // departures no longer rules out asking.
        let gone = lock.withLock { state -> [JID] in
            let gone = Array(state.resources.keys)
            state.resources = [:]
            state.lastSeenSchedule.forgetDepartures()
            return gone
        }
        for jid in gone { peerUpdates.send(PeerUpdate(jid: jid, presence: nil, status: nil)) }
        updateCallablePeers()
    }

    /// A contact's availability as a fixture's server would send it, kept
    /// where the session reads it as well as published, so both agree.
    public func receivePresenceForFixture(_ jid: JID, _ availability: ContactPresence) {
        presencesPublishLock.lock()
        defer { presencesPublishLock.unlock() }
        lock.withLock { state in
            state.presenceCounter += 1
            state.resources[jid] = ["fixture": ResourcePresence(availability: availability, status: nil, order: state.presenceCounter)]
        }
        peerUpdates.send(PeerUpdate(jid: jid, presence: availability, status: nil))
    }

    func pepAvatarChanged(_ jid: JID, info: [PEPUserAvatarModule.Info]) {
        // Any server can push these at us, and each would add a contact row
        // and a file nothing ever removes.
        guard jid == account || (try? database.isKnownPeer(jid)) == true else { return }
        // Our own change not yet sent is what shows; once it's sent or the
        // server's wins, the sender sets the avatar.
        if jid == account, (try? database.owedAvatarChange()) != nil { return }
        func store(_ hash: String?) {
            if (try? database.setAvatarHash(hash, for: jid)) != nil, jid == account { try? database.markOwnAvatarRead() }
        }
        // An empty metadata item means they removed their avatar.
        guard !info.isEmpty else {
            store(nil)
            return
        }
        // We only fetch avatars published inline in PEP, not by URL.
        guard let image = info.first(where: { $0.url == nil }) else { return }
        let hash = image.id.lowercased()
        // It names a file: only a SHA-1, as XEP-0084 has it.
        guard AvatarStore.isValidHash(hash) else { return }
        if avatars.contains(hash) {
            store(hash)
            return
        }
        client.module(.pepUserAvatar).retrieveAvatar(from: jid.martin, itemId: image.id) { [weak self] result in
            guard let self, case .success((_, let data)) = result, self.avatars.save(data, hash: hash) else { return }
            store(hash)
        }
    }

    func vCardAvatarAnnounced(_ jid: JID, hash: String) {
        guard AvatarStore.isValidHash(hash), (try? database.contact(jid))??.avatarHash != hash else { return }
        if avatars.contains(hash) {
            try? database.setAvatarHash(hash, for: jid)
            return
        }
        // Presence repeats the hash with every resource and reconnect, so a
        // photo that is being fetched, or was unusable, isn't asked for again
        // this session.
        guard lock.withLock({ $0.vCardAvatarAttempts.insert("\(jid)#\(hash)").inserted }) else { return }
        client.module(.vcardTemp).retrieveVCard(from: Martin.JID(jid.martin)) { [weak self] result in
            guard let self else { return }
            // Only an answer that arrived and was unusable is final; a
            // failure may pass, and the next presence should ask again.
            guard case .success(let vcard) = result else {
                self.lock.withLock { _ = $0.vCardAvatarAttempts.remove("\(jid)#\(hash)") }
                return
            }
            guard let binval = vcard.photos.first?.binval,
                  let data = AvatarStore.data(fromBase64: binval),
                  self.avatars.save(data, hash: hash) else { return }
            try? self.database.setAvatarHash(hash, for: jid)
        }
    }

    /// Asks for the current PEP avatar of everyone we have a conversation
    /// with whose presence we don't receive. Those we do send their avatar
    /// changes, and the latest when we come online (XEP-0163). Done at most
    /// once a day, as a change in between arrives as an event.
    func refreshAvatars(now: Date = Date()) {
        if let last = database.date(.lastAvatarRefresh), abs(now.timeIntervalSince(last)) < Self.avatarRefreshInterval { return }
        guard let peers = try? database.conversationPeers(), let roster = try? database.roster(),
              let consented = try? database.consented(among: peers) else { return }
        try? database.setDate(.lastAvatarRefresh, now)
        let notifying = Set(roster.filter(\.seesPresence).map(\.jid))
        // Not strangers', whose chats are there because they wrote: asking
        // tells their server we're online. Opening or answering such a chat
        // still asks, as the user then chose to.
        for peer in peers where !notifying.contains(peer) && consented.contains(peer) { fetchAvatar(of: peer) }
    }

    static let avatarRefreshInterval: TimeInterval = 24 * 3600

    /// The daily refresh has come and gone by the time a chat with someone
    /// whose presence we don't receive begins, so their avatar is asked for
    /// once, here.
    ///
    /// Opening a chat before anyone has written asks too, or its avatar would
    /// stay missing until the next daily refresh.
    public func fetchAvatarIfFirstContact(_ peer: JID) {
        // The app calls it as a chat opens, on the main thread.
        Task.detached(priority: .utility) { [self] in askAvatarIfFirstContact(peer) }
    }

    func askAvatarIfFirstContact(_ peer: JID) {
        let contact = (try? database.contact(peer)) ?? nil
        guard !isGroup(peer), contact?.seesPresence != true,
              contact?.avatarHash == nil,
              lock.withLock({ $0.avatarsAskedAtStart.insert(peer).inserted }) else { return }
        fetchAvatar(of: peer)
    }

    func fetchAvatar(of jid: JID) {
        client.module(.pepUserAvatar).retrieveAvatarMetadata(from: jid.martin, fireEvents: false) { [weak self] result in
            guard case .success(let info) = result else { return }
            self?.pepAvatarChanged(jid, info: [info])
        }
    }

    #if DEBUG
    func setShowForTesting(_ show: Presence.Show?) {
        client.module(.presence).setPresence(show: show, status: nil, priority: nil)
    }
    #endif

    // MARK: Archive catch-up

    func catchUp() {
        // Holds back prekey cleanup and session repair until the archive is
        // through, as several archived messages may depend on the same prekey.
        omemo.module.mamSyncStarted(for: nil)
        guard lock.withLock({ $0.archiveVersion }) != nil else {
            logger.info("Server has no message archive")
            finishCatchUp(attempt: lock.withLock { $0.attempt })
            return
        }
        let after = try? database.setting(.lastArchiveId)
        if Self.beginsChatRestore(cursor: after), policy.syncsAccountState { markChatRestorePending() }
        let start = after == nil ? Date().addingTimeInterval(-accountSyncWindow) : nil
        let attempt = lock.withLock { $0.attempt }
        fetchArchivePage(after: after, start: start, attempt: attempt) { [weak self] error in
            guard let self else { return }
            if let error {
                if error is ArchivePageInterrupted { return }
                self.archiveReadFailed(error)
            }
            self.finishCatchUp(attempt: attempt)
        }
    }

    /// What a page's `done` is told when the connection changed under it, which
    /// leaves the catch-up to `resumeInterruptedCatchUps` or the newer connection.
    private struct ArchivePageInterrupted: Error {}

    /// A page came but the database refused it.
    struct ArchivePageNotStored: LocalizedError {
        var errorDescription: String? { String(localized: "Couldn't save some of the messages.") }
    }

    /// The sync ended with a page unread, and the cursor stayed before it, so
    /// the next session reads it again. Until then there may be a gap.
    private func archiveReadFailed(_ error: Error) {
        warnings.post("archive", title: String(localized: "Some messages may be missing"), friendly: String(localized: "Your messages couldn't all be loaded from the server"), error: error) { [weak self] in
            try await self?.rereadArchive()
        }
    }

    /// Reads the archive again from the cursor, for the warning's Retry.
    private func rereadArchive() async throws {
        // The connection going away reads as the timeout it is, which can pass.
        let dropped = ServerError.timedOut
        guard isConnected else { throw dropped }
        let after = try? database.setting(.lastArchiveId)
        let start = after == nil ? Date().addingTimeInterval(-accountSyncWindow) : nil
        let attempt = lock.withLock { $0.attempt }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fetchArchivePage(after: after, start: start, attempt: attempt) { error in
                if let error { continuation.resume(throwing: error is ArchivePageInterrupted ? dropped : error) } else { continuation.resume() }
            }
        }
    }

    /// What a catch-up's answer should do, by the connection it began on.
    enum CatchUpOutcome: Equatable {
        /// Still the connection it began on.
        case proceed
        /// The connection dropped under it. Pending queries fail then, which
        /// is no sign the archive is read, so the sync stays unfinished.
        case interrupted
        /// Another connection is up and has its own catch-up.
        case superseded
    }

    static func catchUpOutcome(isConnected: Bool, startedOn: Int, now: Int) -> CatchUpOutcome {
        if !isConnected { return .interrupted }
        return startedOn == now ? .proceed : .superseded
    }

    /// Whether a catch-up that began on connection `attempt` may go on. If
    /// not, the account's one is marked for `resumeInterruptedCatchUps`.
    private func catchUpMayProceed(attempt: Int) -> Bool {
        let outcome = Self.catchUpOutcome(isConnected: isConnected, startedOn: attempt, now: lock.withLock { $0.attempt })
        if outcome == .interrupted { lock.withLock { $0.catchUpInterrupted = true } }
        return outcome == .proceed
    }

    /// A resumed stream runs no discovery or catch-up, so one the drop cut
    /// off would leave the session syncing for good. Starts it again from the
    /// stored cursor, and the same for the rooms'.
    private func resumeInterruptedCatchUps() {
        let (account, awaitsDiscovery) = lock.withLock { state in
            defer { state.catchUpInterrupted = false }
            return (state.catchUpInterrupted && state.isSyncing, state.awaitsAccountDiscovery)
        }
        if account {
            catchUp()
        } else if awaitsDiscovery {
            // Dropped before discovery answered. Martin asks again on every
            // resume and its answer arrives through the usual subscription;
            // this covers an answer that came in before we got here.
            accountDiscovered(client.module(.disco).accountDiscoResult)
        }
        resumeInterruptedRoomCatchUps()
    }

    /// Reads the archive from `after` to its end, a page at a time, and tells
    /// `done` how it ended: nil, or the error that stopped it. The session is
    /// held only for a page, so one let go of mid-sync stops at the next.
    private func fetchArchivePage(after: String?, start: Date?, attempt: Int, done: @escaping @Sendable (Error?) -> Void) {
        Task { [weak self] in
            guard let step = await self?.readArchivePage(after: after, start: start, attempt: attempt) else { return }
            switch step {
            case .next(let after, let start): self?.fetchArchivePage(after: after, start: start, attempt: attempt, done: done)
            case .ended(let error): done(error)
            }
        }
    }

    private enum ArchiveStep {
        case next(after: String?, start: Date?)
        case ended(Error?)
    }

    private func readArchivePage(after: String?, start: Date?, attempt: Int) async -> ArchiveStep {
        do {
            let page = try await ServerRetry.run(
                backoff: lock.withLock { $0.retryBackoff },
                isStillWanted: { catchUpMayProceed(attempt: attempt) },
                operation: { try await archivePage(after: after, start: start, attempt: attempt) },
            )
            // Results for this page were delivered before the query's answer.
            if let last = page.last {
                try? database.setSetting(.lastArchiveId, last)
            }
            return page.complete || page.last == nil ? .ended(nil) : .next(after: page.last, start: nil)
        } catch {
            // A retry given up because the connection changed is as interrupted
            // as a page it changed under.
            if error is ArchivePageInterrupted || !catchUpMayProceed(attempt: attempt) { return .ended(ArchivePageInterrupted()) }
            if after != nil, (error as? XMPPError) == .item_not_found {
                // Our cursor expired from the archive; fall back to a time window.
                try? database.setSetting(.lastArchiveId, nil)
                if policy.syncsAccountState { markChatRestorePending() }
                return .next(after: nil, start: Date().addingTimeInterval(-accountSyncWindow))
            }
            // The cursor stays where it was, so the page is read again, now or next session.
            if !(error is ArchivePageNotStored) { logger.error("Archive sync failed: \(error)") }
            return .ended(error)
        }
    }

    /// One try at a page: the cursor of its last item and whether it was the
    /// archive's last. It throws `ArchivePageInterrupted` when the connection
    /// changed under it, and `ArchivePageNotStored` when the database refused
    /// the page, as going on would move the cursor past it.
    private func archivePage(after: String?, start: Date?, attempt: Int) async throws -> (last: String?, complete: Bool) {
        let version = lock.withLock { $0.archiveVersion }
        let queryId = UUID().uuidString
        let (result, stored) = await withCheckedContinuation { (continuation: CheckedContinuation<(Result<(last: String?, complete: Bool), XMPPError>, Bool), Never>) in
            client.module(.mam).queryItems(version: version, start: start, queryId: queryId, rsm: RSM.Query(after: after, max: 100)) { [self] result in
                // Stored in Martin's callback rather than after resuming: it
                // is a database write of up to a page, which would hold one of
                // the few threads every task shares.
                let stored = flushArchive(query: queryId)
                continuation.resume(returning: (result.map { ($0.rsm?.last, $0.complete) }, stored))
            }
        }
        guard catchUpMayProceed(attempt: attempt) else { throw ArchivePageInterrupted() }
        let page = try result.get()
        guard stored else { throw ArchivePageNotStored() }
        return page
    }

    func finishCatchUp(attempt: Int) {
        // Never report connected, or do the end-of-sync work, on a dead stream.
        guard catchUpMayProceed(attempt: attempt) else { return }
        if policy.syncsAccountState {
            finishCatchUpAsApp()
        } else {
            finishCatchUpQuietly(attempt: attempt)
        }
    }

    /// Reads what the rooms have too, without joining them.
    private func finishCatchUpQuietly(attempt: Int) {
        omemo.module.mamSyncFinished(for: nil)
        catchUpRoomArchives { [weak self] in
            guard let self, self.catchUpMayProceed(attempt: attempt) else { return }
            // What another device read needs no notification.
            self.fetchDisplayed { [weak self] _ in
                guard let self, self.catchUpMayProceed(attempt: attempt) else { return }
                self.lock.withLock { $0.isSyncing = false }
                self.state.send(.connected(isSyncing: false))
                self.reportClientState()
            }
        }
    }

    /// What the app does once it has caught up with the server: ends the sync
    /// state, refreshes what it keeps in sync, and sends what is still pending.
    private func finishCatchUpAsApp() {
        let generation = lock.withLock { state in
            state.isSyncing = false
            state.held.reset()
            return state.held.generation
        }
        omemo.module.mamSyncFinished(for: nil)
        state.send(.connected(isSyncing: false))
        reportClientState()
        downloadMissedImages()
        refreshAvatars()
        pruneContactRequests()
        fetchDisplayed { [weak self] succeeded in
            if !succeeded { self?.owe(.readStates, generation: generation) }
        }
        syncBookmarks { [weak self] succeeded in
            if !succeeded { self?.owe(.bookmarks, generation: generation) }
        }
        fetchNickname()
        Task.detached(priority: .utility) { [weak self] in await self?.reconcileProfileAccess() }
        syncSettings { [weak self] outcome in
            if outcome.isOwed { self?.owe(.settings, generation: generation) }
        }
        enablePush()
        // However long ago: a message still pending was never sent, as the
        // server never acknowledged it (XEP-0198, e.g. when stream resumption
        // failed), or the share extension left it so, possibly for days when
        // the app isn't opened. Resending with the same id is safe: recipients
        // dedupe on it.
        flushOutboxes(except: [.bookmarks, .readStates])
        restoreChatsIfPending()
    }

    /// What the app keeps to send once connected. Every new session and every
    /// resumed stream sends all of them, so one that is left out of
    /// `flushOutboxes` would wait for the next new session.
    enum Outbox: CaseIterable {
        case messages, blocks, rosterChanges, bookmarks, profile, readStates
    }

    /// Sends every outbox, except those the caller says must wait. A new
    /// session reads the bookmarks and the read states from the server first
    /// (another device may have changed them), so its catch-up sends those
    /// itself; a resumed stream has no such read for the bookmarks, and
    /// reads the states only when chats were read while it was down.
    /// An extension sends nothing it didn't write itself.
    func flushOutboxes(except skipped: Set<Outbox> = []) {
        guard policy.resendsPending else { return }
        for outbox in Outbox.allCases where !skipped.contains(outbox) {
            switch outbox {
            case .messages: sendUnclaimedPending()
            case .blocks: sendPendingBlocks()
            case .rosterChanges: sendPendingRosterChanges()
            case .bookmarks: sendOwedBookmarks()
            case .profile: sendOwedProfile()
            case .readStates: if (try? database.owesReadStates()) == true { fetchDisplayed() }
            }
        }
    }

    /// Sends every pending message the send queue hasn't taken up this
    /// session: 1:1 chats, and rooms that are ready (the others send at the
    /// end of their own catch-up). A claimed message is on its way or awaiting
    /// the server's acknowledgement, which a resumed stream still delivers.
    func sendUnclaimedPending() {
        func isClaimed(_ message: Message) -> Bool {
            guard let id = message.remoteId else { return true }
            return lock.withLock { $0.sends.isClaimed(id) }
        }
        do {
            // What was written at connect (presence, requests) is acknowledged before the server
            // reaches the first of ours, so if that one makes it close the stream, it is the oldest
            // stanza left unacknowledged (see `blameUnacknowledged`). The writes below happen
            // on the send queues, after this request.
            requestAcknowledgement()
            let chats = try database.unconfirmedOutgoing().filter { !isClaimed($0.0) }
            var rooms: [(message: Message, room: JID)] = []
            for (room, status) in lock.withLock({ $0.rooms }) where status.isJoined && !status.isSyncing {
                guard let group = try database.groupChat(room) else { continue }
                rooms += try database.pendingOutgoing(conversationId: group.conversationId).filter { !isClaimed($0) }.map { ($0, room) }
            }
            let pending = PendingKind.allCases.map { (kind: $0, rows: pendingRows($0)) }
            if lock.withLock({ !$0.streamErrorStrikes.isEmpty }) {
                // A stanza the server closed the stream on goes first and alone.
                let ids = chats.compactMap(\.0.remoteId) + rooms.compactMap(\.message.remoteId)
                    + pending.flatMap { $0.rows.map(\.id) }
                beginProbation(among: ids)
            }
            var resent = 0
            for (message, peer) in chats {
                resent += 1
                transmit(message, to: peer)
            }
            for (message, room) in rooms {
                resent += 1
                transmit(message, to: room)
            }
            DiagLog.info(.send, "Sending unclaimed pending messages", .int("count", resent))
            resendUnacknowledged(pending)
        } catch {
            logger.error("Failed to load unsent messages: \(error)")
        }
    }

    /// Writes a reactions stanza once, asking for its acknowledgement, or
    /// pinging for it where the stream has no stream management.
    func writeReactions(_ stanza: Martin.Message, id: String, messageId: Int64, peer: JID) {
        guard isConnected, !isHeldByProbation(id),
              beginWrite(.reaction, id: id, messageId: messageId, peer: peer, failure: ConversationItem.ReactionGroup.notDelivered) else { return }
        let acknowledges = streamAcknowledges
        client.context.writer.write(stanza) { [weak self] result in
            if case .failure = result { self?.endWrite(.reaction, id: id) }
        }
        if acknowledges {
            requestAcknowledgement()
        } else {
            confirmByPing(stanza)
        }
    }

    // MARK: Outbound

    /// Stores and sends a text message. Offline, it stays pending and goes out
    /// once the stream is resumed or has caught up.
    @discardableResult
    public func send(_ text: String, to peer: JID, replyingTo original: Message? = nil) throws -> Message {
        let reply = original.flatMap { message in
            reference(to: message).map { OutgoingMessages.Reply(id: $0, sender: message.sender) }
        }
        let message = try outgoingMessages.stage([.text(text, reply: reply)], to: peer)[0]
        donateSuggestion(for: peer)
        askAvatarIfFirstContact(peer)
        transmit(message, to: peer)
        return message
    }

    /// Lets the share sheet suggest this chat.
    func donateSuggestion(for peer: JID) {
        guard policy.donatesSuggestions else { return }
        Task.detached(priority: .utility) { [database, avatars] in
            await ShareSuggestions.donate(to: peer, database: database, avatars: avatars)
        }
    }

    var outgoingMessages: OutgoingMessages {
        OutgoingMessages(database: database, attachments: attachments, account: account)
    }

    /// Our nickname in the group chat `peer`; nil for 1:1 chats.
    func nickname(in peer: JID) throws -> String? {
        guard isGroup(peer) else { return nil }
        return try database.groupChat(peer)?.nickname
    }

    /// How replies and reactions point at `message`: by the room's stanza-id
    /// in group chats, by the stanza's own id in 1:1 chats.
    func reference(to message: Message) -> String? {
        guard let conversation = try? database.conversation(id: message.conversationId) else {
            return Route.directReference(to: message)
        }
        return route(for: conversation).reference(to: message)
    }

    /// What to tell the recipient of our file, from its row; an old row is
    /// filled in first. Reads the file in that case, so call it off the main
    /// thread. Nil for a file that can't be described or read.
    func outgoingMetadata(for attachment: Attachment) -> FileMetadata? {
        // Not touched at all if it wouldn't be described: hashing it would be for nothing.
        guard attachment.isDescribedWhenSent else { return nil }
        return (try? OutgoingFileFacts.completing(attachment, in: attachments, database: database, with: fileHasher)).flatMap(FileMetadata.outgoing(for:))
    }

    /// `resend` sends a message again that was claimed but never came back.
    func transmit(_ message: Message, to peer: JID, resend: Bool = false) {
        guard let id = message.remoteId else { return }
        let sendId = Redacted.id(id)
        guard isConnected else {
            DiagLog.info(.send, "Send waits", .id("msg", sendId), .value("reason", SendSkip.offline))
            return
        }
        // Stays pending, and `endProbation` sends it.
        guard !isHeldByProbation(id) else {
            DiagLog.info(.send, "Send waits", .id("msg", sendId), .value("reason", SendSkip.probation))
            return
        }
        let route = route(to: peer)
        // Until the room has us, and we've caught up on what it has, the
        // message waits; the end of the catch-up sends it.
        guard route.isReady else {
            DiagLog.info(.send, "Send waits", .id("msg", sendId), .value("reason", SendSkip.routeNotReady))
            return
        }
        let attachment = message.id.flatMap { try? database.attachment(messageId: $0) }
        if let attachment, attachment.url == nil {
            DiagLog.info(.send, "Send needs an upload first", .id("msg", sendId))
            upload(message, attachment, to: peer)
            return
        }
        // Marked before the queue has it, as the claim comes only when the
        // block runs, which a slow encryption ahead of it can delay.
        guard lock.withLock({ $0.sends.enqueue(id, resend: resend) }) else {
            DiagLog.debug(.send, "Send already queued", .id("msg", sendId))
            return
        }
        DiagLog.info(.send, "Send queued", .id("msg", sendId), .bool("resend", resend), .bool("attachment", attachment != nil), .bool("encrypted", message.encryption == .omemo))
        sendQueue(for: peer).async { [self] in
            // Claimed and checked for edits in one step: from here on, a
            // change has to follow the message as a correction.
            let text: String
            let (claim, token) = lock.withLock { ($0.sends.claim(id), $0.sends.token(of: id)) }
            switch claim {
            case .skip:
                DiagLog.debug(.send, "Send skipped, not ours to claim", .id("msg", sendId))
                return
            case .send(let edited): text = edited ?? message.body
            }
            let stanza = OutboundStanza.text(text, to: route, id: id, replyingTo: quote(of: message, in: route),
                                             mentions: attachment == nil ? mentions(in: text, route: route) : [],
                                             active: !route.isGroup && includesActiveState(to: peer))
            // Encrypted, the URL must only travel inside the OMEMO payload.
            // The metadata is an autoclosure that addFile doesn't call then, so
            // the file isn't hashed for a message that sends none of it.
            if let attachment {
                OutboundStanza.addFile(
                    url: message.body, metadata: outgoingMetadata(for: attachment),
                    encrypted: message.encryption != .none, to: stanza,
                )
            }
            // A write the session drops comes back after deliver has returned.
            let conversationId = message.conversationId
            // A mark an earlier process left is about its write, which may have
            // gone out; only a mark this attempt made is taken back when it drops.
            let marked = OSAllocatedUnfairLock(initialState: false)
            let dropped: @Sendable () -> Void = { [weak self] in
                guard let self, let token else { return }
                DiagLog.notice(.send, "Write dropped by the session", .id("msg", sendId))
                lock.withLock { $0.sends.releaseDropped(id, token: token) }
                if marked.withLock({ $0 }) { try? database.setWritten(nil, conversationId: conversationId, remoteId: id) }
            }
            // Before the write rather than after: a process killed in between
            // must still know the stanza may have gone out.
            let willWrite: @Sendable () -> Void = { [weak self] in
                guard let wasUnmarked = try? self?.database.setWritten(Date(), conversationId: conversationId, remoteId: id) else { return }
                marked.withLock { $0 = $0 || wasUnmarked }
            }
            expectBounce(
                of: id, key: .message(id), peer: peer,
                release: { [weak self] in self?.lock.withLock { $0.sends.release(id) } },
                repend: { [weak self] in try? self?.database.bounceOutgoing(conversationId: conversationId, remoteId: id, to: .pending) },
                fail: { [weak self] error in
                    try? self?.database.bounceOutgoing(
                        conversationId: conversationId, remoteId: id, to: .failed, error: InboundMessage.describeError(error),
                    )
                },
            )
            switch deliver(stanza, to: peer, encrypted: message.encryption == .omemo, willWrite: willWrite, onDropped: dropped) {
            case .success(let (trust, acknowledged)):
                DiagLog.info(.send, "Written to the stream", .id("msg", sendId), .bool("streamAcknowledges", acknowledged))
                if let trust { try? database.setTrust(trust, conversationId: message.conversationId, remoteId: id) }
                // The server's acknowledgement marks it sent, or the reply to
                // a ping where it gives none. If that never comes it stays
                // pending, and the claim keeps it from being written again
                // this session.
                if !acknowledged { confirmByPing(stanza) }
            case .failure(.offline):
                // Nothing was written, so it stays pending and gives up its
                // claim to be sent again once we're back.
                DiagLog.notice(.send, "Send gave up, offline", .id("msg", sendId))
                lock.withLock { $0.sends.release(id) }
            case .failure(.failed(let reason, let kind)):
                DiagLog.error(.send, "Marked failed", .id("msg", sendId), .value("reason", kind))
                try? database.markFailed(conversationId: message.conversationId, remoteId: id, error: reason)
                lock.withLock { $0.sends.release(id) }
            }
        }
    }

    /// What `message` replies to, as XEP-0461 wants it sent.
    private func quote(of message: Message, in route: Route) -> OutboundStanza.QuotedMessage? {
        guard let replyId = message.replyToId, let author = message.replyToSender else { return nil }
        let (original, attachment) = (try? database.reader.read { db -> (Message?, Attachment?) in
            let original = try AppDatabase.referencedMessage(db, conversationId: message.conversationId, id: replyId)
            return (original, try original?.id.flatMap { try Attachment.fetchOne(db, key: $0) })
        }) ?? (nil, nil)
        // XEP-0461 names a group chat author by their occupant JID.
        let peer = route.peer
        let to = route.isGroup ? original?.nick.map { "\(peer)/\($0)" } : author.description
        // A file's link holds its key, so the quote describes the file instead.
        let raw = original.map { $0.isRetracted ? "" : $0.body } ?? message.replyFallback ?? ""
        // What an encrypted message holds, its text and its file's name too,
        // must not reach the servers in the clear, which a quote in an
        // unencrypted reply would do.
        let hidden = original?.encryption == .omemo && message.encryption != .omemo
        let text = hidden ? "" : Attachment.quoteSummary(text: raw, attachment: attachment) ?? raw
        return .init(id: replyId, author: to ?? peer.description, text: text)
    }

    /// The group's occupants that `text` names (XEP-0372), by their real
    /// address where the room shows it, else as occupants.
    func mentions(in text: String, route: Route) -> [OutboundStanza.Mention] {
        guard case .room(let peer, let status?) = route else { return [] }
        let others = status.occupants.filter { $0.key != status.nickname }
        return Mentions.find(others.keys, in: text).map { found in
            let uri = others[found.nick]?.jid.map { "xmpp:\($0)" } ?? "xmpp:\(peer)/\(found.nick)"
            return .init(uri: uri, begin: found.begin, end: found.end)
        }
    }

    enum DeliveryError: Error {
        /// Lost the connection on the way: worth trying again later.
        case offline
        case failed(String, SendFailure)
    }

    /// The queue `peer`'s messages go out on, one after another.
    func sendQueue(for peer: JID) -> DispatchQueue {
        lock.withLock { state in
            if let queue = state.sendQueues[peer] { return queue }
            let queue = DispatchQueue(label: "Yapnest.XMPPSession.send.\(peer)")
            state.sendQueues[peer] = queue
            return queue
        }
    }

    /// Encrypts, and again after a wait that doubles while a device list or
    /// bundle can't be had for a reason that may pass, up to 3 attempts, as
    /// `retryingPassingErrors` does for a request. Blocks the send queue,
    /// which encrypting does anyway; stops once the connection is gone or a
    /// new one began, as that one sends the message again.
    private func encryptRetryingPassingErrors(_ stanza: Martin.Message, for recipients: [JID]) -> Result<(Martin.Message, OMEMODevice.Trust), OMEMOEncryption.EncryptError> {
        let (started, backoff) = lock.withLock { ($0.attempt, $0.retryBackoff) }
        var attempt = 1
        while true {
            let result = omemo.encrypt(stanza, for: recipients)
            guard case .failure(let error) = result, error.isPassing, attempt < ServerRetry.attempts else { return result }
            let delay = backoff * Double(1 << (attempt - 1))
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard isConnected, lock.withLock({ $0.attempt }) == started else { return result }
            omemo.forgetFetchFailures(of: recipients)
            attempt += 1
        }
    }

    /// Encrypts `stanza` for everyone in the conversation if asked, then
    /// writes it. Returns how far the recipients' devices were trusted, and
    /// whether the stream acknowledges it (XEP-0198).
    /// Runs on `peer`'s send queue, as encrypting may wait on the network.
    private func deliver(_ stanza: Martin.Message, to peer: JID, encrypted: Bool, willWrite: @Sendable () -> Void = {}, onDropped: @escaping @Sendable () -> Void = {}) -> Result<(OMEMODevice.Trust?, acknowledged: Bool), DeliveryError> {
        var outgoing = stanza
        var trust: OMEMODevice.Trust?
        if encrypted {
            let route = route(to: peer)
            if route.isGroup, (try? database.groupChat(peer))?.isPrivate != true {
                return .failure(.failed(GroupError.notPrivate.localizedDescription, .groupNotPrivate))
            }
            switch encryptRetryingPassingErrors(stanza, for: route.recipients(excluding: account)) {
            case .success(let (encrypted, devices)):
                outgoing = encrypted
                trust = devices
            case .failure(let error):
                DiagLog.error(.omemo, "Encryption failed", .value("reason", EncryptFailure(error)))
                guard isConnected else { return .failure(.offline) }
                return .failure(.failed(error.localizedDescription, .encryption))
            }
        }
        guard isConnected else { return .failure(.offline) }
        // A server closes the stream on a stanza past its limit, which leaves everything queued
        // behind it unacknowledged, and it would be written first again on every reconnect. Martin
        // refuses it too, but that comes back as a dropped write, which leaves the message pending.
        let features = client.context.module(.streamFeatures)
        if !features.fits(outgoing) {
            return .failure(.failed(String(localized: "This message is too large for your server."), .tooLarge))
        }
        let acknowledged = streamAcknowledges
        willWrite()
        client.context.writer.write(outgoing) { result in
            if case .failure = result { onDropped() }
        }
        // Ask now rather than wait for the server to, so it shows as sent.
        // Without stream management the caller has the server confirm it.
        if acknowledged { requestAcknowledgement() }
        return .success((trust, acknowledged))
    }

    // MARK: Corrections and retractions

    public enum MessageActionError: Error, LocalizedError {
        case offline
        /// The room hasn't confirmed the message yet, so it can't be named.
        case notYetConfirmed
        /// The chat gives its messages no id a reaction could name.
        case cannotReact
        /// A correction can't become a file the way a long new message does, and a server
        /// refuses a stanza that large.
        case editTooLong
        /// A change to a group's messages that can't be sent from a room we left.
        case leftGroup

        public var errorDescription: String? {
            switch self {
            case .offline: String(localized: "You're offline.")
            case .notYetConfirmed: String(localized: "The group hasn't received this message yet.")
            case .cannotReact: String(localized: "This chat doesn't let this message be reacted to.")
            case .editTooLong: String(localized: "This text is too long to edit a message with. Send it as a new message instead.")
            case .leftGroup: String(localized: "You've left this group.")
            }
        }
    }

    /// Whether `message` may be out there: acknowledged, or written by this
    /// process or an earlier one (the mark outlives the claims). Read fresh,
    /// as `message` may be old.
    private func mayBeOnTheWire(_ message: Message, id messageId: Int64) -> Bool {
        let current = (try? database.reader.read { try Message.fetchOne($0, key: messageId) }) ?? message
        return current.status >= .sent || current.writtenAt != nil
    }

    /// Whether `message` is ours to edit: a text we sent that's still there.
    public func canEdit(_ message: Message) -> Bool {
        guard message.isEditableText, let id = message.id else { return false }
        return (try? database.attachment(messageId: id)) == nil
    }

    /// Replaces the text of one of our messages, here and for whoever got
    /// it (XEP-0308). One that never left is simply sent with the new text.
    /// Offline, the correction is applied here and stays pending until the
    /// server acknowledges its stanza; a new session sends it again.
    public func edit(_ message: Message, to text: String) throws {
        // As a new message's text is staged, so the stored body and the wire agree.
        let text = EscapeUtils.removingForbidden(text)
        guard canEdit(message), let messageId = message.id, let original = message.remoteId, text != message.body,
              let peer = try database.conversation(id: message.conversationId)?.peer else { return }
        // Before anything is applied: a correction the server would refuse for its size would
        // show the new text here and leave everyone else the old one. Counted as a new message's
        // text is, in characters.
        // Half the server's limit in bytes as well: a short text can be large (joined emoji), and
        // the stanza around it and the encryption of an encrypted chat add to it.
        guard !LongText.isLong(text), text.utf8.count <= client.context.module(.streamFeatures).maxStanzaBytes / 2 else { throw MessageActionError.editTooLong }
        // One that was never written goes out with the new text. Claims last
        // for the session and a status only moves forward once sent, so a
        // message going out meanwhile isn't missed: if the queue claimed it
        // after this read, the claim is seen, and if it hasn't yet, the change
        // recorded here is consumed by its claim.
        let alreadySent = mayBeOnTheWire(message, id: messageId)
        let onTheWire = lock.withLock { $0.sends.apply(.edited(text), to: original, alreadySent: alreadySent) }
        if !onTheWire {
            _ = try database.applyEdit(text, to: messageId, marksEdited: false)
            return
        }
        // Offline, it stays pending and goes out once a session is back.
        let id = OutboundStanza.newId()
        guard try database.applyEdit(text, to: messageId, actionId: id) != nil else { return }
        sendAction(id: id, of: messageId, to: peer)
    }

    /// Takes back one of our messages, here and for whoever got it
    /// (XEP-0424). One that never left is just removed here. Offline, it is
    /// applied here and stays pending like a correction.
    public func retract(_ message: Message) throws {
        guard message.direction == .outgoing, !message.isRetracted, let messageId = message.id,
              let peer = try database.conversation(id: message.conversationId)?.peer else { return }
        // Read before the lock, as in `edit`.
        let alreadySent = mayBeOnTheWire(message, id: messageId)
        let onTheWire = message.remoteId.map { id in
            lock.withLock { $0.sends.apply(.retracted, to: id, alreadySent: alreadySent) }
        } ?? alreadySent
        if !onTheWire {
            if let attachment = try database.applyRetraction(of: messageId) { attachments.remove(attachment) }
            return
        }
        // Groups name messages by the room's stanza-id, 1:1 chats by the stanza's id.
        guard route(to: peer).reference(to: message) != nil else { throw MessageActionError.notYetConfirmed }
        // Offline, it stays pending and goes out once a session is back.
        let id = OutboundStanza.newId()
        if let attachment = try database.applyRetraction(of: messageId, actionId: id) { attachments.remove(attachment) }
        sendAction(id: id, of: messageId, to: peer)
    }

    /// Sends the correction or retraction `id` of a message, built from what
    /// is stored when its turn comes: by then the message may have been
    /// corrected again, or retracted, and only the latest state is sent. Where
    /// the stanza can no longer be built, or can never be sent, it stops
    /// being pending.
    func sendAction(id: String, of messageId: Int64, to peer: JID) {
        guard !isHeldByProbation(id) else { return }
        // A room we left never becomes ready, so it would wait for good.
        // Nothing is shown for it: they left, and no one there is waiting for it.
        if (try? database.groupChat(peer))?.hasLeft == true { return giveUpPending(.action, id: id, because: nil) }
        whenReady(route(to: peer)) { [self] in
            // After any correction still being encrypted.
            sendQueue(for: peer).async { [self] in
                guard isConnected, let message = try? database.reader.read({ try Message.fetchOne($0, key: messageId) }),
                      message.actionPendingId == id else { return }
                let route = route(to: peer)
                let stanza: Martin.Message
                if message.isRetracted {
                    // Groups name messages by the room's stanza-id, 1:1 chats by the stanza's id.
                    guard let target = route.reference(to: message) else { return giveUpPending(.action, id: id, because: Self.unsendableChange) }
                    stanza = OutboundStanza.retraction(of: target, to: route, id: id)
                } else {
                    guard let original = message.remoteId else { return giveUpPending(.action, id: id, because: Self.unsendableChange) }
                    // Corrections name the original's stanza id, in groups too.
                    stanza = OutboundStanza.text(message.body, to: route, id: id, replyingTo: quote(of: message, in: route),
                                                 mentions: mentions(in: message.body, route: route))
                    stanza.addChild(Element(name: "replace", attributes: ["xmlns": NS.correction, "id": original]))
                }
                let failure = message.isRetracted ? String(localized: "The deletion couldn't be delivered.") : String(localized: "The edit couldn't be delivered.")
                guard beginWrite(.action, id: id, messageId: messageId, peer: peer, failure: failure) else { return }
                let dropped: @Sendable () -> Void = { [weak self] in self?.endWrite(.action, id: id) }
                switch deliver(stanza, to: peer, encrypted: !message.isRetracted && message.encryption == .omemo, onDropped: dropped) {
                case .success(let (_, acknowledged)):
                    if !acknowledged { confirmByPing(stanza) }
                case .failure(.offline):
                    dropped()
                case .failure(.failed(let text, let reason)):
                    // Like a message that can't be encrypted for the chat, it
                    // won't go next session either.
                    giveUpPending(.action, id: id, because: text)
                    DiagLog.error(.send, "Correction or retraction failed", .value("reason", reason))
                }
            }
        }
    }

    private static var unsendableChange: String { String(localized: "The change couldn't be sent.") }

    /// Sends a correction or retraction that did not reach the others again,
    /// with what the message holds now.
    public func retryAction(on message: Message) throws {
        guard let messageId = message.id,
              let stored = try database.reader.read({ try Message.fetchOne($0, key: messageId) }), stored.actionError != nil,
              let peer = try database.conversation(id: stored.conversationId)?.peer else { return }
        // Sending would give up at once, and the failure would be gone.
        guard (try database.groupChat(peer))?.hasLeft != true else { throw MessageActionError.leftGroup }
        let id = OutboundStanza.newId()
        try database.repend(.action(messageId: messageId), id: id)
        sendAction(id: id, of: messageId, to: peer)
    }

    // MARK: Bounces

    /// Remembers that the stanza `id` belongs to `key`, for `routeBounce`.
    /// When its error comes, `release` lets the stanza be written again,
    /// `repend` makes the item pending where the error may pass, and `fail`
    /// records it where it won't.
    func expectBounce(
        of id: String, key: BounceKey, peer: JID,
        release: @escaping @Sendable () -> Void,
        repend: @escaping @Sendable () -> Void,
        fail: @escaping @Sendable (ServerError) -> Void,
    ) {
        let handle: @Sendable (BounceRouter.Outcome) -> Void = { [weak self] outcome in
            release()
            switch outcome {
            case .retry(let passes):
                self?.lock.withLock { _ = $0.repended.insert(id) }
                repend()
                self?.resendAfterBounce(passes: passes)
            case .fail(let error):
                fail(error)
            }
        }
        lock.withLock {
            $0.bounces.register(id, .init(key: key, peer: peer, handle: handle))
            $0.repended.remove(id)
        }
    }

    /// Hands the error `stanza` to the stanza it bounces, if we wrote one that
    /// the ledger still holds. False for any other, which ingest looks for in
    /// the database.
    func routeBounce(_ stanza: Martin.Message) -> Bool {
        guard stanza.type == .error, let id = stanza.id else { return false }
        let error = ServerError.bounce(of: stanza)
        let from = stanza.from.flatMap { JID($0) }
        guard let (owner, outcome) = lock.withLock({ $0.bounces.route(id, from: from, account: account, error: error) }) else { return false }
        switch outcome {
        case .retry(let passes): DiagLog.notice(.send, "Bounce may pass", .id("stanza", Redacted.id(id)), .int("passes", passes))
        case .fail: DiagLog.notice(.send, "Bounce is final", .id("stanza", Redacted.id(id)))
        }
        owner.handle(outcome)
        return true
    }

    /// Sends what bounced again, after a wait that doubles each time. Nothing
    /// waits for a second chance to pass otherwise: a session that comes back
    /// sends it by itself. An extension sends nothing it didn't write itself,
    /// so it leaves the bounced item pending for the app.
    private func resendAfterBounce(passes: Int) {
        guard policy.resendsPending else { return }
        let delay = lock.withLock { $0.bounceBackoff } * Double(1 << min(max(passes - 1, 0), 10))
        let resend: @Sendable () -> Void = { [weak self] in
            guard let self, isConnected else { return }
            sendUnclaimedPending()
        }
        if delay <= 0 { resend() } else { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: resend) }
    }

    /// Chooses the action `actionId` that the incoming `message` offered
    /// (XEP-0439). It goes out as it is even in an encrypted chat, as actions
    /// are only ever honoured on plain messages.
    public func chooseAction(_ actionId: String, on message: Message) async throws {
        guard let messageId = message.id, message.direction == .incoming, !message.isRetracted,
              message.quickResponses?.actions.contains(where: { $0.id == actionId }) == true,
              let peer = try database.conversation(id: message.conversationId)?.peer else { return }
        // Offers from a group are never stored; this is the guard if one was.
        guard !isGroup(peer) else { return }
        guard isConnected else { throw MessageActionError.offline }
        // Recorded before it is sent, in one write that also checks, so a
        // second tap, even from another window, sends nothing more. If the
        // record fails nothing has gone out, so the user can try again.
        guard try database.recordChosenAction(actionId, on: messageId) else { return }
        // The connection can go between the check above and the write, and a
        // write after that is dropped. An action marked chosen but never sent
        // would stay greyed out with nothing for the user to retry.
        guard await writeAwaitingHandOver(OutboundStanza.actionSelected(actionId, to: route(to: peer), id: OutboundStanza.newId())) else {
            try database.forgetChosenAction(actionId, on: messageId)
            throw MessageActionError.offline
        }
    }

    // MARK: Encryption

    /// Turns OMEMO on or off for messages sent to `peer` from now on.
    public func setEncrypted(_ encrypted: Bool, with peer: JID) throws {
        try database.setEncrypted(encrypted, with: peer)
    }

    /// Whether our OMEMO device is published, so others can encrypt to us.
    var isEncryptionReady: Bool { omemo.module.isReady }

    var omemoStoreForTesting: OMEMOStore { omemo.store }

    var omemoModuleForTesting: OMEMOModule { omemo.module }

    /// This device's OMEMO device id.
    var omemoDeviceId: UInt32 { omemo.deviceId }

    /// The devices `jid` has announced, as far as we've heard. A newly
    /// published device only gets messages once its announcement reaches us.
    func announcedDevices(of jid: JID) -> [Int32] {
        omemo.module.devices(for: jid.martin) ?? []
    }

    /// This device's OMEMO fingerprint.
    public var ownFingerprint: String? {
        omemo.store.identityFingerprint(forAddress: SignalAddress(name: account.description, deviceId: Int32(bitPattern: omemo.deviceId)))
    }

    /// Known OMEMO devices of `jid` (ours: our other devices).
    public func devices(of jid: JID) -> [OMEMODevice] {
        let usage = omemo.store.usage(forName: jid.description)
        return omemo.store.identities(forName: jid.description)
            .filter { !(jid == account && UInt32(bitPattern: $0.address.deviceId) == omemo.deviceId) }
            .map {
                let seen = usage[$0.address.deviceId]
                return OMEMODevice(jid: jid, id: $0.address.deviceId, fingerprint: $0.fingerprint, trust: .init($0.status), isActive: $0.status.isActive,
                                   firstSeen: seen?.firstSeen ?? Date(), lastUsed: seen?.lastUsed)
            }
    }

    public enum DeviceRemovalError: Error, LocalizedError {
        case offline
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .offline: String(localized: "You're offline.")
            case .failed(let reason): String(localized: "Your server didn't accept the change: \(reason)")
            }
        }
    }

    /// Takes some of our other devices out of our published device list, so
    /// contacts stop encrypting to them, and forgets them here at once. This
    /// device is never removed. A device still in use puts itself back the
    /// next time it connects.
    public func removeOwnDevices(_ devices: [OMEMODevice]) async throws {
        let ids = devices.filter { $0.jid == account && UInt32(bitPattern: $0.id) != omemo.deviceId }.map(\.id)
        guard !ids.isEmpty else { return }
        guard await waitForConnection() else { throw DeviceRemovalError.offline }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            omemo.module.removeDevices(withIds: ids) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: DeviceRemovalError.failed(error.localizedDescription))
                }
            }
        }
        // Only now: if the server refused, the devices stay as they were.
        omemo.store.forget(deviceIds: ids, of: account.description)
    }

    /// Makes this install a new OMEMO device, with a new id and key, for when
    /// contacts' apps hold on to the old key: see `OMEMOStore.replaceIdentity`.
    /// It disconnects this session for good, as its module stays registered
    /// as the old device; a new session over the database registers the new one.
    /// The stream is closed first: stanzas still being handled would otherwise
    /// run against the store after the swap.
    public func replaceEncryptionDevice() async throws {
        lock.withLock { $0.wantsConnection = false }
        // Throws when there's no connection to close.
        try? await client.disconnect(force: false)
        try omemo.replaceDevice()
    }

    /// The devices `setTrust(trust, for: device)` would make undecided, so the
    /// user can be asked first.
    public func devicesDemoted(bySetting trust: OMEMODevice.Trust, for device: OMEMODevice) -> [OMEMODevice] {
        guard trust == .verified else { return [] }
        return devices(of: device.jid).filter { $0.id != device.id && $0.trust == .trusted }
    }

    /// Sets how far we trust one of `device.jid`'s devices. Verifying a device
    /// ends blind trust for that JID: its other unverified devices become
    /// undecided until the user decides on each.
    public func setTrust(_ trust: OMEMODevice.Trust, for device: OMEMODevice) {
        let name = device.jid.description
        for identity in omemo.store.identities(forName: name) {
            let status = identity.status
            if identity.address.deviceId == device.id {
                _ = omemo.store.setStatus(status.toTrust(trust.signal), forIdentity: identity.address)
                // Signal checks trust only when it builds a session. Without
                // this, a device that already has one would stay readable, and
                // a new one must go through that check, which refuses it.
                if trust == .compromised { _ = omemo.store.deleteSessionRecord(forAddress: identity.address) }
                try? database.setTrust(trust, sender: device.jid, device: device.id)
            } else if trust == .verified, status.trust == .trusted {
                _ = omemo.store.setStatus(status.toTrust(.undecided), forIdentity: identity.address)
                try? database.setTrust(.undecided, sender: device.jid, device: identity.address.deviceId)
            }
        }
    }

    /// Sends a failed message again.
    public func retry(_ message: Message) throws {
        guard message.direction == .outgoing, message.status == .failed, let id = message.remoteId,
              let peer = try database.conversation(id: message.conversationId)?.peer else { return }
        lock.withLock { $0.bounces.forget(.message(id)) }
        try database.markPending(conversationId: message.conversationId, remoteId: id)
        var pending = message
        pending.status = .pending
        pending.error = nil
        transmit(pending, to: peer)
    }

    /// Why `message` has nothing to point at. Our own message in a room that
    /// names its other messages will get an id once the room echoes it; any
    /// other message never will.
    private func reactionBlocker(for message: Message, peer: JID) throws -> MessageActionError {
        guard isGroup(peer), message.direction == .outgoing else { return .cannotReact }
        return try database.hasStanzaIds(conversationId: message.conversationId) ? .notYetConfirmed : .cannotReact
    }

    /// Adds or removes our `emoji` reaction on `message`.
    public func toggleReaction(_ emoji: String, on message: Message, peer: JID) throws {
        var mine = try database.reactions(on: message, from: account)
        if mine.contains(emoji) { mine.remove(emoji) } else { mine.insert(emoji) }
        try setMyReactions(mine, on: message, peer: peer)
    }

    /// Sends our reactions on `message` again, after the other side never got
    /// them (see `ConversationItem.ownReactions`).
    public func retryReactions(on message: Message, peer: JID) throws {
        try setMyReactions(database.reactions(on: message, from: account), on: message, peer: peer)
    }

    /// Takes our reactions on `message` back, after the other side never got
    /// them: it may have the earlier ones, so the empty set goes out.
    public func removeReactions(on message: Message, peer: JID) throws {
        try setMyReactions([], on: message, peer: peer)
    }

    /// Makes `mine` our reactions on `message`, here and for the others.
    /// Offline, they stay pending and go out once a session is back.
    private func setMyReactions(_ mine: Set<String>, on message: Message, peer: JID) throws {
        // A room we left never becomes ready, so the reactions would stay
        // pending until a session drops them without a word.
        guard (try database.groupChat(peer))?.hasLeft != true else { throw MessageActionError.leftGroup }
        guard let messageId = message.id, let target = reference(to: message) else {
            throw try reactionBlocker(for: message, peer: peer)
        }
        let route = route(to: peer)
        let me = Author(jid: account, nick: try nickname(in: peer), occupantId: route.occupantId)
        let id = OutboundStanza.newId()
        try database.setReactions(mine, from: me, conversationId: message.conversationId, messageRef: target, pendingId: id)
        let stanza = OutboundStanza.reactions(mine, to: route, target: target, id: id)
        whenReady(route) { [self] in writeReactions(stanza, id: id, messageId: messageId, peer: peer) }
    }

    /// Marks the conversation read and tells the peer and our other devices.
    public func markRead(_ conversation: Conversation) throws {
        guard let id = conversation.id else { return }
        try database.markRead(conversationId: id, owingReadState: true)
        announceRead(conversation, id: id)
    }

    /// Marks the conversation read up to `message`, the newest one the user
    /// has seen, and tells the peer and our other devices about that message
    /// rather than the last one. Seeing an older message than we've already
    /// read changes nothing, so the read point never moves backwards.
    public func markRead(_ conversation: Conversation, through message: Message) throws {
        guard let id = conversation.id, message.direction == .incoming,
              try database.hasUnread(conversationId: id, through: message.timestamp) else { return }
        try database.markRead(conversationId: id, through: message.timestamp, owingReadState: true)
        announceRead(conversation, id: id, through: message.timestamp)
    }

    /// `through` bounds which message the peer's marker names, since that
    /// needs a message that asked for one, which may be an older one.
    private func announceRead(_ conversation: Conversation, id: Int64, through date: Date = .distantFuture) {
        // Read markers in groups would tell everyone; only our devices hear.
        if conversation.kind == .chat { sendDisplayed(conversationId: id, to: conversation.peer, through: date) }
        publishOwedReadStates()
    }

    func write(_ stanza: Stanza) {
        guard isConnected else { return }
        client.context.writer.write(stanza)
    }

    /// Writes `stanza` and says whether the connection took it. Martin only
    /// tells so in its completion, after its session has looked at its own
    /// state, so this waits for that, suspended rather than holding a thread:
    /// callers come from the main actor and the cooperative pool. If no
    /// answer comes in time the stanza is taken to have gone, as a spurious
    /// "offline" would make the user send an action twice.
    func writeAwaitingHandOver(_ stanza: Stanza) async -> Bool {
        guard isConnected else { return false }
        return await withCheckedContinuation { continuation in
            let once = Once()
            client.context.writer.write(stanza) { result in
                guard once.first() else { return }
                if case .failure = result { continuation.resume(returning: false) } else { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.first() { continuation.resume(returning: true) }
            }
        }
    }
}

/// Runs only the latest of a burst of scheduled actions.
final class Debouncer: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        let mine = lock.withLock { generation += 1; return generation }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard lock.withLock({ generation == mine }) else { return }
            work()
        }
    }
}

/// A contact's availability and status as they changed. A nil presence means
/// the session has none for them.
public struct PeerUpdate: Sendable {
    public let jid: JID
    public let presence: ContactPresence?
    public let status: String?

    public init(jid: JID, presence: ContactPresence?, status: String?) {
        self.jid = jid
        self.presence = presence
        self.status = status
    }
}

/// Work a new session does as part of connecting, which a resumed stream
/// has to be told it still owes.
struct OwedOnResume: OptionSet, Sendable {
    let rawValue: Int
    /// Our presence changed while disconnected. Martin sends it on a new
    /// session, but a resumed one keeps what the server last had.
    static let presence = OwedOnResume(rawValue: 1 << 0)
    /// The last push enable failed.
    static let push = OwedOnResume(rawValue: 1 << 1)
    /// Who may read our profile was changed, or failed to change, while
    /// it couldn't be applied.
    static let profileAccess = OwedOnResume(rawValue: 1 << 2)
}
