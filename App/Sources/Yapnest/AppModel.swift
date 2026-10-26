import Combine
import Foundation
import Observation
import os
import SwiftUI
import UIKit
import UserNotifications
import YapnestKit
import YapnestCallMedia

/// Runs blocking work, the database's and the disk's, off the main thread.
/// Callers update their state on the main thread once it's done.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: work).value
}

func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

/// Owns the signed-in account's session and exposes its state to the UI.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case loading
        case signedOut
        case signedIn(XMPPSession)
    }

    private(set) var phase: Phase = .loading
    private(set) var connection: XMPPSession.State = .disconnected(error: nil) {
        didSet { if connection != oldValue { watchCatchUp() } }
    }
    /// Whether loading the saved account, or catching up once connected, has
    /// gone on past `SlowStatusRule.gracePeriod`. Both are done in a moment on
    /// every launch, and a spinner shown for a few frames reads as a hitch.
    private(set) var loadingIsSlow = false
    private(set) var catchUpIsSlow = false
    @ObservationIgnored private var catchUpWatch: Task<Void, Never>?
    /// Peers currently typing to us.
    private(set) var typing: Set<JID> = []
    /// When each typing peer last sent `composing`, for expiring stale ones.
    private var composingSince: [JID: Date] = [:]
    /// Runs only while someone is typing.
    private var typingExpiry: Task<Void, Never>?
    /// Contacts' availability, from the session.
    private(set) var presences: [JID: ContactPresence] = [:]
    /// Contacts online with a device that takes calls.
    private(set) var callablePeers: Set<JID> = []
    /// The callable peers with a device that takes video too.
    private(set) var videoCallablePeers: Set<JID> = []
    @ObservationIgnored private var callableHold = CallableHold()
    @ObservationIgnored private var videoCallableHold = CallableHold()
    /// Runs while a peer who left is still held on offer.
    @ObservationIgnored private var callableExpiry: Task<Void, Never>?
    /// The dot to show for `peer`: only contacts whose presence we receive have
    /// one, since for anyone else "offline" would just mean unknown.
    func presence(of peer: JID, contact: Contact?, isGroup: Bool) -> ContactPresence? {
        !isGroup && contact?.seesPresence == true ? presences[peer] ?? .offline : nil
    }
    /// Contacts' status messages, where they have one.
    private(set) var statuses: [JID: String] = [:]
    /// Group chats' state on the current connection.
    private(set) var rooms: [JID: RoomStatus] = [:]
    /// A conversation to show, from a tapped notification.
    var requestedConversation: JID?
    /// The chat list to show, from a tapped invitation notification.
    var requestsChatList = false
    /// What the menu bar asks the chat list to present.
    var requestedSheet: ChatListSheet?
    /// An `xmpp:` link waiting for the chat list to act on it. Kept while
    /// signed out, so it's handled once the user has signed in.
    var pendingLink: XMPPURI?
    /// Whether the welcome screen that asks for the privacy settings is up. Set
    /// by the first sign-in on this install, not by a restored session, so an
    /// update doesn't ask people who set the app up long ago.
    var showsWelcome = false
    /// Set when a link couldn't be understood; the window says so.
    var linkProblem: String?
    /// Counts the menu bar's Find in Chat, which the open chat answers.
    var chatSearchRequests = 0
    /// Bumped by Edit Last Message in the Mac's menu; the open chat answers it.
    var editLastRequests = 0

    /// How many of a chat's own sheets (settings, GIF and location pickers)
    /// are up. The menu bar's commands are off meanwhile, as SwiftUI would
    /// queue their sheet until the first closes.
    private(set) var conversationSheets = SheetCounter()
    var hasConversationSheet: Bool { conversationSheets.isPresenting }

    func conversationSheetAppeared() { conversationSheets.presented() }
    func conversationSheetDisappeared() { conversationSheets.dismissed() }

    /// What the model reaches outside itself for: the keychain, the process
    /// lock, the disk and the clock. Tests swap these; the defaults are the app's.
    struct Environment {
        var credentials: any CredentialStoring = CredentialStore()
        var sessionLock: ProcessLock = SharedContainer.sessionLock
        /// How long one wait for the process lock lasts before it checks the session is still wanted.
        var lockTimeout: TimeInterval = 30
        var accountDirectory: @Sendable (JID) -> AccountDirectory = { AccountDirectory(account: $0) }
        /// Starts a session's connection once the lock is held.
        var connect: @MainActor (XMPPSession) -> Void = { $0.connect() }
        /// Tells the push relay to stop, as the first step of signing out.
        var disablePush: @MainActor (XMPPSession) async -> Void = { await $0.disablePush() }
        /// How long a session gets to finish what's in flight after the app leaves.
        var suspendDelay: Duration = .seconds(8)
        var slowStatusDelay: Duration = SlowStatusRule.gracePeriod
        var typingLifetime: TimeInterval = 30
        var typingSweepInterval: Duration = .seconds(5)
        var registersForNotifications = true
        /// Whether the badge and delivered notifications follow the account. Setting a badge
        /// asks for permission on a fresh install, and that alert leaves the app inactive.
        var managesBadge = true
        /// Asks the server for a new password.
        var changePassword: @MainActor (XMPPSession, _ new: String, _ current: String) async throws -> Void = {
            try await $0.changePassword(to: $1, current: $2)
        }
        /// Whether the server accepts a password for the session's account, by a
        /// sign-in of its own. Asked when the typed current password differs from
        /// the keychain's, which another client's change leaves stale.
        var verifyPassword: @MainActor (XMPPSession, _ password: String) async throws -> Bool = {
            try await $0.accepts(password: $1)
        }
        /// Drops every client's FAST token: the app's and the extensions'. The
        /// server may have invalidated them with the old password, and none of
        /// them can tell the others that the password changed.
        var forgetFastTokens: @MainActor () -> Void = { KeychainFastTokenStore.deleteAll() }
        /// What signing out clears beyond the account's own folder.
        var forgetSharedState: @MainActor () -> Void = {
            KeychainFastTokenStore.deleteAll()
            KeychainIdentityKeyStore.deleteAll()
            ShareSuggestions.removeAll()
            DraftWriter.shared.forgetAll()
        }
        /// The diagnostic log and the key its ids are hashed with, which hold
        /// nothing of the next account's.
        var forgetDiagnostics: @MainActor () -> Void = { DiagLog.reset() }
    }

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var credentials: any CredentialStoring { environment.credentials }
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    /// Shared with the notification and share extensions: whoever holds it runs
    /// the account's session.
    @ObservationIgnored private var sessionLock: ProcessLock { environment.sessionLock }
    @ObservationIgnored private(set) var isActive = true
    /// Kept for a session that appears while the app is already away.
    @ObservationIgnored private var isBackground = false
    @ObservationIgnored private var suspension: Task<Void, Never>?
    /// Waits for a call to end so the suspension it held back can follow.
    @ObservationIgnored private var callWatch: AnyCancellable?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The sign-out cleanup still running. It frees state that belongs to the
    /// account being left, so a new session must not start before it ends.
    @ObservationIgnored private var signingOut: Task<Void, Never>?
    @ObservationIgnored private var unreadObservation: Task<Void, Never>?
    /// Hears from the share extension when it leaves messages for us.
    @ObservationIgnored private var pendingSends: PendingSendsSignal?
    #if targetEnvironment(macCatalyst)
    @ObservationIgnored private var idleWatch: IdleWatch?
    #endif
    /// Claiming notifications for new messages, and whether more came since it started.
    @ObservationIgnored private var claim: Task<Void, Never>?
    @ObservationIgnored private var claimsAgain = false
    @ObservationIgnored private let logger = Logger(subsystem: "Yapnest", category: "AppModel")

    /// The signed-in account's call, for CallKit and the in-call screen.
    let calls = CallController()

    /// Link previews for the signed-in account.
    @ObservationIgnored private(set) var linkPreviews: LinkPreviewer?

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    var session: XMPPSession? {
        if case .signedIn(let session) = phase { session } else { nil }
    }

    /// Whether the process is only hosting unit tests. The app is the test
    /// host, so launching it would otherwise sign in whatever account the
    /// simulator's keychain still holds and ask for notification permission,
    /// whose alert leaves the app inactive. xctest sets the configuration path
    /// in the environment before the app launches.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func start() {
        Presenter.model = self
        guard case .loading = phase, !isStarting else { return }
        isStarting = true
        Task { [weak self, delay = environment.slowStatusDelay] in
            try? await Task.sleep(for: delay)
            guard let self, case .loading = phase else { return }
            loadingIsSlow = true
        }
        Self.moveToSharedContainer()
        Redacted.prepare()
        #if DEBUG
        if let fixture = DevFixture.requested {
            startFixture(fixture)
            return
        }
        // Sign in from the environment, for driving the simulator from scripts.
        let env = ProcessInfo.processInfo.environment
        if let address = env["YAPNEST_DEV_ACCOUNT"], let jid = JID(address), let password = env["YAPNEST_DEV_PASSWORD"] {
            phase = .signedOut
            let credentials = XMPPSession.Credentials(jid: jid, password: password, host: env["YAPNEST_DEV_HOST"] ?? "127.0.0.1", port: 5222, disableTLS: true)
            Task {
                do { try await signIn(credentials) } catch { DiagLog.error(.app, "Dev sign-in failed", .error(error)) }
            }
            return
        }
        #endif
        do {
            if let saved = try credentials.load() {
                // Saving again moves it to the group the extension reads.
                if !SharedContainer.defaults.bool(forKey: "keychainShared") {
                    try credentials.save(saved)
                    SharedContainer.defaults.set(true, forKey: "keychainShared")
                }
                // Opening the database can migrate it, so it stays on the
                // loading screen until a background task is done.
                Task {
                    await restoreSession(saved)
                    isStarting = false
                }
                return
            }
        } catch {
            DiagLog.error(.app, "Failed to restore account", .error(error))
        }
        phase = .signedOut
        isStarting = false
    }

    @ObservationIgnored private var isStarting = false

    private func watchCatchUp() {
        catchUpWatch?.cancel()
        if catchUpIsSlow { catchUpIsSlow = false }
        guard connection == .connected(isSyncing: true) else { return }
        catchUpWatch = Task { [weak self, delay = environment.slowStatusDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.catchUpIsSlow = true
        }
    }

    /// Signs in to the saved account. A welcome the last run was closed
    /// before answering is shown again.
    func restoreSession(_ saved: XMPPSession.Credentials) async {
        do {
            let session = try await makeSession(saved)
            showsWelcome = await offMain { (try? session.database.setting(.welcomeShown)) == "pending" }
            phase = .signedIn(session)
            connect(session)
            didSignIn(session)
            applyScenePhase(to: session)
        } catch {
            DiagLog.error(.app, "Failed to restore account", .error(error))
            phase = .signedOut
        }
    }

    #if DEBUG
    /// Signs in to a fixture's account, filled from scratch on every launch.
    /// It never connects (see `connect(_:)`), and skips what a real sign-in
    /// starts: notifications, the badge and the share extension.
    private func startFixture(_ fixture: DevFixture) {
        let credentials = XMPPSession.Credentials(jid: DevFixture.account, password: "fixture")
        let directory = environment.accountDirectory(DevFixture.account)
        Task {
            do {
                try? FileManager.default.removeItem(at: directory.url)
                let session = try await makeSession(credentials)
                try await offMain { try fixture.fill(session.database) }
                fixture.configure(session)
                // `YAPNEST_DEV_CALLABLE=<address>[,<address>...]` offers the Call
                // and Video buttons, which an offline fixture never learns from a server.
                if let callable = ProcessInfo.processInfo.environment["YAPNEST_DEV_CALLABLE"] {
                    let peers = Set(callable.split(separator: ",").compactMap { JID(String($0)) })
                    session.callablePeers.send(peers)
                    session.videoCallablePeers.send(peers)
                }
                DevFixture.deliverIncoming(into: session.database)
                showsWelcome = ProcessInfo.processInfo.environment["YAPNEST_DEV_WELCOME"] == "1"
                phase = .signedIn(session)
            } catch {
                DiagLog.error(.app, "Fixture failed", .error(error))
                phase = .signedOut
            }
            isStarting = false
        }
    }
    #endif

    /// Connects with `credentials`; keeps them only if the server accepts them.
    func signIn(_ credentials: XMPPSession.Credentials) async throws {
        // The cleanup would otherwise release the new session's lock, drop
        // its subscriptions and, for the same account, delete its database.
        await signingOut?.value
        let session = try await makeSession(credentials)
        // It holds the lock and the database like a signed-in session, so the
        // scene phase applies to it too.
        pendingSignIn = session
        defer {
            if pendingSignIn === session { pendingSignIn = nil }
            if suspendedSignIn === session { suspendedSignIn = nil }
        }
        connect(session)
        // Fail on the first dropped attempt rather than retrying behind a spinner.
        var attempted = false
        for await state in session.state.values {
            switch state {
            case .connected:
                do {
                    try self.credentials.save(credentials)
                } catch {
                    // Otherwise the connected session would stay behind the
                    // login form, holding the lock and the database.
                    teardown(session)
                    throw error
                }
                SharedContainer.defaults.set(true, forKey: "keychainShared")
                // Recorded as pending, so a launch before Continue asks again.
                showsWelcome = await offMain {
                    // Left pending by a run that never got as far as Continue.
                    switch try? session.database.setting(.welcomeShown) {
                    case "1": return false
                    case "pending": return true
                    default: return (try? session.database.setSetting(.welcomeShown, "pending")) != nil
                    }
                }
                phase = .signedIn(session)
                didSignIn(session)
                applyScenePhase(to: session)
                return
            case .failed(let reason):
                teardown(session)
                throw SignInError(message: reason)
            case .connecting:
                attempted = true
                // Not while away: that would be an attempt from before the suspension.
                if isActive { suspendedSignIn = nil }
            case .disconnected(let error):
                // Our own suspension in the background, not the server's
                // answer: coming back connects again, and that decides. An
                // error that arrives while away is the cut connection's.
                if suspendedSignIn === session, error == nil || !isActive {
                    attempted = false
                    continue
                }
                guard attempted || error != nil else { continue }
                teardown(session)
                throw SignInError(message: error ?? "Couldn't connect to the server.")
            }
        }
        // The stream ends when the task is cancelled; the session would
        // otherwise stay connected, or suspended, behind the login form.
        if Task.isCancelled {
            teardown(session)
            throw CancellationError()
        }
    }

    /// The session a sign-in is connecting, until the server accepts or refuses it.
    @ObservationIgnored private var pendingSignIn: XMPPSession?

    /// The pending sign-in's session once the app has suspended it, until it
    /// connects again. Its disconnect is ours and mustn't fail the sign-in.
    @ObservationIgnored private var suspendedSignIn: XMPPSession?

    /// Changes the account's password, here and on the server. The current
    /// one is checked against the one this device signed in with before
    /// anything is sent; if it differs, the server decides, as the password
    /// may have been changed from another client. Afterwards the keychain, which the extensions read
    /// their credentials from, holds the new one and no FAST token is left.
    func changePassword(current: String, new: String) async throws {
        guard let session else { throw XMPPSession.PasswordError.offline }
        let stored = try await offMain { [credentials] in try credentials.load() }
        // Not stored for a dev sign-in from the environment; the server then judges.
        if let stored, stored.jid == session.account, stored.password != current {
            guard try await environment.verifyPassword(session, current) else {
                throw XMPPSession.PasswordError.wrongCurrentPassword
            }
        }
        do {
            try await environment.changePassword(session, new, current)
        } catch XMPPSession.PasswordError.outcomeUnknown {
            // Kept beside the old one, so a sign-in the server refuses for it
            // can try the new one (the session does, and the extensions). No
            // client keeps a token, so the next sign-in tells which is right.
            environment.forgetFastTokens()
            if var stored, stored.jid == session.account {
                stored.candidatePassword = new
                do {
                    try await offMain { [credentials, stored] in try credentials.update(stored) }
                } catch {
                    DiagLog.error(.app, "Keeping the new password as a candidate failed", .error(error))
                }
            }
            throw XMPPSession.PasswordError.outcomeUnknown
        }
        // The server has the new password from here on, so whatever fails next
        // must not leave a token or the old password to sign in with.
        environment.forgetFastTokens()
        guard var stored, stored.jid == session.account else { return }
        stored.password = new
        stored.candidatePassword = nil
        do {
            try await offMain { [credentials, stored] in try credentials.update(stored) }
        } catch {
            throw XMPPSession.PasswordError.changedButNotSaved
        }
    }

    /// A session that held a candidate password has signed in, with the stored
    /// password or the candidate. The keychain keeps the one that worked.
    private func storeConfirmedPassword(_ password: String, wasCandidate: Bool, account: JID) async {
        do {
            try await offMain { [credentials] in
                guard let stored = try credentials.load(), stored.jid == account else { return }
                try credentials.update(stored.confirming(password))
            }
        } catch {
            DiagLog.error(.app, "Storing the confirmed password failed", .error(error))
        }
        // The old password's tokens, in the extensions too.
        if wasCandidate { environment.forgetFastTokens() }
    }

    /// Closes the welcome screen for good, once its choices are saved.
    func finishWelcome() async throws {
        if let session {
            try await offMain { try session.database.setSetting(.welcomeShown, "1") }
        }
        showsWelcome = false
    }

    func signOut() {
        guard let session else { return }
        showsWelcome = false
        phase = .signedOut
        try? credentials.delete()
        environment.forgetSharedState()
        let folder = environment.accountDirectory(session.account).url
        let task = Task {
            await environment.disablePush(session)
            teardown(session)
            // The folder holds the database and every attachment.
            await offMain { try? FileManager.default.removeItem(at: folder) }
            if environment.managesBadge {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
            // Last, so nothing the steps above log lands in the next account's log.
            environment.forgetDiagnostics()
        }
        signingOut = task
        Task {
            await task.value
            if signingOut == task { signingOut = nil }
        }
    }

    /// Inactive covers system alerts and Notification Center too: the app is
    /// still on screen, so only the background suspends the session.
    ///
    /// The Mac never suspends apps, so there the session stays connected,
    /// and the app notifies for what arrives while another app is in front.
    func scenePhaseChanged(active: Bool, background: Bool) {
        guard active != isActive || background != isBackground else { return }
        isActive = active
        isBackground = background
        DiagLog.info(.app, "Scene phase changed", .bool("active", active), .bool("background", background))
        // A suspended app is not given time to write what it buffered.
        if background { DiagLog.flushSoon() }
        guard let session = SessionScope.current(signedIn: session, pendingSignIn: pendingSignIn) else { return }
        if active {
            suspension?.cancel()
            suspension = nil
            callWatch = nil
            endBackgroundTask()
            // Before connecting, so a new session starts with what was chosen.
            session.setAway(false)
            connect(session)
            // Seen here: no notification for any of it.
            let database = session.database
            Task { await offMain { _ = try? database.claimNotifications(notifies: false) } }
            // The unread observation clears quiet notifications only when the counts change.
            if environment.managesBadge { Task { await UNUserNotificationCenter.current().removeQuietNotifications() } }
        } else if background, !Platform.staysConnected {
            suspendSoon(session)
        }
        session.setActive(active)
    }

    /// Follows the app's lifecycle as UIKit posts it, and only that: it is the
    /// one source of `scenePhaseChanged`. SwiftUI's scene phase can reach
    /// `onChange` only after the app was suspended, in no fixed order with
    /// UIKit's, so a late background from it after UIKit's foreground would
    /// suspend a session that is on screen. The Mac posts the same
    /// notifications. Also, a session left to SwiftUI's phase still held the
    /// process lock and the database when the app was suspended, which iOS
    /// kills an app for (0xdead10cc). UIKit posts these before it lets the
    /// app go, so the background task that lets go of them starts in time.
    func followLifecycle(of center: NotificationCenter = .default) {
        let phases: [(Notification.Name, active: Bool, background: Bool)] = [
            (UIApplication.didBecomeActiveNotification, true, false),
            (UIApplication.willResignActiveNotification, false, false),
            (UIApplication.didEnterBackgroundNotification, false, true),
            (UIApplication.willEnterForegroundNotification, false, false),
        ]
        lifecycleObservers = phases.map { name, active, background in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // Posted on the main thread, and handled before it returns.
                MainActor.assumeIsolated { self?.scenePhaseChanged(active: active, background: background) }
            }
        }
    }

    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []

    /// A session that appears while the app is away missed the transition
    /// `scenePhaseChanged` acts on. Left connected, it would hold the process
    /// lock and the database with no background task, which iOS kills a
    /// suspended app for.
    private func applyScenePhase(to session: XMPPSession) {
        guard !isActive else { return }
        if isBackground, !Platform.staysConnected { suspendSoon(session) }
        session.setActive(false)
    }

    // MARK: Background

    /// Connects once the notification or share extension is done with the session.
    private func connect(_ session: XMPPSession) {
        #if DEBUG
        if DevFixture.isActive { return }
        #endif
        AppDatabase.resume()
        // The extension may have stored messages this process hasn't seen.
        let database = session.database
        Task { await offMain { try? database.notifyExternalChanges() } }
        if sessionLock.tryLock(as: .app) {
            environment.connect(session)
            return
        }
        // Connecting without the lock would leave extensions free to run a
        // session beside ours, and make `sendShared` ignore the share
        // extension, so keep waiting for it. The notification extension's
        // catch-up is short and the system ends it within 30 seconds, but the
        // share extension may take longer.
        guard lockWaiter !== session else { return }
        lockWaiter = session
        Task {
            defer { if lockWaiter === session { lockWaiter = nil } }
            while true {
                let (sessionLock, timeout) = (sessionLock, environment.lockTimeout)
                let locked = await Task.detached { sessionLock.lock(timeout: timeout, as: .app) }.value
                guard isActive, SessionScope.isWanted(session, signedIn: self.session, pendingSignIn: pendingSignIn) else {
                    // Not if a newer session waits on the same lock: it would take it from there.
                    if locked, lockWaiter === session { sessionLock.unlock() }
                    return
                }
                if locked {
                    let database = session.database
                    await offMain { try? database.notifyExternalChanges() }
                    environment.connect(session)
                    return
                }
                logger.warning("Another process kept the session; still waiting")
            }
        }
    }

    /// The session a task is waiting on the process lock for.
    @ObservationIgnored private var lockWaiter: XMPPSession?

    /// Gives what's in flight a few seconds after leaving the app, then lets
    /// the server keep the session, so it pushes, and lets go of what iOS
    /// would kill a suspended app for holding.
    private func suspendSoon(_ session: XMPPSession) {
        guard suspension == nil, callWatch == nil else { return }
        guard !holdsForCall(session) else { return }
        // Sent now, while the connection is still up to carry it.
        session.setAway(true)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Suspend session") { [weak self] in
            MainActor.assumeIsolated { self?.suspend(session) }
        }
        suspension = Task {
            try? await Task.sleep(for: environment.suspendDelay)
            guard !Task.isCancelled else { return }
            suspend(session)
        }
    }

    private func suspend(_ session: XMPPSession) {
        guard !isActive, suspension != nil || backgroundTask != .invalid else { return }
        suspension?.cancel()
        suspension = nil
        // The audio background mode keeps the process running during a call,
        // and a suspended session would cut it. The task still has to end here.
        if holdsForCall(session) {
            endBackgroundTask()
            return
        }
        if pendingSignIn === session { suspendedSignIn = session }
        session.suspend()
        DiagLog.info(.app, "Session suspended")
        DiagLog.flush()
        sessionLock.unlock()
        AppDatabase.suspend()
        endBackgroundTask()
    }

    /// Whether a call keeps the session from being suspended. If so, suspends
    /// once the call is over.
    private func holdsForCall(_ session: XMPPSession) -> Bool {
        guard session.callState.value?.isOver == false else { return false }
        guard callWatch == nil else { return true }
        callWatch = session.callState
            .filter { $0?.isOver != false }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.callWatch = nil
                    guard SessionScope.isWanted(session, signedIn: self.session, pendingSignIn: self.pendingSignIn) else { return }
                    if !self.isActive, self.isBackground, !Platform.staysConnected { self.suspendSoon(session) }
                }
            }
        return true
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Notifications

    private func didSignIn(_ session: XMPPSession) {
        observeUnread(session)
        observeShares()
        #if targetEnvironment(macCatalyst)
        idleWatch = IdleWatch(session: session)
        #endif
        // The token doesn't depend on the permission, and with it, allowing
        // notifications later in Settings needs nothing else.
        guard environment.registersForNotifications else { return }
        UIApplication.shared.registerForRemoteNotifications()
        #if DEBUG
        // A script driving the simulator can't answer the permission alert,
        // which would cover the screen it records.
        if ProcessInfo.processInfo.environment["YAPNEST_DEV_ACCOUNT"] != nil { return }
        #endif
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if !granted { logger.info("Notifications not allowed") }
        }
    }

    /// The share extension can't send while we hold the session, which on the
    /// Mac is always. It writes its messages first, then tells us; any it
    /// left while we were away go out after the next catch-up as usual.
    private func observeShares() {
        pendingSends = PendingSendsSignal { [weak self] in
            Task { @MainActor in self?.sendShared() }
        }
    }

    private func sendShared() {
        // Without the lock, the database is let go of too, and the next
        // connection sends what the extension wrote.
        guard let session, sessionLock.isLocked else { return }
        Task.detached(priority: .userInitiated) {
            try? session.database.notifyExternalChanges()
            session.resendPending()
        }
    }

    func receivedPushToken(_ token: Data) {
        // The build configuration says nothing here: the scheme runs Release,
        // signed for development, so the token is a sandbox one. The profile
        // the app was signed with tells which. A changed environment makes
        // setPushToken register again, which repairs installs that reported
        // the wrong one.
        guard let session else { return }
        let sandbox = Self.pushEnvironment == .sandbox
        Task { await offMain { session.setPushToken(token, sandbox: sandbox) } }
    }

    /// Read once: the profile can't change while the app runs.
    private static let pushEnvironment: PushEnvironment = {
        let profile = ["embedded.mobileprovision", "Contents/embedded.provisionprofile"]
            .lazy.compactMap { try? Data(contentsOf: Bundle.main.bundleURL.appending(path: $0)) }.first
        if let profile, PushEnvironment.apsEnvironment(in: profile) == nil {
            Logger(subsystem: "Yapnest", category: "AppModel")
                .error("The provisioning profile has no push environment; assuming production")
        }
        return PushEnvironment.from(profile: profile)
    }()

    /// Messages that arrive while the app is in the background, before it lets
    /// the server push, get their notification from here.
    ///
    /// A catch-up brings messages by the hundred, each stored while the next
    /// is being written: claiming is a write, so it runs off the main thread,
    /// and once for all that arrived meanwhile.
    private func notifyInBackground(_ session: XMPPSession) {
        guard claim == nil else {
            claimsAgain = true
            return
        }
        claim = Task {
            repeat {
                claimsAgain = false
                let database = session.database, notifies = !isActive
                let (claimed, badge) = await Task.detached(priority: .utility) {
                    ((try? database.claimNotificationsAndEdits(notifies: notifies)) ?? ([], []), try? database.unreadCount())
                }.value
                let (notifications, edited) = claimed
                guard !isActive, self.session === session else { continue }
                await MessageNotification.replaceDelivered(edited, badge: badge, avatars: session.avatars)
                await MessageNotification.replaceHeld(notifications, badge: badge, avatars: session.avatars)
                for notification in notifications where !notification.isQuiet {
                    try? await UNUserNotificationCenter.current().add(await notification.request(badge: badge, avatars: session.avatars))
                }
            } while claimsAgain
            claim = nil
        }
    }

    /// Keeps the badge on the unread count, and clears a conversation's
    /// notifications once it's read, here or on another device.
    private func observeUnread(_ session: XMPPSession) {
        unreadObservation?.cancel()
        guard environment.managesBadge else { return }
        unreadObservation = Task {
            var last: [JID: Int]?
            await session.database.forEachValue(of: session.database.observeUnreadBadge(), "Unread") { badge in
                let center = UNUserNotificationCenter.current()
                // Every time: the notification extension sets the badge as
                // well, and a message it counted can be read before this
                // sees the count go up, so the counts alone may not change.
                try? await center.setBadgeCount(badge.count)
                DockBadge.showDot(badge.showsDot)
                let counts = badge.counts
                guard counts != last else { return }
                last = counts
                // Archived and deleted chats aren't in the counts at all, so
                // it's what's unread that stays, not what's read that goes.
                let delivered = await center.deliveredNotifications()
                let stale = AppDatabase.staleNotifications(
                    threads: delivered.map { ($0.request.identifier, $0.request.content.threadIdentifier) },
                    unread: counts)
                let quiet = delivered.filter(\.isQuiet).map(\.request.identifier)
                center.removeDeliveredNotifications(withIdentifiers: stale + quiet)
            }
        }
    }

    /// The chats that are alive. A link that prefills the composer of one
    /// reaches it here.
    let liveConversations = LiveConversations()

    func open(_ peer: JID) {
        requestedConversation = peer
    }

    func openChatList() {
        requestsChatList = true
    }

    /// An `xmpp:` link from the system or from a message. Nothing is sent
    /// for it: the chat list asks the user first.
    func open(link url: URL) {
        guard let link = XMPPURI(url) else {
            linkProblem = String(localized: "This link isn't a valid Jabber address.")
            return
        }
        pendingLink = link
    }

    /// The shortcode recents the composer kept per device before emoji usage
    /// was synced become picks on the account that is signed in. Only one
    /// account is ever signed in, so the first one to open takes them.
    private nonisolated static func importEmojiRecents(into database: AppDatabase) {
        let key = "recentEmojiShortcodes"
        guard let recents = UserDefaults.standard.stringArray(forKey: key) else { return }
        guard (try? database.importEmojiRecents(recents)) != nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Opening the database and making the session read and migrate it, so
    /// that happens off the main thread.
    private func makeSession(_ credentials: XMPPSession.Credentials) async throws -> XMPPSession {
        let directory = environment.accountDirectory(credentials.jid)
        let relay = Self.pushRelay(for: credentials.jid)
        let session = try await offMain {
            let database = try directory.openDatabase()
            Self.importEmojiRecents(into: database)
            return try XMPPSession(
                credentials: credentials, resource: "yapnest-\(SharedContainer.deviceId)", directory: directory,
                database: database, pushRelay: relay, callMedia: WebRTCCallMediaFactory(),
            )
        }
        calls.attach(session)
        session.onPasswordConfirmed { [weak self] password, wasCandidate in
            Task { @MainActor in
                await self?.storeConfirmedPassword(password, wasCandidate: wasCandidate, account: credentials.jid)
            }
        }
        linkPreviews = LinkPreviewer(database: session.database, directory: directory.previews)
        cancellables = []
        session.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.connection = $0
                // After a reconnect we can't know who is still typing.
                if case .connected = $0 {} else { self?.clearTyping() }
            }
            .store(in: &cancellables)
        session.presences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let before = presences
                presences = $0
                // An unavailable peer can't be typing, and won't send "paused".
                // Someone we never had presence for (a stranger) isn't dropped.
                for peer in typing where $0[peer] == .offline || ($0[peer] == nil && before[peer] != nil) { stopTyping(peer) }
            }
            .store(in: &cancellables)
        session.callablePeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.callableHold.update($0, now: .now)
                self?.offerCallablePeers()
            }
            .store(in: &cancellables)
        session.videoCallablePeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.videoCallableHold.update($0, now: .now)
                self?.offerCallablePeers()
            }
            .store(in: &cancellables)
        session.statuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.statuses = $0 }
            .store(in: &cancellables)
        session.rooms
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rooms = $0 }
            .store(in: &cancellables)
        session.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &cancellables)
        return session
    }

    /// Publishes who is offered a call, and comes back when a peer who left
    /// stops being held.
    private func offerCallablePeers() {
        let now = ContinuousClock.now
        let offered = callableHold.offered(at: now), videoOffered = videoCallableHold.offered(at: now)
        if callablePeers != offered { callablePeers = offered }
        if videoCallablePeers != videoOffered { videoCallablePeers = videoOffered }
        callableExpiry?.cancel()
        guard let expiry = [callableHold.nextExpiry, videoCallableHold.nextExpiry].compactMap(\.self).min() else { return }
        callableExpiry = Task { [weak self] in
            try? await Task.sleep(until: expiry, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.offerCallablePeers()
        }
    }

    private func teardown(_ session: XMPPSession) {
        calls.detach()
        session.disconnect()
        sessionLock.unlock()
        unreadObservation?.cancel()
        pendingSends = nil
        #if targetEnvironment(macCatalyst)
        idleWatch?.stop()
        idleWatch = nil
        #endif
        cancellables = []
        connection = .disconnected(error: nil)
        presences = [:]
        callableExpiry?.cancel()
        callableHold = CallableHold()
        videoCallableHold = CallableHold()
        callablePeers = []
        videoCallablePeers = []
        statuses = [:]
        rooms = [:]
        clearTyping()
        requestedConversation = nil
        requestedSheet = nil
        linkPreviews = nil
    }

    private func handle(_ event: XMPPSession.Event) {
        switch event {
        case .chatState(let peer, let state):
            if state == .composing { startTyping(peer) } else { stopTyping(peer) }
        case .editedMessage(let message):
            if message.direction == .incoming, let session { notifyInBackground(session) }
        case .invitationHeld:
            if let session { notifyInBackground(session) }
        case .newMessage(let message):
            if message.direction == .incoming, let session {
                notifyInBackground(session)
                // A message ends the sender's typing indicator; with nobody
                // typing there's nothing to look up.
                if !typing.isEmpty {
                    let database = session.database, conversationId = message.conversationId
                    Task {
                        let peer = await offMain { try? database.reader.read { try Conversation.fetchOne($0, key: conversationId)?.peer } }
                        if let peer { stopTyping(peer) }
                    }
                }
            }
        }
    }

    // A `composing` is stale after about 30 seconds (XEP-0085 suggests), for
    // peers whose app died or whose network dropped mid-sentence.

    private func startTyping(_ peer: JID) {
        typing.insert(peer)
        composingSince[peer] = Date()
        guard typingExpiry == nil else { return }
        let interval = environment.typingSweepInterval
        typingExpiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                let cutoff = Date().addingTimeInterval(-environment.typingLifetime)
                for (peer, since) in composingSince where since < cutoff { stopTyping(peer) }
            }
        }
    }

    private func stopTyping(_ peer: JID) {
        typing.remove(peer)
        composingSince[peer] = nil
        if typing.isEmpty { typingExpiry?.cancel(); typingExpiry = nil }
    }

    private func clearTyping() {
        typing = []
        composingSince = [:]
        typingExpiry?.cancel()
        typingExpiry = nil
    }

    /// The App Store relay, or in development builds the local server's or
    /// `YAPNEST_PUSH_RELAY`.
    private static func pushRelay(for account: JID) -> JID {
        #if DEBUG
        if let relay = ProcessInfo.processInfo.environment["YAPNEST_PUSH_RELAY"].flatMap(JID.init(_:)) { return relay }
        if account.domain == "localhost" { return JID("push.localhost")! }
        #endif
        return XMPPSession.defaultPushRelay
    }

    /// Accounts lived in the app's own Application Support before the
    /// notification extension needed them.
    private static func moveToSharedContainer() {
        let fileManager = FileManager.default
        guard let old = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "accounts"),
              old != SharedContainer.accounts, fileManager.fileExists(atPath: old.path),
              !fileManager.fileExists(atPath: SharedContainer.accounts.path) else { return }
        do {
            try fileManager.createDirectory(at: SharedContainer.url, withIntermediateDirectories: true)
            try fileManager.moveItem(at: old, to: SharedContainer.accounts)
        } catch {
            DiagLog.error(.app, "Moving the accounts to the shared container failed", .error(error))
        }
    }
}

