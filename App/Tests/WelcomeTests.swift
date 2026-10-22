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
        #expect(try await offMain { try session.database.setting(.welcomeShown) } == nil)

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
}
