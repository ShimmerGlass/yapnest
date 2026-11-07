import Combine
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

        private func session(_ jid: JID, device: String, callMedia: (any CallMediaFactory)? = nil) throws -> XMPPSession {
            let account = AccountDirectory(url: directory(device))
            let database = try account.openDatabase()
            return try XMPPSession(
                credentials: credentials(jid), resource: device,
                database: database,
                attachments: account.attachments,
                pushRelay: Self.relay,
                callMedia: callMedia,
                identityKeys: testIdentityKeys(for: database),
                resumeTickets: tickets(device),
            )
        }

        /// Where the app leaves its stream for the extension.
        private func tickets(_ device: String) -> ResumeTicketStore {
            ResumeTicketStore(directory: AccountDirectory(url: directory(device)))
        }

        /// The extension's, with the app's identity, as on a phone.
        private func fetcher(_ jid: JID, device: String) -> NotificationFetcher {
            NotificationFetcher(
                credentials: credentials(jid), directory: directory(device), resource: "\(device)-push", appResource: device,
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

        /// Whether each of a session's connections was a resumption of its stream.
        private final class ResumeLog: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            var cancellable: AnyCancellable?
            var resumed: Bool { lock.withLock { values.contains(true) } }
            func record(_ resumed: Bool) { lock.withLock { values.append(resumed) } }
        }

        private func watchResumptions(of session: XMPPSession) -> ResumeLog {
            let log = ResumeLog()
            log.cancellable = session.client.$state.sink { state in
                if case .connected(let resumed) = state { log.record(resumed) }
            }
            return log
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

            await a.suspend()
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

        /// The extension takes over the app's stream, and leaves it for the next wake, so the server never
        /// sees a second session come and go; the app then resumes it, losing and doubling nothing.
        @Test func extensionResumesTheAppsStreamWakeAfterWake() async throws {
            let a = try session(alice, device: "alice-push"), b = try session(bob, device: "bob-push")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            _ = try a.database.claimNotifications()
            let store = tickets("alice-push")
            let started = Date()
            let resumptions = watchResumptions(of: a)

            await a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            let appsStream = try #require(store.load()).stream
            // Over SASL2 the server picks the resource, so only the account is known.
            #expect(appsStream.boundJid?.hasPrefix("\(alice)/") == true)

            let tag = UUID().uuidString.prefix(6)
            var bodies: [String] = []
            var generation = try #require(store.load()).generation
            for n in 1...2 {
                let secret = "resumed wake #\(n) \(tag)"
                bodies.append(secret)
                try b.send(secret, to: alice)
                try await waitUntil("bob's message to go out") { try message(secret, in: b).first?.status == .sent }

                let outcome = await fetcher(alice, device: "alice-push").fetch(timeout: 15)
                guard case .notifications(let notifications, _, _) = outcome else {
                    Issue.record("Fetch \(n) failed: \(outcome)")
                    return
                }
                #expect(notifications.contains { $0.body == secret }, "notification \(n)")
                #expect(try message(secret, in: a).count == 1, "stored once after wake \(n)")
                let ticket = try #require(store.load(), "wake \(n) left no ticket")
                #expect(ticket.stream.id == appsStream.id, "wake \(n) opened a session of its own instead of resuming the app's")
                #expect(ticket.stream.resumedH != nil)
                #expect(ticket.generation > generation)
                generation = ticket.generation
            }

            let before = resumptions.resumed
            a.connect()
            try await waitUntil("alice to come back") { a.state.value == .connected(isSyncing: false) }
            try await Task.sleep(for: .seconds(2))
            #expect(!before)
            #expect(resumptions.resumed, "the app started a new session instead of resuming after the extension")
            for body in bodies { #expect(try message(body, in: a).count == 1, "\(body) after the app returned") }
            let undecryptable = try await a.database.reader.read {
                try Message.filter(Column("encryption") == "omemoUndecryptable" && Column("timestamp") > started.addingTimeInterval(-1)).fetchCount($0)
            }
            #expect(undecryptable == 0)
            // The app uses the stream now, so what the extension kept of it is stale.
            #expect(store.load() == nil)
        }

        /// A ticket for a stream the server doesn't have: the extension falls back to a session on the app's
        /// resource, and leaves that one's ticket, which the next wake resumes.
        @Test func aTicketForAnUnknownStreamFallsBackCleanly() async throws {
            let a = try session(alice, device: "alice-push"), b = try session(bob, device: "bob-push")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            _ = try a.database.claimNotifications()
            let store = tickets("alice-push")
            await a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            let bogus = "no-such-stream-\(UUID().uuidString.prefix(8))"
            store.save(.init(id: bogus, incoming: 3, outgoing: 3, boundJid: "\(alice)/Yapnest-gone"))

            let secret = "after a bad ticket \(UUID().uuidString.prefix(6))"
            try b.send(secret, to: alice)
            try await waitUntil("bob's message to go out") { try message(secret, in: b).first?.status == .sent }
            let outcome = await fetcher(alice, device: "alice-push").fetch(timeout: 15)
            guard case .notifications(let notifications, _, _) = outcome else {
                Issue.record("Fetch failed: \(outcome)")
                return
            }
            #expect(notifications.contains { $0.body == secret })
            let fallback = try #require(store.load()?.stream, "the fallback session left no ticket")
            #expect(fallback.id != bogus)
            #expect(fallback.resumedH == nil)

            // The next wake resumes what the fallback left.
            let again = "and the next wake \(UUID().uuidString.prefix(6))"
            try b.send(again, to: alice)
            try await waitUntil("bob's message to go out") { try message(again, in: b).first?.status == .sent }
            guard case .notifications(let next, _, _) = await fetcher(alice, device: "alice-push").fetch(timeout: 15) else {
                Issue.record("The second fetch failed")
                return
            }
            #expect(next.contains { $0.body == again })
            #expect(try #require(store.load()).stream.id == fallback.id)
            #expect(try message(again, in: a).count == 1)
        }

        /// iOS rings only for a live `propose`, and an extension that resumed the app's stream consumed it: the
        /// app, back with a new session, rings for it from what the extension handed over.
        @Test func aCallAnExtensionConsumedRingsWhenTheAppReturns() async throws {
            let a = try session(alice, device: "alice-push", callMedia: FakeCallMediaFactory())
            let b = try session(bob, device: "bob-push", callMedia: FakeCallMediaFactory())
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            a.addContact(bob)
            b.addContact(alice)
            try await waitUntil("each other in the roster") { try a.database.isInRoster(bob) && b.database.isInRoster(alice) }
            try await waitUntil("bob to be able to call alice") { b.canCall(alice) }
            _ = try a.database.claimNotifications()
            let store = tickets("alice-push")

            await a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            try b.startCall(to: alice)
            let sid = try #require(b.callState.value?.sid)

            let outcome = await fetcher(alice, device: "alice-push").fetch(timeout: 15)
            guard case .notifications = outcome else {
                Issue.record("Fetch failed: \(outcome)")
                return
            }
            let kept = store.readJournal()
            #expect(kept.isComplete)
            #expect(kept.entries.contains { $0.xml.contains(sid) }, "the extension consumed the propose and kept nothing to ring for")
            let resumptions = watchResumptions(of: a)

            a.connect()
            try await waitUntil("alice's phone to ring") { a.callState.value?.phase == .incoming }
            #expect(a.callState.value?.sid == sid)
            #expect(resumptions.resumed, "the app started a new session after the extension")
            b.hangUpCall()
        }

        /// The app suspends, a contact goes away, says something in a room and to the app, and the extension
        /// wakes and resumes the stream: the app returns and resumes it too, with the presence updated, each
        /// message once, and what it had sent before neither lost nor doubled.
        @Test func theAppResumesAfterAnExtensionAndSeesWhatItConsumed() async throws {
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
            try await waitUntil("bob to see alice as a member") { b.groupRecipients(room) == [alice] }
            try await waitUntil("alice to see bob online") { a.presence(of: bob) == .online }
            _ = try a.database.claimNotifications()
            let tag = UUID().uuidString.prefix(6)
            let before = "sent before suspending \(tag)"
            try a.send(before, to: bob)
            try await waitUntil("bob to get it") { try message(before, in: b).count == 1 }
            let resumptions = watchResumptions(of: a)

            await a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            b.setShowForTesting(.away)
            let inRoom = "to the room \(tag)", direct = "to alice \(tag)"
            try b.send(inRoom, to: room)
            try b.send(direct, to: alice)
            try await waitUntil("the room to echo bob's message") { try message(inRoom, in: b).first?.serverId != nil }
            try await waitUntil("bob's message to go out") { try message(direct, in: b).first?.status == .sent }

            guard case .notifications = await fetcher(alice, device: "alice-push").fetch(timeout: 15) else {
                Issue.record("Fetch failed")
                return
            }
            #expect(a.presence(of: bob) == .online, "the app's memory is as it was when it suspended")

            a.connect()
            try await waitUntil("alice to come back") { a.state.value == .connected(isSyncing: false) }
            #expect(resumptions.resumed, "the app started a new session after the extension")
            try await waitUntil("bob's presence to be replayed") { a.presence(of: bob) == .away }
            try await Task.sleep(for: .seconds(2))
            #expect(try message(inRoom, in: a).count == 1)
            #expect(try message(direct, in: a).count == 1)
            let after = "sent after returning \(tag)"
            try a.send(after, to: bob)
            try await waitUntil("bob to get both") { try message(after, in: b).count == 1 && message(before, in: b).count == 1 }
            try await Task.sleep(for: .seconds(1))
            #expect(try message(after, in: b).count == 1)
            #expect(try message(before, in: b).count == 1)
            try await a.leaveGroup(room)
            try await b.leaveGroup(room)
        }

        /// Servers push for more than messages, in bursts: the extension
        /// catches up once for pushes that come together, and notifies once.
        @Test func burstOfPushesNotifiesOnce() async throws {
            let a = try session(alice, device: "alice-push"), b = try session(bob, device: "bob-push")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            _ = try a.database.claimNotifications()
            await a.suspend()
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

            await a.suspend()
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

        @Test func extensionDecryptsEncryptedGroupThenAppResumes() async throws {
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
            try await waitUntil("bob to see alice as a member") { b.groupRecipients(room) == [alice] }
            let group = try #require(try a.database.groupChat(room))
            #expect(try a.database.conversation(id: group.conversationId)?.isEncrypted == true)

            let tag = UUID().uuidString.prefix(6)
            let hiA = "hi from alice \(tag)", hiB = "hi from bob \(tag)"
            try a.send(hiA, to: room)
            try await waitUntil("bob to decrypt alice") { try message(hiA, in: b).first?.encryption == .omemo }
            try b.send(hiB, to: room)
            try await waitUntil("alice to decrypt bob") { try message(hiB, in: a).first?.encryption == .omemo }
            _ = try a.database.claimNotifications()

            await a.suspend()
            try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
            var bodies: [String] = []
            for n in 1...2 {
                let secret = "anyone up? #\(n) \(tag)"
                bodies.append(secret)
                let sent = try b.send(secret, to: room)
                #expect(sent.encryption == .omemo)
                try await waitUntil("the room to echo bob's message") { try message(secret, in: b).first?.serverId != nil }

                let outcome = await fetcher(alice, device: "alice-push").fetch(timeout: 15)
                guard case .notifications(let notifications, _, _) = outcome else {
                    Issue.record("Fetch failed: \(outcome)")
                    return
                }
                let notification = notifications.first { $0.peer == room && $0.body == secret }
                #expect(notification != nil, "extension notification for \(n)")
                let rows = try message(secret, in: a)
                #expect(rows.count == 1 && rows.first?.encryption == .omemo, "stored after fetch \(n)")

                a.connect()
                try await waitUntil("alice to resume") { a.state.value == .connected(isSyncing: false) }
                try await Task.sleep(for: .seconds(3))
                let after = try message(secret, in: a)
                #expect(after.count == 1 && after.first?.encryption == .omemo, "stored after resume \(n)")
                if n == 1 {
                    await a.suspend()
                    try await waitUntil("alice to drop the connection") { if case .disconnected = a.state.value { true } else { false } }
                }
            }
            let all = try await a.database.reader.read { try Message.filter(Column("body").like("anyone up?%\(tag)")).fetchAll($0) }
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
