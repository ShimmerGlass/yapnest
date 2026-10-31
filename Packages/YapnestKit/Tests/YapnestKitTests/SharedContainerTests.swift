import Foundation
import Testing
@testable import YapnestKit

/// Serialized: the device id lives in the process-wide defaults.
@Suite(.serialized) struct DeviceIdTests {
    private let key = "yapnest.deviceId"

    /// Runs `body` with both defaults stores set as given, and puts back what was there.
    private func withDefaults(shared: String?, standard: String?, _ body: () -> Void) {
        let group = SharedContainer.defaults, own = UserDefaults.standard
        let saved = (group.string(forKey: key), own.string(forKey: key))
        func put(_ value: String?, in defaults: UserDefaults) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        put(shared, in: group)
        put(standard, in: own)
        defer {
            put(saved.0, in: group)
            put(saved.1, in: own)
        }
        body()
    }

    @Test func idFromBeforeTheExtensionIsKeptAndMovedToTheSharedDefaults() {
        withDefaults(shared: nil, standard: "abcd1234") {
            #expect(SharedContainer.existingDeviceId == nil)
            #expect(SharedContainer.deviceId == "abcd1234")
            #expect(SharedContainer.existingDeviceId == "abcd1234")
        }
    }

    @Test func sharedIdWinsOverTheOldOne() {
        withDefaults(shared: "11111111", standard: "22222222") {
            #expect(SharedContainer.deviceId == "11111111")
        }
    }

    @Test func newInstallMakesOneEightCharacterIdAndKeepsIt() {
        withDefaults(shared: nil, standard: nil) {
            let id = SharedContainer.deviceId
            #expect(id.count == 8 && id == id.lowercased())
            #expect(SharedContainer.deviceId == id)
            #expect(SharedContainer.existingDeviceId == id)
        }
    }

    @Test func forgettingTheIdMakesTheNextAccountANewOne() {
        withDefaults(shared: "11111111", standard: "22222222") {
            SharedContainer.forgetDeviceId()
            #expect(SharedContainer.existingDeviceId == nil)
            #expect(UserDefaults.standard.string(forKey: key) == nil)
            #expect(SharedContainer.deviceId != "11111111" && SharedContainer.deviceId != "22222222")
        }
    }

    @Test func extensionReadingTheIdDoesNotMakeOne() {
        withDefaults(shared: nil, standard: nil) {
            #expect(SharedContainer.existingDeviceId == nil)
        }
    }
}

struct ProcessLockTests {
    private func lockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yapnest-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "session.lock")
    }

    @Test func theAppIsNotRunningWhenNobodyHoldsItsLock() throws {
        let url = try lockURL()
        #expect(!ProcessLock(url: url).appIsRunning)
        let app = ProcessLock(url: url)
        #expect(app.tryLock())
        app.unlock()
        #expect(!ProcessLock(url: url).appIsRunning)
    }

    @Test func theAppIsRunningWhileItHoldsItsLockFromAnotherOpenOfTheFile() throws {
        let url = try lockURL()
        let app = ProcessLock(url: url)
        #expect(app.tryLock())
        #expect(ProcessLock(url: url).appIsRunning)
        #expect(ProcessLock(url: url).appIsRunning)
        app.unlock()
        #expect(!ProcessLock(url: url).appIsRunning)
    }

    @Test func askingWhetherTheAppIsRunningLeavesTheLockFree() throws {
        let url = try lockURL()
        #expect(!ProcessLock(url: url).appIsRunning)
        #expect(ProcessLock(url: url).tryLock())
    }

    @Test func theAppIsRunningFromTheFirstMomentItHoldsTheSessionLock() throws {
        // The app takes its own lock before it waits for the session lock, and
        // never holds the session lock without it.
        let directory = try lockURL().deletingLastPathComponent()
        let session = ProcessLock(url: directory.appending(path: "session.lock"))
        let appURL = directory.appending(path: "app.lock")
        let app = ProcessLock(url: appURL)
        let extensionSession = ProcessLock(url: directory.appending(path: "session.lock"))
        #expect(extensionSession.tryLock())

        #expect(app.tryLock())
        #expect(!session.tryLock())
        #expect(ProcessLock(url: appURL).appIsRunning)
        extensionSession.unlock()
        #expect(session.tryLock())
        #expect(ProcessLock(url: appURL).appIsRunning)
        session.unlock()
        app.unlock()
        #expect(!ProcessLock(url: appURL).appIsRunning)
    }

    @Test func secondHolderCannotTakeALockInUse() throws {
        let url = try lockURL()
        let first = ProcessLock(url: url), second = ProcessLock(url: url)
        #expect(first.tryLock())
        #expect(!second.tryLock())
        #expect(!second.isLocked)
    }

    @Test func tryLockWhileAlreadyHeldSucceeds() throws {
        let url = try lockURL()
        let lock = ProcessLock(url: url)
        #expect(lock.tryLock())
        #expect(lock.tryLock())
        #expect(lock.isLocked)
    }

    @Test func unlockIsIdempotent() throws {
        let url = try lockURL()
        let lock = ProcessLock(url: url)
        lock.unlock() // never locked
        #expect(lock.tryLock())
        lock.unlock()
        lock.unlock()
        #expect(!lock.isLocked)
        #expect(ProcessLock(url: url).tryLock())
    }

    @Test func lockWaitsForTheHolderToLetGo() async throws {
        let url = try lockURL()
        let first = ProcessLock(url: url)
        #expect(first.tryLock())
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            first.unlock()
        }
        let second = ProcessLock(url: url)
        let got = await Task.detached { second.lock(timeout: 5) }.value
        #expect(got)
    }

    @Test func manyWaitsForTheLockDoNotTakeTheConcurrencyPool() async throws {
        let url = try lockURL()
        let holder = ProcessLock(url: url)
        #expect(holder.tryLock())
        // More waiters than the pool has threads.
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 4
        let waiting = Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<waiters {
                    let lock = ProcessLock(url: url)
                    group.addTask { await lock.waitForLock(timeout: 1.5) }
                }
                return await group.reduce(into: [Bool]()) { $0.append($1) }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        // Other work still runs while they wait.
        let started = Date()
        await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(await waiting.value.allSatisfy { !$0 })
    }

    @Test func lockGivesUpAfterTheTimeout() throws {
        let url = try lockURL()
        let first = ProcessLock(url: url)
        #expect(first.tryLock())
        let second = ProcessLock(url: url)
        let started = Date()
        #expect(!second.lock(timeout: 0.25))
        #expect(Date().timeIntervalSince(started) >= 0.25)
    }

    @Test func lockDroppedWithoutUnlockIsReleased() throws {
        let url = try lockURL()
        var first: ProcessLock? = ProcessLock(url: url)
        #expect(first?.tryLock() == true)
        first = nil
        #expect(ProcessLock(url: url).tryLock())
    }
}
