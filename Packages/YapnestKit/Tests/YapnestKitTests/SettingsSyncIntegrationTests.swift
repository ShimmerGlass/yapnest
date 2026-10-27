import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Yapnest's settings kept in the account's PEP, between two devices of one account.
    /// `YAPNEST_INTEGRATION=1 swift test --filter SettingsSyncIntegration`
    @Suite
    struct SettingsSyncIntegrationTests {
        let alice = LiveServer.jid("alice")

        private func device(_ name: String) async throws -> XMPPSession {
            let session = try await LiveServer.connectedSession(alice, resource: name)
            session.lock.withLock { $0.settingsSync.deviceId = "\(name)-\(UUID().uuidString.prefix(4))" }
            return session
        }

        /// Waits for the session's own sync to end, then starts it from a
        /// server without the node.
        private func startFromNoNode(_ session: XMPPSession) async throws {
            try await LiveServer.waitUntil("the first sync to end") { session.lock.withLock { !$0.settingsSync.syncing && $0.settingsSync.node != .unchecked } }
            await withCheckedContinuation { continuation in
                session.client.module(.pubsub).deleteNode(from: alice.martin, node: NS.settings) { _ in continuation.resume() }
            }
            session.lock.withLock { $0.settingsSync.startSession() }
            await session.runSettingsSync()
            try await LiveServer.waitUntil("the node to be checked") { session.lock.withLock { $0.settingsSync.node == .verified } }
        }

        private func accessModel(_ session: XMPPSession) async throws -> String? {
            try await withCheckedThrowingContinuation { continuation in
                session.client.module(.pubsub).retrieveNodeConfiguration(from: nil, node: NS.settings) { (result: Result<PubSubNodeConfig, PubSubError>) in
                    continuation.resume(with: result.map { $0.accessModel?.rawValue })
                }
            }
        }

        @Test func theNodeIsPrivateAndAChangeReachesTheOtherDevice() async throws {
            let a = try await device("settings-a")
            defer { a.disconnect() }
            try await LiveServer.forgettingSyncedSettings(of: a) { try await aChangeReachesTheOtherDevice(from: a) }
        }

        private func aChangeReachesTheOtherDevice(from a: XMPPSession) async throws {
            try await startFromNoNode(a)
            #expect(try await accessModel(a) == "whitelist")

            let b = try await device("settings-b")
            defer { b.disconnect() }
            try a.setStatus(availability: .dnd, message: "in a meeting")
            try await LiveServer.waitUntil("the other device to follow") {
                try b.database.setting(.availability) == "dnd" && b.statusMessage == "in a meeting"
            }
            #expect(try await accessModel(b) == "whitelist")

            try b.database.setFlag(.gifs, false)
            try await LiveServer.waitUntil("the first device to follow") { try a.database.setting(.gifs) == "0" }
            // Back to the default is a reset, which the other follows too.
            try b.database.setFlag(.gifs, true)
            try await LiveServer.waitUntil("the first device to follow again") { a.database.flag(.gifs, default: true) }
        }

        @Test func changesMadeOfflineOnBothDevicesConverge() async throws {
            let a = try await device("settings-a")
            defer { a.disconnect() }
            try await LiveServer.forgettingSyncedSettings(of: a) { try await offlineChangesConverge(from: a) }
        }

        private func offlineChangesConverge(from a: XMPPSession) async throws {
            try await startFromNoNode(a)
            let b = try await device("settings-b")
            defer { b.disconnect() }

            b.disconnect()
            try await LiveServer.waitUntil("b to disconnect") { !b.isConnected }
            try a.database.setSetting(.availability, "away")
            try await LiveServer.waitUntil("a's change to be published") { try a.database.pendingSyncItems().isEmpty }
            try b.database.setSetting(.statusMessage, "from b")
            try b.database.setFlag(.sendsChatStates, false)

            b.connect()
            try await LiveServer.waitUntil("b to catch up", timeout: 60) { try b.database.setting(.availability) == "away" }
            try await LiveServer.waitUntil("a to hear of b's changes", timeout: 60) {
                try a.database.setting(.statusMessage) == "from b" && a.database.setting(.sendsChatStates) == "0"
            }
        }
    }
}
