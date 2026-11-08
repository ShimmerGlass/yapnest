import Foundation
import UIKit
import Testing
import YapnestKit
@testable import Yapnest

@MainActor
struct AppModelSessionTests {
    @Test func signingInRightAfterSigningOutKeepsTheNewSession() async throws {
        // The old session's cleanup is slow, so it would land after the new
        // session is up: it must not release its lock, drop its observers or
        // delete its database.
        let fixture = AppModelFixture(disablePush: { _ in try? await Task.sleep(for: .milliseconds(250)) })
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        model.signOut()
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(model.session)

        #expect(await stays(for: .milliseconds(700)) { fixture.lock.isLocked && FileManager.default.fileExists(atPath: fixture.databaseFile.path) })
        let peer = JID("peer@example.com")!
        session.peerUpdates.send(PeerUpdate(jid: peer, presence: .away, status: nil))
        await eventually("the new session's presences reach the model") { model.live.peer(peer).presence == .away }
    }

    @Test func aFailedCredentialSaveTearsTheSessionDown() async throws {
        let fixture = AppModelFixture()
        fixture.credentials.refusesToSave = true

        await #expect(throws: FakeCredentials.SaveFailed.self) { try await fixture.model.signIn(fixture.credentialsToSignIn) }

        #expect(fixture.model.session == nil)
        #expect(!fixture.lock.isLocked)
        #expect(fixture.connects.count == 1)
    }

    @Test func signingOutResetsWhatBelongedToTheAccount() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(model.session)
        let peer = JID("peer@example.com")!
        session.events.send(.chatState(peer, .composing))
        await eventually("typing starts") { model.live.peer(peer).isTyping }
        model.open(peer)
        model.requestedSheet = .newGroup
        #expect(model.linkPreviews != nil)

        model.signOut()

