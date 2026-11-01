import Foundation
import SwiftUI
import Testing
@testable import Yapnest

/// Settings are written off the main thread; two changes made quickly must
/// still land in the order the user made them.
@MainActor
struct SettingsWritesTests {
    @Test func aSlowWriteIsNotOvertakenByTheNextOne() async {
        let writes = SettingsWrites()
        let log = Log()
        writes.run({ Thread.sleep(forTimeInterval: 0.3); log.add("first") }, onFailure: { _ in })
        await confirmation { done in
            await withCheckedContinuation { finished in
                writes.run({ log.add("second") }, onSuccess: { _ in
                    done()
                    finished.resume()
                }, onFailure: { _ in })
            }
        }
        #expect(log.entries == ["first", "second"])
    }

    @Test func aFailedWritePutsTheControlBack() async {
        let writes = SettingsWrites()
        var value = false
        let binding = Binding(get: { value }, set: { value = $0 })
        await withCheckedContinuation { finished in
            writes.setOptimistically(binding, key: "x", to: true, { throw CocoaError(.fileWriteUnknown) }, onFailure: { _ in finished.resume() })
            #expect(value)
        }
        #expect(!value)
    }

    // Going back to what the first write replaced would show a value the
    // second, which follows and succeeds, never stored.
    @Test func aFailedWriteLeavesALaterChangeShown() async {
        let writes = SettingsWrites()
        var value = 0
        let binding = Binding(get: { value }, set: { value = $0 })
        await withCheckedContinuation { finished in
            writes.setOptimistically(binding, key: "x", to: 1, { Thread.sleep(forTimeInterval: 0.2); throw CocoaError(.fileWriteUnknown) }, onFailure: { _ in })
            writes.setOptimistically(binding, key: "x", to: 2, {}, onFailure: { _ in })
            writes.run({}, onSuccess: { _ in finished.resume() }, onFailure: { _ in finished.resume() })
        }
        #expect(value == 2)
    }

    // The control was moved away and back to the value the failed write
    // set: it equals that value, yet a later write holds it too.
    @Test func aFailedWriteLeavesAControlMovedAwayAndBackWhereItIs() async {
        let writes = SettingsWrites()
        var value = 0
        let binding = Binding(get: { value }, set: { value = $0 })
        await withCheckedContinuation { finished in
            writes.setOptimistically(binding, key: "x", to: 1, { Thread.sleep(forTimeInterval: 0.2); throw CocoaError(.fileWriteUnknown) }, onFailure: { _ in })
            writes.setOptimistically(binding, key: "x", to: 0, {}, onFailure: { _ in })
            writes.setOptimistically(binding, key: "x", to: 1, {}, onFailure: { _ in })
            writes.run({}, onSuccess: { _ in finished.resume() }, onFailure: { _ in finished.resume() })
        }
        #expect(value == 1)
    }

    @Test func aFailedWriteStillRevertsWhenAnotherControlWasWrittenAfterIt() async {
        let writes = SettingsWrites()
        var first = false, second = false
        let one = Binding(get: { first }, set: { first = $0 })
        let two = Binding(get: { second }, set: { second = $0 })
        await withCheckedContinuation { finished in
            writes.setOptimistically(one, key: "one", to: true, { throw CocoaError(.fileWriteUnknown) }, onFailure: { _ in })
            writes.setOptimistically(two, key: "two", to: true, {}, onFailure: { _ in })
            writes.run({}, onSuccess: { _ in finished.resume() }, onFailure: { _ in finished.resume() })
        }
        #expect(!first)
        #expect(second)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var entries: [String] { lock.withLock { items } }
    }
}
