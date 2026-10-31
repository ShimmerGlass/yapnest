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
            writes.setOptimistically(binding, to: true, { throw CocoaError(.fileWriteUnknown) }, onFailure: { _ in finished.resume() })
            #expect(value)
        }
        #expect(!value)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var entries: [String] { lock.withLock { items } }
    }
}
