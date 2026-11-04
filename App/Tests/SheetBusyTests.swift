import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// A chat list sheet that waits on the server isn't replaced meanwhile, and
/// a late answer doesn't close another sheet.
@MainActor
struct SheetBusyTests {
    private let chat = JID("a@example.com")!
    private let link = XMPPURI("xmpp:room@conference.example.com?join")!

    private func signedIn() async throws -> AppModel {
        let fixture = AppModelFixture()
        let model = fixture.model!
        try await model.signIn(fixture.credentialsToSignIn)
        try await model.finishWelcome()
        return model
    }

    @Test func aNotificationWaitsForABusySheet() async throws {
        let model = try await signedIn()
        model.requestedConversation = chat
        model.sheetIsBusy = true
        #expect(model.takeRequestedConversation() == nil)
        #expect(model.requestedConversation == chat)

        model.sheetIsBusy = false
        #expect(model.takeRequestedConversation() == chat)
        #expect(model.requestedConversation == nil)
    }

    @Test func aLinkAndTheChatListRequestWaitForABusySheet() async throws {
        let model = try await signedIn()
        model.pendingLink = link
        model.requestsChatList = true
        model.sheetIsBusy = true
        #expect(model.takePendingLink() == nil)
        #expect(!model.takeRequestsChatList())

        model.sheetIsBusy = false
        #expect(model.takePendingLink() == link)
        #expect(model.takeRequestsChatList())
        #expect(model.pendingLink == nil && !model.requestsChatList)
    }

    @Test func aLateAnswerClosesOnlyItsOwnSheet() {
        var current: ChatListSheet? = .joinGroup
        #expect(!ChatListSheet.close(&current, ifShowing: .newGroup))
        #expect(current == .joinGroup)

        current = nil
        #expect(!ChatListSheet.close(&current, ifShowing: .joinGroup))

        current = .joinGroup
        #expect(ChatListSheet.close(&current, ifShowing: .joinGroup))
        #expect(current == nil)
    }
}