        await eventually("the account's state is reset") {
            model.typingPeers.isEmpty && model.requestedConversation == nil && model.requestedSheet == nil && model.linkPreviews == nil
        }
    }

    /// The ticket resumes the stream it names, so one that outlives the session would let an extension
    /// take over a session the app has ended. Closing the session for another reason than signing out
    /// leaves the folder, and the ticket in it, in place.
    @Test func endingTheSessionDeletesTheResumeTicket() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        let tickets = ResumeTicketStore(directory: AccountDirectory(url: fixture.root.appending(path: fixture.account.description)))
        tickets.save(.init(id: "stream", incoming: 1, outgoing: 1))
        #expect(tickets.load() != nil)

        await fixture.model.replaceEncryptionDevice()

        #expect(tickets.load() == nil)
    }

    /// They are made from the account's files, encrypted chats' among them,
    /// but kept outside its folder.
    @Test func signingOutDeletesTheCopiesOfReceivedFiles() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let gif = AnimatedImages.copyURL(for: URL(filePath: "/tmp/received.gif"))
        let opened = MacFileActions.copiesFolder.appending(path: "x/report.pdf")
        for file in [gif, opened] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        model.signOut()

        await eventually("the copies are deleted") {
            !FileManager.default.fileExists(atPath: gif.path) && !FileManager.default.fileExists(atPath: opened.path)
        }
    }

    @Test func signingOutDeletesTheDiagnosticLogLast() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        #expect(fixture.diagnosticsWipes == 0)

        model.signOut()

        await eventually("the log is deleted") { fixture.diagnosticsWipes == 1 }
    }

    @Test func aLinkOpenedBeforeSignInWaitsForIt() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        model.open(link: URL(string: "xmpp:friend@example.com?roster;preauth=tok")!)
        #expect(model.pendingLink?.action == .addContact(name: nil, preauth: "tok"))

        try await model.signIn(fixture.credentialsToSignIn)
        model.signOut()
        #expect(model.pendingLink != nil)

        model.open(link: URL(string: "xmpp:friend@example.com?message;body=%00")!)
        #expect(model.linkProblem != nil)
    }

    // MARK: The process lock

    @Test func aSignInWaitsForTheLockForAsLongAsItIsPending() async throws {
        // The lock is held for several waits' worth of time, and the account
        // isn't signed in yet: the waiter must not give up on it.
        let fixture = AppModelFixture(lockTimeout: 0.1)
        #expect(fixture.otherProcess.tryLock())
        let model = fixture.model!
        let signIn = Task { try await model.signIn(fixture.credentialsToSignIn) }
        defer { signIn.cancel() }

        #expect(await stays(for: .milliseconds(600)) { fixture.connects.isEmpty })
        // Waiting counts as running, so an extension doesn't wait for the app.
        #expect(fixture.appIsRunning())
        fixture.otherProcess.unlock()

        await eventually("the sign-in goes through") { model.session != nil }
        #expect(fixture.connects.count == 1)
        #expect(fixture.lock.isLocked)
    }

    // The first sign-in's waiter, no longer wanted, found the lock taken by
    // the second (one lock object per process) and let go of it, leaving the
    // new session running beside whatever an extension started.
    @Test func aWaiterLeftBehindBySigningInAgainKeepsTheNewSessionsLock() async throws {
        let fixture = AppModelFixture(lockTimeout: 0.1)
        #expect(fixture.otherProcess.tryLock())
        let model = fixture.model!
        let first = Task { try await model.signIn(fixture.credentialsToSignIn) }
        try await Task.sleep(for: .milliseconds(150))
        first.cancel()
        model.signOut()
        fixture.otherProcess.unlock()
        try await model.signIn(fixture.credentialsToSignIn)

        #expect(await stays(for: .milliseconds(600)) { fixture.lock.isLocked && fixture.appIsRunning() })
    }

    // An extension asking whether the app runs holds the app lock for an
    // instant. The app waited for it on the main thread, and after a second
    // went on without it, so extensions took the app for one of them.
    @Test func aSignInWaitsOutAnExtensionAskingWhetherTheAppRuns() async throws {
        let fixture = AppModelFixture(lockTimeout: 0.1)
        let asking = open(fixture.appLockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        #expect(flock(asking, LOCK_SH | LOCK_NB) == 0)
        let model = fixture.model!
        let signIn = Task { try await model.signIn(fixture.credentialsToSignIn) }
        defer { signIn.cancel() }
        #expect(await stays(for: .milliseconds(1_300)) { fixture.connects.isEmpty })
        flock(asking, LOCK_UN)
        close(asking)

        await eventually("the sign-in goes through") { model.session != nil }
        #expect(fixture.appIsRunning())
        #expect(fixture.lock.isLocked)
    }

    @Test func comingBackConnectsOnlyOnceTheLockIsFree() async throws {
        let fixture = AppModelFixture(lockTimeout: 0.1)
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        model.scenePhaseChanged(active: false, background: true)
        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
        // A suspended app must not keep extensions from deciding for themselves.
        #expect(!fixture.appIsRunning())
        #expect(fixture.otherProcess.tryLock())

        model.scenePhaseChanged(active: true, background: false)
        #expect(await stays(for: .milliseconds(500)) { fixture.connects.count == 1 })
        fixture.otherProcess.unlock()

        await eventually("it connects again") { fixture.connects.count == 2 }
        #expect(fixture.lock.isLocked)
        #expect(fixture.appIsRunning())
    }

    // MARK: Leaving the app

    @Test func leavingTheAppWhileSigningInSuspendsTheSession() async throws {
        let fixture = AppModelFixture()
        fixture.accepts = false
        let model = fixture.model!
        let signIn = Task { try await model.signIn(fixture.credentialsToSignIn) }
        defer { signIn.cancel() }
        await eventually("the sign-in connects") { fixture.lock.isLocked }

        model.scenePhaseChanged(active: false, background: true)

        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
    }

    /// An extension that takes the locks must find the ticket it resumes from: the locks are let go
    /// only once the session has saved it, which waits for the connection to close.
    @Test func theLocksAreLetGoOnlyOnceTheTicketIsSaved() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(fixture.connects.last)
        session.seedStreamForTesting(id: "stream")
        let tickets = ResumeTicketStore(directory: AccountDirectory(url: fixture.root.appending(path: fixture.account.description)))

        model.scenePhaseChanged(active: false, background: true)
        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }

        #expect(tickets.load()?.stream.id == "stream", "the lock was free before the ticket was saved")
        await eventually("the time to be given back") { fixture.openBackgroundTasks == 0 }
    }

    /// iOS takes the time back before the connection has closed: the ticket is saved with the counters as
    /// they stand and the locks go at once, without waiting.
    @Test func whenTheTimeRunsOutTheTicketIsSavedAndTheLocksGoAtOnce() async throws {
        let fixture = AppModelFixture(suspendDelay: .seconds(30))
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(fixture.connects.last)
        session.seedStreamForTesting(id: "stream")
        let tickets = ResumeTicketStore(directory: AccountDirectory(url: fixture.root.appending(path: fixture.account.description)))
        model.scenePhaseChanged(active: false, background: true)
        let expiry = try #require(fixture.suspensionExpiry)
        #expect(fixture.lock.isLocked)

        expiry()

        #expect(!fixture.lock.isLocked)
        #expect(tickets.load()?.stream.id == "stream")
        #expect(fixture.openBackgroundTasks == 0)
    }

    @Test func leavingTheAppAsUIKitPostsItSuspendsTheSession() async throws {
        // SwiftUI's scene phase can come after iOS suspended the app, which
        // kills one holding the lock; UIKit's notification comes before.
        let fixture = AppModelFixture()
        let model = fixture.model!
        let center = NotificationCenter()
        model.followLifecycle(of: center)
        try await model.signIn(fixture.credentialsToSignIn)
        #expect(fixture.lock.isLocked)

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
    }

    @Test func theSamePhaseTwiceChangesNothing() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        let center = NotificationCenter()
        model.followLifecycle(of: center)
        try await model.signIn(fixture.credentialsToSignIn)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await eventually("it connects again") { fixture.connects.count == 2 }

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        #expect(await stays(for: .milliseconds(300)) { fixture.connects.count == 2 })
    }

    @Test func anotherAppInFrontOnTheMacCountsAsLeavingTheApp() async throws {
        // Catalyst posts AppKit's notifications only, and the app went on
        // taking anything that arrived as seen: no banner on the Mac.
        let fixture = AppModelFixture()
        let model = fixture.model!
        let center = NotificationCenter()
        model.followLifecycle(of: center)
        try await model.signIn(fixture.credentialsToSignIn)
        #expect(model.isActive)

        center.post(name: Platform.appDidLoseFocus, object: nil)
        #expect(!model.isActive)
        #expect(fixture.lock.isLocked, "it isn't the background")

        center.post(name: Platform.appDidGainFocus, object: nil)
        #expect(model.isActive)
    }

    @Test func aNotificationIsShownForWhatTheUserCantSee() {
        let model = AppModelFixture().model!
        let front = JID("front@example.com")!
        let other = JID("other@example.com")!

        #expect(model.isActive)
        #expect(!model.showsNotification(for: other), "the list is in front, with every row")
        #expect(!model.showsNotification(for: nil))

        model.inFront = .chat(front)
        #expect(!model.showsNotification(for: front))
        #expect(model.showsNotification(for: other))
        #expect(model.showsNotification(for: nil), "an invitation is on the list, behind the chat")

        model.inFront = .chatList
        model.scenePhaseChanged(active: false, background: false)
        #expect(model.showsNotification(for: front))
        #expect(model.showsNotification(for: nil))
    }

    @Test func theArchiveOrASheetOverTheListHidesEveryChat() {
        let model = AppModelFixture().model!
        model.inFront = .elsewhere
        #expect(model.showsNotification(for: JID("other@example.com")!))
        #expect(model.showsNotification(for: nil))
        #expect(model.notificationScope.notifies)
        #expect(model.notificationScope.silencing == nil)
    }

    @Test func theExtensionsStandInIsHiddenWhileTheAppIsActive() {
        let model = AppModelFixture().model!
        model.inFront = .chat(JID("front@example.com")!)
        let other: [AnyHashable: Any] = [MessageNotification.peerKey: "other@example.com"]
        let invitation: [AnyHashable: Any] = [MessageNotification.invitationKey: "room@example.com"]
        let standIn: [AnyHashable: Any] = [MessageNotification.placeholderKey: true]

        #expect(model.showsNotification(userInfo: other))
        #expect(model.showsNotification(userInfo: invitation))
        #expect(!model.showsNotification(userInfo: standIn), "the app has those messages and notifies for them itself")
        #expect(!model.showsNotification(userInfo: [MessageNotification.peerKey: "front@example.com"]))

        model.scenePhaseChanged(active: false, background: false)
        #expect(model.showsNotification(userInfo: standIn))
    }

    @Test func aChatLeftOpenInTheBackgroundKeepsItsInterval() {
        let model = AppModelFixture().model!
        let front = JID("front@example.com")!
        #expect(!model.notificationScope.notifies, "the list shows everything")
        model.inFront = .chat(front)
        #expect(model.notificationScope.notifies)
        #expect(model.notificationScope.silencing == front)

        model.scenePhaseChanged(active: false, background: true)
        #expect(model.notificationScope.notifies)
        #expect(model.notificationScope.silencing == nil, "out of sight like every other chat")
    }

    @Test func aSignInThatFinishesInTheBackgroundSuspendsTheSession() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        model.scenePhaseChanged(active: false, background: true)

        try await model.signIn(fixture.credentialsToSignIn)

        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
    }

    @Test func aCallKeepsTheSessionConnectedInTheBackgroundUntilItEnds() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(model.session)
        let peer = JID("bob@example.org")!
        func call(_ phase: CallPhase) -> CallState {
            CallState(sid: "s", peer: peer, direction: .outgoing, phase: phase, isVideo: false, isCameraOn: false)
        }
        session.callState.send(call(.active))

        model.scenePhaseChanged(active: false, background: true)

        #expect(await stays(for: .milliseconds(500)) { fixture.lock.isLocked })
        session.callState.send(call(.ended(.completed)))
        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
    }

    // MARK: Launching in the background

    /// A silent push can launch the app without anyone looking at it. Holding
    /// the locks then makes a notification extension woken for a real message
    /// treat the app as running, and the app is about to be suspended.
    @Test func launchingInTheBackgroundDoesntConnectOrTakeEitherLock() async throws {
        let fixture = AppModelFixture()
        fixture.launchesInBackground = true
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())

        let error = await model.restoreSession(fixture.credentialsToSignIn)

        #expect(error == nil)
        #expect(model.session != nil)
        #expect(await stays(for: .milliseconds(400)) {
            fixture.connects.isEmpty && !fixture.lock.isLocked && !fixture.appLock.isLocked && !fixture.appIsRunning()
        })
        #expect(fixture.otherProcess.tryLock(), "an extension can run its own session")
        fixture.otherProcess.unlock()
        await eventually("the background task that covered the open is over") { fixture.openBackgroundTasks == 0 }
    }

    @Test func theFirstMoveToActiveAfterABackgroundLaunchConnects() async throws {
        let fixture = AppModelFixture()
        fixture.launchesInBackground = true
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())
        await model.restoreSession(fixture.credentialsToSignIn)
        #expect(fixture.connects.isEmpty)

        model.scenePhaseChanged(active: true, background: false)

        await eventually("it connects") { fixture.connects.count == 1 }
        #expect(fixture.lock.isLocked)
        #expect(fixture.appIsRunning())
    }

    @Test func launchingInTheForegroundStillConnectsAtOnce() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())

        await model.restoreSession(fixture.credentialsToSignIn)

        #expect(fixture.connects.count == 1)
        #expect(fixture.lock.isLocked)
    }

    // MARK: Silent pushes

    @Test func aSilentPushWhileActiveAnswersNoDataWithoutTouchingTheLocks() async throws {
        let fixture = AppModelFixture()
        fixture.pushResult = .newData
        let model = fixture.model!

        let result = await model.receivedBackgroundPush()

        #expect(result == .noData)
        #expect(fixture.pushCatchUps == 0)
        #expect(!fixture.lock.isLocked && !fixture.appLock.isLocked && !fixture.appIsRunning())
    }

    @Test func aSilentPushWhileTheAppHoldsTheConnectionAnswersNoData() async throws {
        let fixture = AppModelFixture()
        fixture.pushResult = .newData
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        model.scenePhaseChanged(active: false, background: false)

        #expect(await model.receivedBackgroundPush() == .noData)
        #expect(fixture.pushCatchUps == 0)
        #expect(fixture.lock.isLocked, "the connection is left alone")
    }

    @Test func aSilentPushInTheBackgroundCatchesUpAndLeavesNothingHeld() async throws {
        let fixture = AppModelFixture()
        fixture.launchesInBackground = true
        fixture.pushResult = .newData
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())

        let result = await model.receivedBackgroundPush()

        #expect(result == .newData)
        #expect(fixture.pushCatchUps == 1)
        #expect(!fixture.lock.isLocked && !fixture.appLock.isLocked && !fixture.appIsRunning())
        #expect(fixture.openBackgroundTasks == 0)
        #expect(fixture.backgroundTasks == ["Background push"])
    }

    /// A catch-up the test holds, until `release()`.
    @MainActor private final class HeldCatchUp {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    /// The model's own suspension, eight seconds after a background launch, cuts every database in the
    /// process off, among them the one a running push's catch-up is writing to.
    @Test func theModelsSuspensionLeavesTheDatabasesToARunningBackgroundPush() async throws {
        let fixture = AppModelFixture()
        fixture.launchesInBackground = true
        fixture.pushResult = .newData
        let held = HeldCatchUp()
        fixture.pushWork = { await held.wait() }
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())
        let push = Task { await model.receivedBackgroundPush() }
        await eventually("the catch-up to start") { fixture.pushCatchUps == 1 }
        await model.restoreSession(fixture.credentialsToSignIn)

        // Past the model's suspension delay and the close that follows.
        #expect(await stays(for: .milliseconds(600)) { fixture.databaseSuspensions == 0 }, "the databases were cut off mid-fetch")
        held.release()

        #expect(await push.value == .newData)
        #expect(fixture.databaseSuspensions == 1, "the push left the databases open past its end")
    }

    /// A push that ends while the background launch is still opening the account's database: the cut-off
    /// would interrupt its migration, and the restoration would fail and sign the user out.
    @Test func aPushThatEndsWhileTheSessionIsBeingRestoredLeavesTheCutOffUntilItIsOpen() async throws {
        let fixture = AppModelFixture()
        fixture.launchesInBackground = true
        let held = HeldCatchUp()
        fixture.pushWork = { await held.wait() }
        fixture.onRestoring = { held.release() }
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())
        let push = Task { await model.receivedBackgroundPush() }
        await eventually("the catch-up to start") { fixture.pushCatchUps == 1 }

        #expect(await model.restoreSession(fixture.credentialsToSignIn) == nil)
        _ = await push.value

        // The push's cut-off, then the model's own suspension; the fixture must outlive both.
        await eventually("the databases to be cut off twice") { fixture.databaseSuspensions >= 2 }
        #expect(fixture.suspendedOnceSignedIn.first == true, "the databases were cut off while the account was opening")
        if case .signedIn = model.phase {} else { Issue.record("the restoration failed") }
    }

    /// Cancelling is cooperative, so the task is kept until the catch-up has let go of its lock and database.
    @Test func aBackgroundPushsTaskOutlivesItsExpiryUntilTheCatchUpLetsGo() async throws {
        let fixture = AppModelFixture()
        fixture.launchesInBackground = true
        let held = HeldCatchUp()
        fixture.pushWork = { await held.wait() }
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())
        let push = Task { await model.receivedBackgroundPush() }
        await eventually("the catch-up to start") { fixture.pushCatchUps == 1 }

        let expire = try #require(fixture.pushExpiry)
        expire()

        #expect(await stays(for: .milliseconds(300)) { fixture.openBackgroundTasks == 1 && fixture.databaseSuspensions == 0 })
        held.release()
        _ = await push.value
        #expect(fixture.openBackgroundTasks == 0)
        #expect(fixture.databaseSuspensions == 1)
    }

    /// A catch-up that doesn't let go is cut off from its databases and the task ended, as iOS gives no more time.
    @Test func aBackgroundPushThatDoesntLetGoIsCutOffAfterTheGrace() async throws {
        let fixture = AppModelFixture(pushExpiryGrace: .milliseconds(200))
        fixture.launchesInBackground = true
        let held = HeldCatchUp()
        fixture.pushWork = { await held.wait() }
        let model = fixture.model!
        model.followLifecycle(of: NotificationCenter())
        let push = Task { await model.receivedBackgroundPush() }
        await eventually("the catch-up to start") { fixture.pushCatchUps == 1 }

        let expire = try #require(fixture.pushExpiry)
        expire()

        await eventually("the task to end") { fixture.openBackgroundTasks == 0 }
        #expect(fixture.databaseSuspensions == 1)
        held.release()
        _ = await push.value
    }

    // MARK: Leaving the app during sign-in

    /// A sign-in the app suspended in the background, its connection dropped.
    private func suspendedSignIn(_ fixture: AppModelFixture) async -> (Task<Void, Error>, XMPPSession) {
        fixture.accepts = false
        let model = fixture.model!
        let signIn = Task { try await model.signIn(fixture.credentialsToSignIn) }
        await eventually("the sign-in connects") { fixture.connects.count == 1 }
        let session = fixture.connects[0]
        session.state.send(.connecting)
        model.scenePhaseChanged(active: false, background: true)
        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
        session.state.send(.disconnected(error: nil))
        return (signIn, session)
    }

    @Test func aSignInSuspendedInTheBackgroundGoesThroughOnComingBack() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        let (signIn, _) = await suspendedSignIn(fixture)
        defer { signIn.cancel() }
        #expect(await stays(for: .milliseconds(300)) { model.session == nil })

        fixture.accepts = true
        model.scenePhaseChanged(active: true, background: false)

        try await signIn.value
        #expect(model.session != nil)
        #expect(fixture.connects.count == 2)
    }

    @Test func aSuspendedSignInThatTheServerRefusesOnComingBackFails() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        let (signIn, session) = await suspendedSignIn(fixture)
        defer { signIn.cancel() }

        model.scenePhaseChanged(active: true, background: false)
        await eventually("it connects again") { fixture.connects.count == 2 }
        session.state.send(.connecting)
        session.state.send(.failed("Wrong password"))

        let error = await #expect(throws: SignInError.self) { try await signIn.value }
        #expect(error?.message == "Wrong password")
        #expect(model.session == nil)
    }

    @Test func aDropAfterComingBackStillFailsTheSignIn() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        let (signIn, session) = await suspendedSignIn(fixture)
        defer { signIn.cancel() }

        model.scenePhaseChanged(active: true, background: false)
        await eventually("it connects again") { fixture.connects.count == 2 }
        session.state.send(.connecting)
        session.state.send(.disconnected(error: "Connection refused"))

        let error = await #expect(throws: SignInError.self) { try await signIn.value }
        #expect(error?.message == "Connection refused")
    }

    @Test func aDisconnectWhileActiveFailsTheSignIn() async throws {
        let fixture = AppModelFixture()
        fixture.accepts = false
        let model = fixture.model!
        let signIn = Task { try await model.signIn(fixture.credentialsToSignIn) }
        await eventually("the sign-in connects") { fixture.connects.count == 1 }

        fixture.connects[0].state.send(.connecting)
        // The state stream keeps only the latest value, and an attempt is
        // only an attempt once the sign-in has seen it.
        try await Task.sleep(for: .milliseconds(100))
        fixture.connects[0].state.send(.disconnected(error: nil))

        let error = await #expect(throws: SignInError.self) { try await signIn.value }
        #expect(error?.message == "Couldn't connect to the server.")
        #expect(!fixture.lock.isLocked)
    }

    @Test func cancellingASuspendedSignInEndsIt() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        let (signIn, _) = await suspendedSignIn(fixture)

        signIn.cancel()

        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(model.session == nil)
        #expect(!fixture.lock.isLocked)
    }
}
