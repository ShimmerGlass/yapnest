import Foundation
import Synchronization
import Testing
@testable import Yapnest

struct DecodeOffMainTests {
    @Test func aDecodeQueuedForAViewThatHasGoneNeverRuns() async {
        let ran = Atomic<Int>(0)
        // Cancelled before it asks, as a row's task is once it has scrolled away.
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await decodeOffMain { () -> Int? in
                ran.add(1, ordering: .relaxed)
                return 1
            }
        }
        #expect(await waiting.value == nil)
        #expect(ran.load(ordering: .relaxed) == 0)
    }

    @Test func aDecodeStillWantedReturnsItsPicture() async {
        #expect(await decodeOffMain { 42 } == 42)
    }
}
