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
    var appLockURL: URL { root.appending(path: "app.lock") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fetcher() -> NotificationFetcher {
        NotificationFetcher(
            credentials: .init(jid: me, password: "x"), directory: root.appending(path: "account"), resource: "push",
            lock: ProcessLock(url: lockURL), appLock: ProcessLock(url: appLockURL),
        )
    }

    @Test func aPushWhileTheShareExtensionHoldsTheSessionIsBusy() async {
        let share = ProcessLock(url: lockURL)
        #expect(share.tryLock())
        defer { share.unlock() }

        #expect(await fetcher().fetch() == .busy)
    }

    @Test func aPushWhileTheAppHoldsTheSessionLeavesTheNotificationToTheApp() async {
        let app = ProcessLock(url: lockURL), appLock = ProcessLock(url: appLockURL)
        #expect(appLock.tryLock())
        #expect(app.tryLock())
        defer { app.unlock(); appLock.unlock() }

        #expect(await fetcher().fetch() == .appIsRunning)
    }

    @Test func aPushQueuedBehindASlowOneKeepsItsOwnDeadline() async {
        let share = ProcessLock(url: lockURL)
        #expect(share.tryLock())
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
        // connect, so it only hands out what's stored, and as no catch-up looked
        // into its push, an empty claim isn't quiet. Counting from when its
        // turn came it would wait for the lock again and run past its deadline.
        guard case .incomplete = second else {
            Issue.record("expected only the stored notifications, as incomplete, got \(second)")
            return
        }
        #expect(waited < 5)
    }

    @Test func aPushBehindACatchUpThatFoundTheSessionBusyTriesForItself() async {
        let share = ProcessLock(url: lockURL)
        #expect(share.tryLock())
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
        let app = ProcessLock(url: lockURL), appLock = ProcessLock(url: appLockURL)
        #expect(appLock.tryLock())
        #expect(app.tryLock())
        defer { app.unlock(); appLock.unlock() }
        let fetcher = fetcher()

        let first = Task { (await fetcher.fetch(), Date()) }
        try? await Task.sleep(for: .milliseconds(200))
        let second = Task { await fetcher.fetch() }
        let third = Task { (await fetcher.fetch(), Date()) }

        let (firstOutcome, firstDone) = await first.value
        #expect(firstOutcome == .appIsRunning)
        let (thirdOutcome, thirdDone) = await third.value
        for outcome in [await second.value, thirdOutcome] {
            guard case .notifications = outcome else {
                Issue.record("expected only the stored notifications, got \(outcome)")
                continue
            }
        }
        // Waiting in turn would take 3 seconds more for each. Timed from the
        // end of the first's wait, not from when the others arrived: that
        // span is mostly the first's 3-second wait, which left a busy machine
        // under a second to spare, while the two after it take about 100
        // milliseconds.
        #expect(thirdDone.timeIntervalSince(firstDone) < NotificationFetcher.maxLockWait)
    }

    @Test func aCatchUpThatDidntFinishAndStoredNothingKeepsTheRelaysAlert() async {
        let unreachable = NotificationFetcher(
            credentials: .init(jid: JID("me@nowhere.invalid")!, password: "x"), directory: root.appending(path: "account"), resource: "push",
            lock: ProcessLock(url: lockURL), appLock: ProcessLock(url: appLockURL), identityKeys: MemoryIdentityKeyStore(),
        )

        let outcome = await unreachable.fetch(timeout: 5)

        guard case .incomplete(let edited, _) = outcome else {
            Issue.record("expected the relay's alert to show, got \(outcome)")
            return
        }
        #expect(edited.isEmpty)
    }

    @Test func nothingIsClaimedOnceTheExtensionHasExpired() async throws {
        let fetcher = fetcher()
        let database = try fetcher.account.files.openDatabase()
        let chat = try database.conversation(with: JID("alice@example.org")!)
        _ = try database.claimNotifications()
        try database.insert(Message(conversationId: chat.id!, direction: .incoming, sender: chat.peer, body: "hi", remoteId: "1"))

        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try fetcher.claimed(from: database)
        }
        cancelled.cancel()
        #expect(try await cancelled.value == .failed("Cancelled"))

        guard case .notifications(let new, _, _) = try fetcher.claimed(from: database) else {
            Issue.record("expected the message to still be there")
            return
        }
        #expect(new.map(\.body) == ["hi"])
    }
}
