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
        session.presences.send([peer: .away])
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
        #expect(fixture.otherProcess.tryLock(as: .share))
        let model = fixture.model!
        let signIn = Task { try await model.signIn(fixture.credentialsToSignIn) }
        defer { signIn.cancel() }

        #expect(await stays(for: .milliseconds(600)) { fixture.connects.isEmpty })
        fixture.otherProcess.unlock()

        await eventually("the sign-in goes through") { model.session != nil }
        #expect(fixture.connects.count == 1)
        #expect(fixture.lock.isLocked)
    }

    @Test func comingBackConnectsOnlyOnceTheLockIsFree() async throws {
        let fixture = AppModelFixture(lockTimeout: 0.1)
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        model.scenePhaseChanged(active: false, background: true)
        await eventually("the session lets go of the lock") { !fixture.lock.isLocked }
        #expect(fixture.otherProcess.tryLock(as: .notification))

        model.scenePhaseChanged(active: true, background: false)
        #expect(await stays(for: .milliseconds(500)) { fixture.connects.count == 1 })
        fixture.otherProcess.unlock()

        await eventually("it connects again") { fixture.connects.count == 2 }
        #expect(fixture.lock.isLocked)
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
