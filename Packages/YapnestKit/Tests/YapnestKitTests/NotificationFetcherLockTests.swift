import Foundation
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!

/// What a push does when another process holds the session. Serialized: the
/// fetcher's queue is shared by the whole process, and a fetch that arrives
/// while another is under way is treated as part of the same burst.
@Suite(.serialized) struct NotificationFetcherLockTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "fetcher-\(UUID().uuidString)")
    var lockURL: URL { root.appending(path: "session.lock") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fetcher() -> NotificationFetcher {
        NotificationFetcher(
            credentials: .init(jid: me, password: "x"), directory: root.appending(path: "account"), resource: "push",
            lock: ProcessLock(url: lockURL),
        )
    }

    @Test func aPushWhileTheShareExtensionHoldsTheSessionIsBusy() async {
        let share = ProcessLock(url: lockURL)
        #expect(share.tryLock(as: .share))
        defer { share.unlock() }

        #expect(await fetcher().fetch() == .busy)
    }

    @Test func aPushWhileTheAppHoldsTheSessionLeavesTheNotificationToTheApp() async {
        let app = ProcessLock(url: lockURL)
        #expect(app.tryLock(as: .app))
        defer { app.unlock() }

        #expect(await fetcher().fetch() == .appIsRunning)
    }

    @Test func aPushQueuedBehindASlowOneKeepsItsOwnDeadline() async {
        let share = ProcessLock(url: lockURL)
        #expect(share.tryLock(as: .share))
        defer { share.unlock() }
        let fetcher = fetcher()

        // The first waits the full 3 seconds for the lock, then gives up. It
        // finds the share extension there, not the app, so it leaves no mark
        // that would make the second skip its catch-up for that reason.
        let first = Task { await fetcher.fetch(timeout: 20) }
        try? await Task.sleep(for: .milliseconds(500))

        let arrived = Date()
        let second = await fetcher.fetch(timeout: 5)
        let waited = Date().timeIntervalSince(arrived)
        _ = await first.value

        // By the time it's its turn, 2.5 seconds of its 5 are left: too few to
        // connect, so it only hands out what's stored. Counting from when its
        // turn came it would wait for the lock again and run past its deadline.
        guard case .notifications = second else {
            Issue.record("expected only the stored notifications, got \(second)")
            return
        }
        #expect(waited < 5)
    }

    @Test func aPushBehindACatchUpThatFoundTheSessionBusyTriesForItself() async {
        let share = ProcessLock(url: lockURL)
        #expect(share.tryLock(as: .share))
        defer { share.unlock() }
        let fetcher = fetcher()

        let first = Task { await fetcher.fetch() }
        try? await Task.sleep(for: .milliseconds(200))
        let second = Task { await fetcher.fetch() }
        let third = Task { await fetcher.fetch() }

        // The second never caught up, so it mustn't stand in for the third.
        _ = await first.value
        _ = await second.value
        #expect(await third.value == .busy)
    }

    @Test func pushesQueuedWhileTheAppHoldsTheSessionDontEachWaitForIt() async {
        let app = ProcessLock(url: lockURL)
        #expect(app.tryLock(as: .app))
        defer { app.unlock() }
        let fetcher = fetcher()

        let first = Task { await fetcher.fetch() }
        try? await Task.sleep(for: .milliseconds(200))
        let started = Date()
        let second = Task { await fetcher.fetch() }
        let third = Task { await fetcher.fetch() }

        #expect(await first.value == .appIsRunning)
        for outcome in [await second.value, await third.value] {
            guard case .notifications = outcome else {
                Issue.record("expected only the stored notifications, got \(outcome)")
                continue
            }
        }
        // Waiting in turn would take 9 seconds in all.
        #expect(Date().timeIntervalSince(started) < 4)
    }
}
