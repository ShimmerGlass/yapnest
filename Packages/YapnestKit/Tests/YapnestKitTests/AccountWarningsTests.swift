import Foundation
import Martin
import Testing
@testable import YapnestKit

struct AccountWarningsTests {
    @Test func aRepeatReplacesRatherThanStacks() {
        let warnings = AccountWarnings()
        warnings.post("profile", title: "Profile not saved", detail: "first")
        warnings.post("privacy", title: "Setting not saved", detail: "other")
        warnings.post("profile", title: "Profile not saved", detail: "second")
        #expect(warnings.current.map(\.key) == ["profile", "privacy"])
        #expect(warnings.current.first?.detail == "second")
    }

    @Test func clearingRemovesOnlyThatKey() {
        let warnings = AccountWarnings()
        warnings.post("a", title: "A", detail: "a")
        warnings.post("b", title: "B", detail: "b")
        warnings.clear("a")
        warnings.clear("missing")
        #expect(warnings.current.map(\.key) == ["b"])
    }

    @Test func theDetailComesFromTheServersError() {
        let warnings = AccountWarnings()
        warnings.post("p", title: "Profile not saved", friendly: "Your profile wasn't saved", error: ServerError(condition: "forbidden", text: "Not yours"))
        #expect(warnings.current.first?.detail == "Your profile wasn't saved: Not yours (forbidden)")
    }

    @Test func updatesStartWithTheListAndFollowChanges() async {
        let warnings = AccountWarnings()
        warnings.post("a", title: "A", detail: "a")
        var seen: [[String]] = []
        for await list in warnings.updates {
            seen.append(list.map(\.key))
            if seen.count == 1 { warnings.clear("a") } else { break }
        }
        #expect(seen == [["a"], []])
    }

    private final class Tries: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    @Test func aSuccessfulRetryClearsTheWarning() async {
        let warnings = AccountWarnings()
        warnings.post("p", title: "Profile not saved", detail: "x") {}
        #expect(await warnings.retry("p"))
        #expect(warnings.current.isEmpty)
    }

    @Test func aFailedRetryReplacesTheDetailAndKeepsTheRetry() async {
        let warnings = AccountWarnings()
        let tries = Tries()
        warnings.post("p", title: "Profile not saved", detail: "old") {
            if tries.next() == 1 { throw ServerError(condition: "forbidden", text: "Still no") }
        }
        #expect(await warnings.retry("p") == false)
        #expect(warnings.current.first?.detail == "Profile not saved: Still no (forbidden)")
        #expect(await warnings.retry("p"))
        #expect(warnings.current.isEmpty)
        #expect(tries.value == 2)
    }

    @Test func aWarningWithoutRetryCannotBeRetried() async {
        let warnings = AccountWarnings()
        warnings.post("p", title: "T", detail: "d")
        #expect(await warnings.retry("p") == false)
        #expect(warnings.current.count == 1)
    }
}

struct ServerErrorMessageTests {
    @Test func aFinalErrorIsTold() {
        let message = ServerError.userMessage(for: ServerError(condition: "forbidden", text: "No"))
        #expect(message == "The server refused: No (forbidden)")
    }

    @Test func aPassingOneSaysSo() {
        #expect(ServerError.userMessage(for: URLError(.timedOut)) == "The server didn't answer in time (remote-server-timeout)")
    }

    @Test func anUnsupportedOneSaysSo() {
        #expect(ServerError.userMessage(for: ServerError(condition: "feature-not-implemented")).hasPrefix("The server doesn't support this"))
    }

    @Test func theLeadCanBeReplaced() {
        #expect(ServerError.userMessage(for: ServerError(condition: "forbidden"), friendly: "Couldn't join") == "Couldn't join (forbidden)")
    }

    @Test func anErrorOfOurOwnKeepsItsText() {
        struct Offline: LocalizedError { var errorDescription: String? { "You're offline." } }
        #expect(ServerError.userMessage(for: Offline()) == "You're offline.")
        #expect(!ServerError.isFromServer(Offline()))
    }

    @Test func aMartinErrorIsTheServers() {
        #expect(ServerError.isFromServer(XMPPError.not_allowed(nil)))
    }
}
