import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// The welcome screen that asks for the privacy settings: shown by the first
/// sign-in, answered once.
@MainActor
struct WelcomeTests {
    @Test func theFirstSignInAsksButNothingElseDoes() async throws {
        let fixture = AppModelFixture()
        #expect(!fixture.model.showsWelcome)

        try await fixture.model.signIn(fixture.credentialsToSignIn)

        #expect(fixture.model.showsWelcome)
    }

    @Test func continuingClosesItAndRecordsThatItWasAnswered() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(model.session)
        #expect(try await offMain { try session.database.setting(.welcomeShown) } == "pending")

        try await model.finishWelcome()

        #expect(!model.showsWelcome)
        #expect(try await offMain { try session.database.setting(.welcomeShown) } == "1")
    }

    @Test func signingOutClosesIt() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)

        model.signOut()

        #expect(!model.showsWelcome)
    }

    @Test func aLaunchBeforeContinueAsksAgain() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)

        fixture.relaunch()
        #expect(!fixture.model.showsWelcome)
        await fixture.model.restoreSession(fixture.credentialsToSignIn)

        #expect(fixture.model.showsWelcome)
    }

    @Test func signingInAgainOverAQuestionNeverAnsweredAsksAgain() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)

        // The restore failed, so the user signed in again without signing out.
        fixture.relaunch()
        try await fixture.model.signIn(fixture.credentialsToSignIn)

        #expect(fixture.model.showsWelcome)
    }

    @Test func aLaunchAfterContinueDoesNotAsk() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        try await fixture.model.finishWelcome()

        fixture.relaunch()
        await fixture.model.restoreSession(fixture.credentialsToSignIn)

        #expect(fixture.model.session != nil)
        #expect(!fixture.model.showsWelcome)
    }

    @Test func anInstallFromBeforeTheWelcomeIsNotAsked() async throws {
        let fixture = AppModelFixture()

        await fixture.model.restoreSession(fixture.credentialsToSignIn)

        let session = try #require(fixture.model.session)
        #expect(try await offMain { try session.database.setting(.welcomeShown) } == nil)
        #expect(!fixture.model.showsWelcome)
    }
}
