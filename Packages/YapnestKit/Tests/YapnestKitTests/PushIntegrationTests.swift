import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    /// What happens while the app is away: the notification extension's
    /// catch-up, and enabling push through the relay. Enable with
    /// `YAPNEST_INTEGRATION=1 swift test --filter PushIntegration`.
    @Suite
    struct PushIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")
        static let relay = JID("push.localhost")!

        /// An account's directory, as the app and its extension share it. Kept
        /// across runs, like the other suites' OMEMO devices.
        private func directory(_ device: String) -> URL {
            LiveServer.stateDirectory.appending(path: device)
        }

        private func credentials(_ jid: JID) -> XMPPSession.Credentials {
            .init(jid: jid, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true)
        }

        private func session(_ jid: JID, device: String) throws -> XMPPSession {
            let account = AccountDirectory(url: directory(device))
            let database = try account.openDatabase()
            return try XMPPSession(
                credentials: credentials(jid), resource: device,
                database: database,
                attachments: account.attachments,
                pushRelay: Self.relay,
                identityKeys: testIdentityKeys(for: database),
            )
        }

        /// The extension's, with the app's identity, as on a phone.
        private func fetcher(_ jid: JID, device: String) -> NotificationFetcher {
            NotificationFetcher(
                credentials: credentials(jid), directory: directory(device), resource: "\(device)-push",
                lock: ProcessLock(url: directory(device).appending(path: "session.lock")),
                identityKeys: testIdentityKeys(forAccountAt: directory(device)),
            )
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try await !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        private func connected(_ sessions: XMPPSession...) async throws {
            for session in sessions {
                session.connect()
                try await waitUntil("\(session.account) to connect, sync and publish its device") {
                    session.state.value == .connected(isSyncing: false) && session.isEncryptionReady
                }
            }
            for session in sessions {
                for other in sessions where other !== session {
                    let device = Int32(bitPattern: other.omemoDeviceId)
                    try await waitUntil("\(session.account) to hear of \(other.account)'s device") {
                        let known = session.announcedDevices(of: other.account)
                        return known.isEmpty ? other.account != session.account : known.contains(device)
                    }
                }
            }
        }

        private func message(_ body: String, in session: XMPPSession) throws -> [Message] {
            try session.database.reader.read { try Message.filter(Column("body") == body).fetchAll($0) }
        }

        /// The app goes to the background; a message arrives; the extension
        /// fetches and decrypts it from the archive, in a session of its own.
        @Test func extensionFetchesWhatArrivedMeanwhile() async throws {
            let a = try session(alice, device: "alice-push"), b = try session(bob, device: "bob-push")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            _ = try a.database.claimNotifications()

            a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            let secret = "while you were out \(UUID().uuidString.prefix(6))"
            let sent = try b.send(secret, to: alice)
            #expect(sent.encryption == .omemo)
            try await waitUntil("bob's message to go out") { try message(secret, in: b).first?.status == .sent }

            let outcome = await fetcher(alice, device: "alice-push").fetch(timeout: 15)
            guard case .notifications(let notifications, _, let badge) = outcome else {
                Issue.record("Fetch failed: \(outcome)")
                return
            }
            let notification = try #require(notifications.first { $0.body == secret })
            #expect(notification.title == "bob")
            #expect(notification.peer == bob)
            #expect(badge >= 1)
            // Claimed: the app won't notify again.
            #expect(try a.database.claimNotifications().isEmpty)

            // The app comes back: the server replays what it held, which the
            // extension already decrypted.
            a.connect()
            try await waitUntil("alice to resume") { a.state.value == .connected(isSyncing: false) }
            try await Task.sleep(for: .seconds(1))
            let copies = try message(secret, in: a)
            #expect(copies.count == 1)
            #expect(copies.first?.encryption == .omemo)
            let undecryptable = try await a.database.reader.read {
                try Message.filter(Column("encryption") == "omemoUndecryptable" && Column("timestamp") > sent.timestamp.addingTimeInterval(-1)).fetchCount($0)
            }
            #expect(undecryptable == 0)
        }

        /// Servers push for more than messages, in bursts: the extension
        /// catches up once for pushes that come together, and notifies once.
        @Test func burstOfPushesNotifiesOnce() async throws {
            let a = try session(alice, device: "alice-push"), b = try session(bob, device: "bob-push")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            _ = try a.database.claimNotifications()
            a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            let secret = "just once \(UUID().uuidString.prefix(6))"
            try b.send(secret, to: alice)
            try await waitUntil("bob's message to go out") { try message(secret, in: b).first?.status == .sent }

            let fetcher = fetcher(alice, device: "alice-push")
            let outcomes = await withTaskGroup(of: NotificationFetcher.Outcome.self) { group in
                for _ in 0..<5 { group.addTask { await fetcher.fetch(timeout: 15) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            var shown: [MessageNotification] = []
            for outcome in outcomes {
                guard case .notifications(let notifications, _, _) = outcome else {
                    Issue.record("Fetch didn't run: \(outcome)")
                    continue
                }
                shown += notifications
            }
            #expect(shown.filter { $0.body == secret }.count == 1)
        }

        @Test func extensionReadsGroupArchives() async throws {
            let a = try session(alice, device: "alice-push"), b = try session(bob, device: "bob-push")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            a.addContact(bob)
            b.addContact(alice)
            try await waitUntil("each other in the roster") { try a.database.isInRoster(bob) && b.database.isInRoster(alice) }
            let room = try await a.createGroup(name: "Night owls", inviting: [bob])
            try await LiveServer.accept(invitationTo: room, on: b)
            try await waitUntil("bob to join") { b.roomStatus(room)?.isJoined == true && b.roomStatus(room)?.isSyncing == false }
            try await waitUntil("alice to see bob as a member") { a.groupRecipients(room) == [bob] }
            _ = try a.database.claimNotifications()

            a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            let secret = "anyone up? \(UUID().uuidString.prefix(6))"
            try b.send(secret, to: room)
            try await waitUntil("the room to echo bob's message") { try message(secret, in: b).first?.serverId != nil }

            let outcome = await fetcher(alice, device: "alice-push").fetch(timeout: 15)
            guard case .notifications(let notifications, _, _) = outcome else {
                Issue.record("Fetch failed: \(outcome)")
                return
            }
            let notification = try #require(notifications.first { $0.peer == room })
            #expect(notification.body == secret)
            #expect(notification.title == "Night owls")
            #expect(notification.subtitle == "bob")

            a.connect()
            try await waitUntil("alice to resume") { a.state.value == .connected(isSyncing: false) }
            try await a.leaveGroup(room)
            try await b.leaveGroup(room)
        }

        /// Needs the relay on the local Prosody: `dev/relay.sh`.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_RELAY"] == "1"))
        func enablesPushThroughTheRelay() async throws {
            let a = try session(alice, device: "alice-push")
            try a.database.setSetting(.pushNode, nil)
            a.setPushToken(Data(repeating: 0xab, count: 32), sandbox: true)
            try await connected(a)
            defer { a.disconnect() }
            try await waitUntil("push to be enabled") { try a.database.setting(.pushNode) != nil }
            #expect(try a.database.setting(.pushRelay) == Self.relay.description)

            // Registering again gives the same node, so the server replaces it.
            let node = try a.database.setting(.pushNode)
            a.disconnect()
            try await connected(a)
            try await Task.sleep(for: .seconds(1))
            #expect(try a.database.setting(.pushNode) == node)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_RELAY"] == "1"))
        func aNewTokenReplacesTheOldNode() async throws {
            let a = try session(alice, device: "alice-push")
            try a.database.setSetting(.pushNode, nil)
            a.setPushToken(Data(repeating: 0x01, count: 32), sandbox: true)
            try await connected(a)
            defer { a.disconnect() }
            try await waitUntil("push to be enabled") { try a.database.setting(.pushNode) != nil }
            let old = try #require(try a.database.setting(.pushNode))

            a.setPushToken(Data(repeating: 0x02, count: 32), sandbox: true)
            try await waitUntil("the new node to be stored") { try a.database.setting(.pushNode) != old }
            let new = try #require(try a.database.setting(.pushNode))
            #expect(new != old)
            #expect(try a.database.setting(.pushRelay) == Self.relay.description)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_RELAY"] == "1"))
        func disablingPushForgetsAndStopsTheNode() async throws {
            let a = try session(alice, device: "alice-push")
            try a.database.setSetting(.pushNode, nil)
            a.setPushToken(Data(repeating: 0x03, count: 32), sandbox: true)
            try await connected(a)
            defer { a.disconnect() }
            try await waitUntil("push to be enabled") { try a.database.setting(.pushNode) != nil }

            await a.disablePush()
            #expect(try a.database.setting(.pushRelay) == nil)
            #expect(try a.database.setting(.pushNode) == nil)
        }
    }
}
