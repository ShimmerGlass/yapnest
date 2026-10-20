import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// Changing the password: the keychain the extensions read, and the FAST tokens.
@MainActor
struct AppModelPasswordTests {
    private func signedIn(_ fixture: AppModelFixture) async throws {
        try await fixture.model.signIn(fixture.credentialsToSignIn)
    }

    @Test func aChangeStoresTheNewPasswordAndDropsEveryToken() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)
        // Sign-in stored "x" with the rest of what it connected with.
        try fixture.credentials.save(.init(jid: fixture.account, password: "x", host: "h.example", port: 5223, disableTLS: true))

        try await fixture.model.changePassword(current: "x", new: "fresh")

        #expect(fixture.passwordChanges.map(\.new) == ["fresh"])
        #expect(fixture.passwordChanges.map(\.current) == ["x"])
        let stored = try #require(try fixture.credentials.load())
        #expect(stored.password == "fresh")
        #expect(stored.host == "h.example" && stored.port == 5223 && stored.disableTLS)
        #expect(fixture.fastTokenWipes == 1)
    }

    @Test func aMatchingKeychainNeedsNoVerification() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)

        try await fixture.model.changePassword(current: "x", new: "fresh")

        #expect(fixture.passwordVerifications.isEmpty)
    }

    @Test func aStaleKeychainDefersToTheServerWhichKnowsTheTypedPassword() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)
        fixture.acceptedPasswords = ["changed-elsewhere"]

        try await fixture.model.changePassword(current: "changed-elsewhere", new: "fresh")

        #expect(fixture.passwordVerifications == ["changed-elsewhere"])
        #expect(fixture.passwordChanges.map(\.new) == ["fresh"])
        #expect(fixture.passwordChanges.map(\.current) == ["changed-elsewhere"])
        #expect(try fixture.credentials.load()?.password == "fresh")
        #expect(fixture.fastTokenWipes == 1)
    }

    @Test func aStaleKeychainAndAServerThatRefusesTheTypedPasswordIsWrong() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)

        await #expect(throws: XMPPSession.PasswordError.wrongCurrentPassword) {
            try await fixture.model.changePassword(current: "nope", new: "fresh")
        }

        #expect(fixture.passwordVerifications == ["nope"])
        #expect(fixture.passwordChanges.isEmpty)
        #expect(try fixture.credentials.load()?.password == "x")
        #expect(fixture.fastTokenWipes == 0)
    }

    @Test func aVerificationThatCantReachTheServerIsNotAWrongPassword() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)
        fixture.passwordVerificationError = XMPPSession.PasswordError.offline

        await #expect(throws: XMPPSession.PasswordError.offline) {
            try await fixture.model.changePassword(current: "maybe", new: "fresh")
        }

        #expect(fixture.passwordChanges.isEmpty)
        #expect(try fixture.credentials.load()?.password == "x")
        #expect(fixture.fastTokenWipes == 0)
    }

    @Test func aWrongCurrentPasswordIsRefusedWithoutChangingAnything() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)

        await #expect(throws: XMPPSession.PasswordError.wrongCurrentPassword) {
            try await fixture.model.changePassword(current: "nope", new: "fresh")
        }

        #expect(fixture.passwordChanges.isEmpty)
        #expect(try fixture.credentials.load()?.password == "x")
        #expect(fixture.fastTokenWipes == 0)
    }

    @Test func aRefusingServerLeavesTheKeychainAndTokensAlone() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)
        fixture.passwordChangeError = XMPPSession.PasswordError.notAcceptable(reason: nil)

        await #expect(throws: XMPPSession.PasswordError.notAcceptable(reason: nil)) {
            try await fixture.model.changePassword(current: "x", new: "fresh")
        }

        #expect(try fixture.credentials.load()?.password == "x")
        #expect(fixture.fastTokenWipes == 0)
    }

    @Test func aKeychainThatCantSaveAfterTheServerChangedItSaysSo() async throws {
        let fixture = AppModelFixture()
        try await signedIn(fixture)
        fixture.credentials.refusesToSave = true

        await #expect(throws: XMPPSession.PasswordError.changedButNotSaved) {
            try await fixture.model.changePassword(current: "x", new: "fresh")
        }

        #expect(fixture.passwordChanges.map(\.new) == ["fresh"])
        // The old token is useless either way.
        #expect(fixture.fastTokenWipes == 1)
    }

    @Test func signedOutThereIsNothingToChange() async {
        let fixture = AppModelFixture()
        await #expect(throws: XMPPSession.PasswordError.offline) {
            try await fixture.model.changePassword(current: "x", new: "fresh")
        }
    }
}
