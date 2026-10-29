import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

/// A chat opened from the list starts loading on the tap, and on the iPhone
/// is pushed once its first messages are in: started once the screen was
/// there, they arrived 100 to 160 ms into its slide and popped in partway.
@MainActor
struct PreparedChatsTests {
    @Test func aChatStartedFromATapLoadsBeforeItIsShown() async throws {
        let f = try ConversationFixture()
        try f.addMany(10, read: true)
        f.model.prepare(previews: nil)
        await f.model.waitUntilLoaded(atMost: .seconds(5))
        #expect(f.model.hasLoaded)
        #expect(f.rowIDs.count == 10)
    }

    @Test func waitingForTheFirstMessagesGivesUpAfterItsLimit() async throws {
        let f = try ConversationFixture()
        let started = ContinuousClock.now
        // Never started, so it never loads.
        await f.model.waitUntilLoaded(atMost: .milliseconds(100))
        #expect(!f.model.hasLoaded)
        #expect(ContinuousClock.now - started < .milliseconds(400))
    }

    /// The opening scroll has a limited number of tries, a frame apart, to
    /// land on the first unread message. Spent before the push, they would
    /// run out with no list to scroll, and it would be shown wherever it is.
    @Test func aChatStartedBeforeItsScreenKeepsItsOpeningTriesForTheList() async throws {
        let f = try ConversationFixture()
        try f.addMany(10, read: true)
        try (0..<6).forEach { _ = try f.add("new \($0)") }
        f.model.prepare(previews: nil)
        await f.model.waitUntilLoaded(atMost: .seconds(5))
        // Longer than all the tries take.
        try await Task.sleep(for: .milliseconds(800))
        #expect(!f.model.isPositioned)

        f.model.setOnScreen(true)
        f.model.geometryChanged(geometry(distanceFromBottom: 900))
        await eventually("the list was never shown") { f.model.isPositioned }
    }

    @Test func theScreenTakesOnlyItsOwnChatAndOnlyOnce() throws {
        let f = try ConversationFixture()
        let prepared = PreparedChats()
        var shown = 0
        prepared.open(session: f.session, peer: f.peer, openingAt: nil, initial: nil, previews: nil, waits: false) { shown += 1 }
        #expect(shown == 1)
        #expect(prepared.take(peer: JID("other@example.com")!, openingAt: nil) == nil)
        #expect(prepared.take(peer: f.peer, openingAt: 42) == nil)
        #expect(prepared.take(peer: f.peer, openingAt: nil) != nil)
        #expect(prepared.take(peer: f.peer, openingAt: nil) == nil)
    }

    @Test func thePushWaitsForTheFirstMessages() async throws {
        let f = try ConversationFixture()
        try f.addMany(10, read: true)
        let prepared = PreparedChats()
        var loadedWhenShown: Bool?
        prepared.open(session: f.session, peer: f.peer, openingAt: nil, initial: nil, previews: nil, waits: true) {
            loadedWhenShown = prepared.take(peer: f.peer, openingAt: nil)?.conversation.hasLoaded
        }
        #expect(loadedWhenShown == nil)
        await eventually("the chat was never shown") { loadedWhenShown != nil }
        #expect(loadedWhenShown == true)
    }

    @Test func aChatOpenedAnotherWayDropsOneStillWaiting() async throws {
        let f = try ConversationFixture()
        let prepared = PreparedChats()
        var shown = false
        prepared.open(session: f.session, peer: f.peer, openingAt: nil, initial: nil, previews: nil, waits: true) { shown = true }
        prepared.clear()
        try await Task.sleep(for: PreparedChats.pushWait + .milliseconds(100))
        #expect(!shown)
        #expect(prepared.take(peer: f.peer, openingAt: nil) == nil)
    }
}
