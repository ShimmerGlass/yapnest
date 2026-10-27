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

    @Test func holderIsTheRoleOfWhoeverHoldsTheLock() throws {
        let url = try lockURL()
        let app = ProcessLock(url: url)
        #expect(app.tryLock(as: .app))
        #expect(ProcessLock(url: url).holder == .app)
        app.unlock()
        #expect(ProcessLock(url: url).holder == nil)
    }

    @Test func holderIsNilWithoutAFile() throws {
        #expect(ProcessLock(url: try lockURL()).holder == nil)
    }

    @Test func staleRoleLeftByAHolderThatIsGoneIsNotBelieved() throws {
        let url = try lockURL()
        // What a crashed process leaves: its role in the file, and no lock.
        try Data("share".utf8).write(to: url)
        #expect(ProcessLock(url: url).holder == nil)
    }

    @Test func holderWithoutARoleIsUnknown() throws {
        let url = try lockURL()
        let lock = ProcessLock(url: url)
        #expect(lock.tryLock())
        #expect(ProcessLock(url: url).holder == nil)
    }

    @Test func newHolderReplacesTheLastOnesRole() throws {
        let url = try lockURL()
        let first = ProcessLock(url: url)
        #expect(first.tryLock(as: .notification))
        first.unlock()
        let second = ProcessLock(url: url)
        #expect(second.tryLock())
        #expect(ProcessLock(url: url).holder == nil)
    }

    @Test func secondHolderCannotTakeALockInUse() throws {
        let url = try lockURL()
        let first = ProcessLock(url: url), second = ProcessLock(url: url)
        #expect(first.tryLock(as: .app))
        #expect(!second.tryLock(as: .share))
        #expect(!second.isLocked)
        // The record is still the holder's.
        #expect(ProcessLock(url: url).holder == .app)
    }

    @Test func tryLockWhileAlreadyHeldSucceedsWithoutChangingTheRole() throws {
        let url = try lockURL()
        let lock = ProcessLock(url: url)
        #expect(lock.tryLock(as: .app))
        #expect(lock.tryLock(as: .share))
        #expect(lock.isLocked)
        #expect(ProcessLock(url: url).holder == .app)
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
        #expect(first.tryLock(as: .share))
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            first.unlock()
        }
        let second = ProcessLock(url: url)
        let got = await Task.detached { second.lock(timeout: 5, as: .app) }.value
        #expect(got)
        #expect(ProcessLock(url: url).holder == .app)
    }

    @Test func manyWaitsForTheLockDoNotTakeTheConcurrencyPool() async throws {
        let url = try lockURL()
        let holder = ProcessLock(url: url)
        #expect(holder.tryLock(as: .app))
        // More waiters than the pool has threads.
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 4
        let waiting = Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<waiters {
                    let lock = ProcessLock(url: url)
                    group.addTask { await lock.waitForLock(timeout: 1.5, as: .share) }
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
        #expect(first.tryLock(as: .app))
        let second = ProcessLock(url: url)
        let started = Date()
        #expect(!second.lock(timeout: 0.25, as: .share))
        #expect(Date().timeIntervalSince(started) >= 0.25)
    }

    @Test func lockDroppedWithoutUnlockIsReleased() throws {
        let url = try lockURL()
        var first: ProcessLock? = ProcessLock(url: url)
        #expect(first?.tryLock(as: .app) == true)
        first = nil
        #expect(ProcessLock(url: url).tryLock())
    }
}
