import Foundation
import Testing
@testable import Yapnest

@MainActor
struct ServerActionTests {
    private struct Failure: Error {}

    private func settle(_ action: ServerAction) async {
        while action.isBusy { await Task.yield() }
    }

    @Test func tagNamesTheControlThatIsBusy() async {
        let action = ServerAction()
        var release: CheckedContinuation<Void, Never>?
        action.run(tag: "avatar") { await withCheckedContinuation { release = $0 } }
        while release == nil { await Task.yield() }

        #expect(action.isBusy("avatar"))
        #expect(!action.isBusy("name"))
        #expect(!action.isBusy(7))

        release?.resume()
        await settle(action)
        #expect(!action.isBusy("avatar"))
    }

    @Test func retryKeepsTheTag() async {
        let action = ServerAction()
        var runs = 0
        var release: CheckedContinuation<Void, Never>?
        action.run(tag: "name") {
            runs += 1
            if runs == 1 { throw Failure() }
            await withCheckedContinuation { release = $0 }
        }
        await settle(action)
        #expect(action.error != nil)

        action.retry()
        while release == nil { await Task.yield() }
        #expect(action.isBusy("name"))
        release?.resume()
        await settle(action)
    }
}
