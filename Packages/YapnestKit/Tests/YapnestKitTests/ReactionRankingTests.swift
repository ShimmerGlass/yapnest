import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct ReactionRankingTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func later(_ days: Double, from date: Date? = nil) -> Date {
        (date ?? start).addingTimeInterval(days * 86400)
    }

    @Test func emptyGivesTheDefaultsInOrder() {
        #expect(ReactionRanking().row(at: start) == ["👍", "❤️", "😂", "😮", "😢"])
    }

    @Test func aNewFavouriteRisesAfterAFewPicks() {
        var ranking = ReactionRanking()
        for _ in 0..<3 { ranking.record("🔥", at: start) }
        ranking.record("😂", at: start)
        #expect(ranking.row(at: start) == ["🔥", "😂", "👍", "❤️", "😮"])
    }

    @Test func oneStrayPickDoesNotPushADefaultOut() {
        var ranking = ReactionRanking()
        ranking.record("🔥", at: start)
        #expect(ranking.row(at: start) == ReactionRanking.defaults)
    }

    @Test func twoPicksCloseTogetherEnterTheRow() {
        var ranking = ReactionRanking()
        ranking.record("🔥", at: start)
        ranking.record("🔥", at: later(0.01))
        #expect(ranking.row(at: later(0.01)) == ["🔥", "👍", "❤️", "😂", "😮"])
    }

    @Test func aPickedDefaultRanksAboveUnpickedOnes() {
        var ranking = ReactionRanking()
        ranking.record("😢", at: start)
        #expect(ranking.row(at: start) == ["😢", "👍", "❤️", "😂", "😮"])
    }

    @Test func aFadedNonDefaultFallsBelowTheDefaults() {
        var ranking = ReactionRanking()
        for _ in 0..<3 { ranking.record("🔥", at: start) }
        #expect(ranking.row(at: start).first == "🔥")
        #expect(!ranking.row(at: later(14 * 3)).contains("🔥"))
        #expect(ranking.row(at: later(14 * 3)) == ReactionRanking.defaults)
    }

    @Test func anOldFavouriteFadesBelowARecentOne() {
        var ranking = ReactionRanking()
        for _ in 0..<5 { ranking.record("🔥", at: start) }
        for _ in 0..<3 { ranking.record("🎉", at: start) }
        #expect(ranking.row(at: start).prefix(2) == ["🔥", "🎉"])
        // Six weeks on, 🔥 is worth 5/8 and a fresh pick of 🎉 twice outweighs it.
        let weeks = later(42)
        ranking.record("🎉", at: weeks)
        ranking.record("🎉", at: weeks)
        #expect(ranking.row(at: weeks).first == "🎉")
        #expect(ranking.score(of: "🔥", at: weeks) < ranking.score(of: "🎉", at: weeks))
        #expect(!ranking.row(at: weeks).contains("🔥"))
    }

    @Test func aPickAddsOneAndHalvesEveryTwoWeeks() {
        var ranking = ReactionRanking()
        ranking.record("🔥", at: start)
        #expect(ranking.score(of: "🔥", at: start) == 1)
        #expect(abs(ranking.score(of: "🔥", at: later(14)) - 0.5) < 1e-9)
        ranking.record("🔥", at: later(14))
        #expect(abs(ranking.score(of: "🔥", at: later(14)) - 1.5) < 1e-9)
    }

    @Test func topsUpWithDefaultsWithoutDuplicates() {
        var ranking = ReactionRanking()
        ranking.record("😮", at: start)
        ranking.record("🙏", at: start)
        ranking.record("🙏", at: start)
        let row = ranking.row(at: start)
        #expect(row.count == 5)
        #expect(Set(row).count == 5)
        #expect(row == ["😮", "🙏", "👍", "❤️", "😂"])
    }

    @Test func tiesGoToTheMoreRecentThenTheDefaultOrder() {
        // All worth 2: the most recent pick first, then a default before a non-default.
        let ranking = ReactionRanking(entries: [
            "🔥": .init(score: 2, updated: start), "🎉": .init(score: 2, updated: later(1)),
            "👍": .init(score: 0.5, updated: start),
        ])
        #expect(ranking.row(at: later(1)).prefix(3) == ["🎉", "👍", "🔥"])
    }

    @Test func aFullPickerEmojiEntersTheRow() {
        var ranking = ReactionRanking()
        ranking.record("🪺", at: start)
        ranking.record("🪺", at: start)
        #expect(ranking.row(at: start).first == "🪺")
        #expect(ranking.row(at: start).count == 5)
    }

    @Test func forgottenEntriesArePruned() {
        var ranking = ReactionRanking()
        for _ in 0..<2 { ranking.record("🔥", at: start) }
        for _ in 0..<2 { ranking.record("🎉", at: later(14 * 12)) }
        #expect(ranking.entries["🔥"] == nil)
        #expect(ranking.row(at: later(14 * 12)).first == "🎉")
    }

    @Test func aFadedEntryNoLongerRanks() {
        let ranking = ReactionRanking(entries: ["🔥": .init(score: 1, updated: start)])
        #expect(ranking.row(at: later(14 * 12)) == ReactionRanking.defaults)
    }

    @Test func theCountIsCapped() {
        var ranking = ReactionRanking()
        for index in 0..<(ReactionRanking.capacity + 20) {
            ranking.record("e\(index)", at: later(Double(index) / 100))
        }
        #expect(ranking.entries.count == ReactionRanking.capacity)
        #expect(ranking.entries["e\(ReactionRanking.capacity + 19)"] != nil)
    }

    @Test func theStoredRankingSurvivesAReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        do {
            let database = try AppDatabase(DatabaseQueue(path: url.path))
            #expect(database.reactionRanking().row(at: start) == ReactionRanking.defaults)
            try database.recordReactionPick("🔥", at: start)
            try database.recordReactionPick("🔥", at: later(1))
        }
        let reopened = try AppDatabase(DatabaseQueue(path: url.path))
        #expect(reopened.reactionRanking().row(at: later(1)).first == "🔥")
        #expect(reopened.reactionRanking().score(of: "🔥", at: later(1)) > 1.9)
    }
}
