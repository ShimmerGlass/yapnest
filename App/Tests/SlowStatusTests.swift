import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// Loading the saved account and catching up once connected take a moment on
/// every launch, so their spinners wait until they've gone on a while.
@MainActor
struct SlowStatusTests {
    @Test func aCatchUpIsShownOnlyOnceItHasGoneOnAWhile() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(model.session)

        session.state.send(.connected(isSyncing: true))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.connection == .connected(isSyncing: true))
        #expect(!model.catchUpIsSlow)

        try await Task.sleep(for: .milliseconds(300))
        #expect(model.catchUpIsSlow)

        session.state.send(.connected(isSyncing: false))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.catchUpIsSlow)
    }

    @Test func aCatchUpDoneInAMomentIsNeverShown() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        let session = try #require(model.session)

        session.state.send(.connected(isSyncing: true))
        try await Task.sleep(for: .milliseconds(30))
        session.state.send(.connected(isSyncing: false))
        try await Task.sleep(for: .milliseconds(300))

        #expect(!model.catchUpIsSlow)
    }

    @Test func aLaunchThatLoadsTheAccountInAMomentShowsNoSpinner() async throws {
        let fixture = AppModelFixture()
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        fixture.relaunch()

        fixture.model.start()
        try await Task.sleep(for: .milliseconds(300))

        #expect(fixture.model.session != nil)
        #expect(!fixture.model.loadingIsSlow)
    }
}
