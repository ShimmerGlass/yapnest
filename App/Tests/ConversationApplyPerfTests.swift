import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// Not an assertion: prints what `apply` costs the main actor for one incoming
/// message in a long chat, to compare before and after a change to it.
@MainActor
struct ConversationApplyPerfTests {
    @Test func applyingOneIncomingMessageInAThousand() async throws {
        let f = try ConversationFixture()
        try f.addMany(1100, read: true)
        await f.start()
        while f.model.rows.count < 1100 {
            let before = f.model.rows.count
            f.model.nearTopChanged(false)
            f.model.nearTopChanged(true)
            await eventually("older messages never loaded") { f.model.rows.count > before }
        }
        let rounds = 20
        var total = Duration.zero
        for round in 1...rounds {
            try f.add("incoming \(round)", .incoming, read: true)
            await eventually("the message never showed") { f.model.rows.last?.message.body == "incoming \(round)" }
            total += f.model.lastApplyDuration
        }
        print("PERF apply of one incoming message in a chat of 1,100: \(total / rounds) on average")
    }
}
