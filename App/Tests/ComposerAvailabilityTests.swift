import Testing
@testable import Yapnest

struct ComposerAvailabilityTests {
    // A drop on the list or a paste reaches the composer even when the bottom
    // bar shows "Join Again" in its place; what it stages is never seen.
    @Test func aRoomThatFailedToBeJoinedTakesTheComposerAwayLikeALeftOneDoes() {
        #expect(ConversationView.showsComposer(hasLeftGroup: false, hasBlockedContact: false, roomFailed: false))
        #expect(!ConversationView.showsComposer(hasLeftGroup: false, hasBlockedContact: false, roomFailed: true))
        #expect(!ConversationView.showsComposer(hasLeftGroup: true, hasBlockedContact: false, roomFailed: false))
        #expect(!ConversationView.showsComposer(hasLeftGroup: false, hasBlockedContact: true, roomFailed: false))
    }
}
