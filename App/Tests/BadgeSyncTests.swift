import Testing
@testable import Yapnest

struct BadgeSyncTests {
    @Test func aCountIsSetOnceUntilItChangesOrIsForgotten() {
        let sync = BadgeSync()
        #expect(sync.shouldSet(2))
        #expect(!sync.shouldSet(2))
        #expect(sync.shouldSet(0))
        #expect(!sync.shouldSet(0))

        sync.forget()

        #expect(sync.shouldSet(0))
    }
}
