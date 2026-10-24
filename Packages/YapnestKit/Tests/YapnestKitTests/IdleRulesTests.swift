import Foundation
import Testing
@testable import YapnestKit

struct IdleRulesTests {
    @Test func awayAfterTenQuietMinutesOrOnceLocked() {
        #expect(!IdleRules.isAway(idle: 0, screenLocked: false))
        #expect(!IdleRules.isAway(idle: 10 * 60 - 1, screenLocked: false))
        #expect(IdleRules.isAway(idle: 10 * 60, screenLocked: false))
        #expect(IdleRules.isAway(idle: 0, screenLocked: true))
    }

    /// Looking more often while away is what makes coming back quick.
    @Test func looksMoreOftenWhileAway() {
        #expect(IdleRules.interval(away: true) < IdleRules.interval(away: false))
    }
}