/// The saved account, in the keychain.
protocol CredentialStoring: Sendable {
    func load() throws -> XMPPSession.Credentials?
    func save(_ credentials: XMPPSession.Credentials) throws
    /// Replaces what's stored without removing it first.
    func update(_ credentials: XMPPSession.Credentials) throws
    func delete() throws
}

extension CredentialStore: CredentialStoring {}

struct SignInError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

extension View {
    /// Marks a sheet presented by a conversation, so `AppModel` knows one is up.
    func countsAsConversationSheet() -> some View { modifier(ConversationSheetCounter()) }
}

private struct ConversationSheetCounter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.conversationSheetAppeared() }
            .onDisappear { model.conversationSheetDisappeared() }
    }
}

/// The conversation models that are alive, on screen or kept in the
/// navigation stack under another chat. A link's text goes into the one
/// that is there, as it has read its draft already and would write its own
/// composer over one stored now. A chat that was left and released is gone
/// from here, and takes nothing.
@MainActor
final class LiveConversations {
    private struct Entry { weak var model: ConversationModel? }
    private var entries: [JID: Entry] = [:]

    func register(_ model: ConversationModel) {
        entries = entries.filter { $0.value.model != nil }
        entries[model.peer] = Entry(model: model)
    }

    func model(for peer: JID) -> ConversationModel? {
        entries[peer]?.model
    }
}
