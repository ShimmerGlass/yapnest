import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// Resetting the encryption device: what it refuses, and what it leaves open.
@MainActor
struct AppModelEncryptionResetTests {
    private func signedIn() async throws -> (AppModelFixture, XMPPSession) {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        return (fixture, try #require(fixture.model.session))
    }

    @Test func theLockIsStillHeldWhenTheDeviceIsSwapped() async throws {
        let (fixture, _) = try await signedIn()

        await fixture.model.replaceEncryptionDevice()

        #expect(fixture.lockHeldDuringReplacement == [true], "an extension taking it would run as the old device")
    }

    @Test func aResetMakesANewDeviceAndOpensTheAccountAgain() async throws {
        let (fixture, old) = try await signedIn()
        let oldFingerprint = try #require(old.ownFingerprint)

        await fixture.model.replaceEncryptionDevice()

        let new = try #require(fixture.model.session)
        #expect(new !== old)
        #expect(new.ownFingerprint != oldFingerprint)
        #expect(fixture.model.encryptionDeviceProblem == nil)
        #expect(fixture.lock.isLocked)
    }

    @Test func aResetThatCantOpenTheAccountAgainSaysSo() async throws {
        let (fixture, _) = try await signedIn()
        try Data().write(to: fixture.root.appending(path: "blocker"))
        fixture.accountCantBeOpened = true

        await fixture.model.replaceEncryptionDevice()

        #expect(fixture.model.session == nil)
        #expect(fixture.model.encryptionDeviceProblem?.contains("couldn't be opened again") == true)
    }

    @Test func aFailedReplacementAndAnAccountThatCantBeOpenedAreBothShown() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "The server said no" } }
        let (fixture, _) = try await signedIn()
        try Data().write(to: fixture.root.appending(path: "blocker"))
        fixture.accountCantBeOpened = true
        fixture.replacementError = Refused()

        await fixture.model.replaceEncryptionDevice()

        #expect(fixture.model.session == nil)
        let problem = try #require(fixture.model.encryptionDeviceProblem)
        #expect(problem.contains("The server said no"))
        #expect(problem.contains("couldn't be opened again"))
    }

    @Test func aResetWithoutTheProcessLockIsRefused() async throws {
        let (fixture, session) = try await signedIn()
        let fingerprint = session.ownFingerprint
        // Still waiting for an extension to let go.
        fixture.lock.unlock()

        let refusal = await fixture.model.replaceEncryptionDevice()

        #expect(refusal != nil)
        #expect(fixture.lockHeldDuringReplacement.isEmpty)
        #expect(fixture.model.session === session)
        #expect(session.ownFingerprint == fingerprint)
    }

    // The root's alert waits under the Settings sheet the button is in, so a
    // refusal made while everything is still open goes back to the screen.
    @Test func aRefusalIsReturnedToTheScreenThatAskedNotRaisedAtTheRoot() async throws {
        let (fixture, _) = try await signedIn()
        fixture.lock.unlock()

        let refusal = await fixture.model.replaceEncryptionDevice()

        #expect(refusal != nil)
        #expect(fixture.model.encryptionDeviceProblem == nil)
    }

    @Test func anAccountTheKeychainDoesNotHoldIsNotReset() async throws {
        let (fixture, session) = try await signedIn()
        try fixture.credentials.delete()

        let refusal = await fixture.model.replaceEncryptionDevice()

        #expect(refusal != nil)
        #expect(fixture.lockHeldDuringReplacement.isEmpty)
        #expect(fixture.model.session === session)
    }

    @Test func aRingingCallIsNotHungUpByAReset() async throws {
        let (fixture, session) = try await signedIn()
        let peer = JID("bob@example.org")!
        session.callState.send(CallState(sid: "s", peer: peer, direction: .incoming, phase: .incoming, isVideo: false, isCameraOn: false))

        let refusal = await fixture.model.replaceEncryptionDevice()

        #expect(refusal != nil)
        #expect(fixture.lockHeldDuringReplacement.isEmpty)
        #expect(fixture.model.session === session)
    }

    @Test func aCallBeingPreparedIsNotCutByAReset() async throws {
        let (fixture, session) = try await signedIn()
        let release = AsyncStream<Void>.makeStream()
        fixture.model.calls.prepareCall = { _, _, _ in for await _ in release.stream { return } }
        fixture.model.calls.systemAudio = (activate: { _ in }, deactivate: {})
        fixture.model.calls.startCall(to: JID("bob@example.org")!)

        let refusal = await fixture.model.replaceEncryptionDevice()
        release.continuation.finish()

        #expect(refusal != nil)
        #expect(fixture.model.session === session)
    }

    @Test func theAppAsksForTimeToFinishAResetAfterLeavingTheScreen() async throws {
        let (fixture, _) = try await signedIn()

        await fixture.model.replaceEncryptionDevice()

        #expect(fixture.backgroundTasks == ["Reset encryption"])
        #expect(fixture.openBackgroundTasks == 0, "the time is given back when the reset ends")
    }

    @Test func aRefusedResetDoesNotHoldBackgroundTime() async throws {
        let (fixture, _) = try await signedIn()
        fixture.lock.unlock()

        await fixture.model.replaceEncryptionDevice()

        #expect(fixture.backgroundTasks.isEmpty)
    }
}
