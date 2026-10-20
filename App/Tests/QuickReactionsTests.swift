import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// The menu's row of quick reactions learns from what is picked.
@MainActor
struct QuickReactionsTests {
    private func opened() async throws -> (ConversationFixture, Int64) {
        let f = try ConversationFixture()
        let message = try f.add("hello", remoteId: "m1")
        await f.start()
        await eventually("the row never showed") { f.rowIDs.contains(message.id!) }
        return (f, message.id!)
    }

    private func picks(_ f: ConversationFixture, _ emoji: String) -> Double {
        f.database.reactionRanking().score(of: emoji, at: Date())
    }

    @Test func aSingleStrayPickLeavesTheRowAlone() async throws {
        let (f, id) = try await opened()
        f.model.react("🪺", to: id)
        await eventually("the pick was never counted") { picks(f, "🪺") > 0.9 }
        #expect(await stays { f.model.quickReactions == ReactionRanking.defaults })
    }

    @Test func startsWithTheDefaults() async throws {
        let (f, _) = try await opened()
        #expect(f.model.quickReactions == ReactionRanking.defaults)
    }

    @Test func aPickFromTheFullPickerEntersTheNextMenu() async throws {
        let (f, id) = try await opened()
        // One pick alone doesn't displace a default; the second does.
        try f.database.recordEmojiPick("🪺")
        f.model.react("🪺", to: id)
        await eventually("the pick never showed in the row") { f.model.quickReactions.first == "🪺" }
        #expect(f.model.quickReactions == ["🪺", "👍", "❤️", "😂", "😮"])
    }

    @Test func takingAReactionBackIsNotAPick() async throws {
        let (f, id) = try await opened()
        f.model.react("🔥", to: id)
        await eventually("the pick was never counted") { picks(f, "🔥") > 0.9 }
        await eventually("the reaction never showed on the message") { f.model.rows.first { $0.id == id }?.item.reactions.contains { $0.includesMe } == true }
        f.model.react("🔥", to: id)
        await eventually("the reaction was never taken back") { f.model.rows.first { $0.id == id }?.item.reactions.isEmpty == true }
        #expect(await stays { picks(f, "🔥") < 1.1 })
    }

    @Test func theRowIsReadOncePerMenuAndDoesNotShiftUnderneathIt() async throws {
        let (f, _) = try await opened()
        let before = f.model.quickReactions
        // Something else counts picks, as another open chat would: the row
        // shown by this chat's menu stays until a pick made here.
        try f.database.recordEmojiPick("🔥")
        try f.database.recordEmojiPick("🔥")
        #expect(await stays { f.model.quickReactions == before })
    }

    @Test func theRankingIsLoadedWhenTheChatIsOpenedAgain() async throws {
        let (f, id) = try await opened()
        try f.database.recordEmojiPick("🪺")
        f.model.react("🪺", to: id)
        await eventually("the pick was never counted") { picks(f, "🪺") > 1.9 }
        f.reopen()
        await f.start()
        await eventually("the learned row never loaded") { f.model.quickReactions.first == "🪺" }
    }
}
