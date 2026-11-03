import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// When the Mac's menu commands act. They are off while a sheet is up, and
/// on the welcome screen, where no chat list is there to answer them.
@MainActor
struct MenuCommandTests {
    @Test func theCommandsActOnlyOnceSignedIn() {
        #expect(!AppModelFixture().model.acceptsMenuCommands)
    }

    @Test func aSheetOfTheChatListTurnsTheCommandsOff() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        try await model.finishWelcome()
        #expect(model.acceptsMenuCommands)

        model.conversationSheetAppeared()
        #expect(!model.acceptsMenuCommands)

        model.requestSheet(.compose)
        #expect(model.requestedSheet == nil)

        model.conversationSheetDisappeared()
        #expect(model.acceptsMenuCommands)
        model.requestSheet(.compose)
        #expect(model.requestedSheet == .compose)
    }

    @Test func theWelcomeScreenDropsARequestNoChatListWouldRead() async throws {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        #expect(model.showsWelcome)
        #expect(!model.acceptsMenuCommands)

        model.requestSheet(.settings)
        #expect(model.requestedSheet == nil)

        try await model.finishWelcome()
        model.requestSheet(.settings)
        #expect(model.requestedSheet == .settings)
    }
}
