import Testing
import YapnestKit
@testable import Yapnest

/// When the glow over the list plays: for a message from the contact that
/// arrives while the chat is in front of the user, and for nothing else.
@MainActor
struct ConversationPulseTests {
    private func opened(count: Int = 10, onScreen: Bool = true) async throws -> ConversationFixture {
        let f = try ConversationFixture()
        try f.addMany(count)
        await f.start()
        if onScreen { f.model.setOnScreen(true) }
        return f
    }

    @Test func aMessageFromTheContactPulsesOnce() async throws {
        let f = try await opened()
        #expect(f.model.receivedPulse == 0)
        let incoming = try f.add("hi")
        await eventually("the message never showed") { f.rowIDs.last == incoming.id }
        #expect(f.model.receivedPulse == 1)
    }

    @Test func openingTheChatDoesNotPulse() async throws {
        let f = try await opened()
        #expect(await stays { f.model.receivedPulse == 0 })
    }

    @Test func ownMessagesAndTheirCopiesFromOtherDevicesDoNotPulse() async throws {
        let f = try await opened()
        let sent = try f.add("hello", .outgoing, status: .pending)
        await eventually("the send never showed") { f.rowIDs.last == sent.id }
        let copy = try f.add("from my other device", .outgoing)
        await eventually("the copy never showed") { f.rowIDs.last == copy.id }
        #expect(f.model.receivedPulse == 0)
    }

    @Test func olderMessagesPagingInDoNotPulse() async throws {
        let f = try ConversationFixture()
        try f.addMany(700)
        await f.start()
        f.model.setOnScreen(true)
        f.model.nearTopChanged(true)
        await eventually("older messages never loaded") { f.model.rows.count == 700 }
        #expect(f.model.receivedPulse == 0)
    }

    @Test func editsReactionsAndRetractionsDoNotPulse() async throws {
        let f = try await opened()
        let theirs = try f.add("original", remoteId: "r1")
        await eventually("the message never showed") { f.rowIDs.last == theirs.id }
        let before = f.model.receivedPulse

        _ = try f.database.applyEdit("fixed", to: theirs.id!)
        await eventually("the edit never applied") { f.model.rows.last?.message.body == "fixed" }
        _ = try f.database.setReactions(["👍"], from: f.peer, conversationId: f.conversation.id!, messageRef: "r1")
        _ = try f.database.applyRetraction(of: theirs.id!)
        #expect(await stays { f.model.receivedPulse == before })
    }

    @Test func aBurstPulsesOnce() async throws {
        let f = try await opened()
        var last: Message?
        for index in 0..<3 {
            last = try f.add("burst \(index)")
            let id = last!.id
            await eventually("the message never showed") { f.rowIDs.last == id }
        }
        #expect(f.model.receivedPulse == 1)
    }

    @Test func aMessageAfterTheWindowPulsesAgain() async throws {
        let f = try await opened()
        let first = try f.add("one")
        await eventually("the message never showed") { f.rowIDs.last == first.id }
        try await Task.sleep(for: ConversationModel.pulseWindow + .milliseconds(100))
        let second = try f.add("two")
        await eventually("the message never showed") { f.rowIDs.last == second.id }
        #expect(f.model.receivedPulse == 2)
    }

    @Test func aChatNotOnScreenDoesNotPulse() async throws {
        let f = try await opened(onScreen: false)
        let incoming = try f.add("hi")
        await eventually("the message never showed") { f.rowIDs.last == incoming.id }
        #expect(f.model.receivedPulse == 0)
    }
}
