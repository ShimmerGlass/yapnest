import Combine
import Foundation
import GRDB
import Martin
import Synchronization
import Testing
@testable import YapnestKit

extension LiveServer {
    /// `YAPNEST_INTEGRATION=1 swift test --filter SessionResilience`
    @Suite
    struct SessionResilienceIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func waitUntil(_ what: String, timeout: TimeInterval = 60, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try await !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        /// A message staged while the connection is down goes out when the
        /// stream is resumed, rather than at the next new session.
        @Test func aMessageStagedOfflineGoesOutAfterAResume() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try LiveServer.makeSession(alice, resource: "resume-\(UUID().uuidString.prefix(6))", database: try Self.device("alice-resume-plain"), port: proxy.port)
            session.connect()
            defer { session.disconnect() }
            try await waitUntil("the session") { session.state.value == .connected(isSyncing: false) }
            try await waitUntil("stream management") { session.client.module(.streamManagement).resumptionEnabled }

            let resumed = Mutex(false)
            // Martin's State compares equal whatever `resumed` says, so match the payload.
            let watch = session.client.$state.sink { state in
                if case .connected(let wasResumed) = state, wasResumed { resumed.withLock { $0 = true } }
            }
            defer { watch.cancel() }

            proxy.isRefusing = true
            proxy.cut()
            try await waitUntil("the drop") { !session.isConnected }
            // Plain: on a fresh server bob has published no keys, and this is about the resume.
            try session.setEncrypted(false, with: bob)
            let body = "offline \(UUID().uuidString.prefix(6))"
            try session.send(body, to: bob)
            proxy.isRefusing = false

            try await waitUntil("the message to be sent") {
                try session.database.reader.read { try Message.filter(Column("body") == body).fetchOne($0) }?.status ?? .pending >= .sent
            }
            #expect(resumed.withLock { $0 }, "the stream should have been resumed, not started anew")
        }

        // MARK: Drops at a precise point

        /// What happened to a session, in the order it was told.
        private final class Timeline: Sendable {
            enum Event: Equatable, Sendable { case state(XMPPSession.State), resumed }
            private let log = Mutex<[Event]>([])

            var events: [Event] { log.withLock { $0 } }
            var didResume: Bool { events.contains(.resumed) }
            func record(_ event: Event) { log.withLock { $0.append(event) } }
        }

        private func watch(_ session: XMPPSession) -> (Timeline, [AnyObject]) {
            let timeline = Timeline()
            let states = session.state.sink { timeline.record(.state($0)) }
            // Martin's State compares equal whatever `resumed` says, so match the payload.
            let client = session.client.$state.sink { if case .connected(let resumed) = $0, resumed { timeline.record(.resumed) } }
            return (timeline, [states, client])
        }

        /// Each test has a device database of its own, kept across runs: a new device per run
        /// would grow the account's device list, which every sign-in then fetches.
        private static func device(_ name: String) throws -> AppDatabase {
            try OMEMOIntegrationTests.device(name)
        }

        private func proxied(_ proxy: FreezableProxy, device: String, database: AppDatabase? = nil) throws -> XMPPSession {
            try LiveServer.makeSession(alice, resource: "cut-\(UUID().uuidString.prefix(6))", database: try database ?? Self.device(device), port: proxy.port)
        }

        private func stored(_ body: String, in session: XMPPSession) throws -> YapnestKit.Message? {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("body") == body).fetchOne($0) }
        }

        /// A message to a group written while the stream is down goes out
        /// when it is resumed.
        @Test func aGroupMessageStagedOfflineGoesOutAfterAResume() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try proxied(proxy, device: "alice-resume-group")
            let (timeline, watches) = watch(session)
            defer { _ = watches }
            session.connect()
            defer { session.disconnect() }
            try await waitUntil("the session") { session.state.value == .connected(isSyncing: false) }
            try await waitUntil("stream management") { session.client.module(.streamManagement).resumptionEnabled }
            let room = try await session.createGroup(name: "Cut \(UUID().uuidString.prefix(4))", inviting: [])

            proxy.isRefusing = true
            proxy.cut()
            try await waitUntil("the drop") { !session.isConnected }
            let body = "group offline \(UUID().uuidString.prefix(6))"
            try session.send(body, to: room)
            proxy.isRefusing = false

            try await waitUntil("the message to be sent") { (try stored(body, in: session)?.status ?? .pending) >= .sent }
            #expect(timeline.didResume, "the stream should have been resumed, not started anew")
            try await session.leaveGroup(room)
        }

        /// A file chosen while the stream is down is uploaded and sent when
        /// it is resumed.
        @Test func aFileStagedOfflineIsUploadedAndSentAfterAResume() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try proxied(proxy, device: "alice-resume-file")
            let (timeline, watches) = watch(session)
            defer { _ = watches }
            session.connect()
            defer { session.disconnect() }
            try await waitUntil("the session") { session.state.value == .connected(isSyncing: false) }
            try await waitUntil("stream management") { session.client.module(.streamManagement).resumptionEnabled }
            try await LiveServer.requireUpload(of: session)
            try session.setEncrypted(false, with: bob)

            let file = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString.prefix(6)).txt")
            try Data("sent after a resume".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            proxy.isRefusing = true
            proxy.cut()
            try await waitUntil("the drop") { !session.isConnected }
            let message = try await session.sendFile(at: file, to: bob)
            proxy.isRefusing = false

            let id = try #require(message.id)
            try await waitUntil("the file to be sent") {
                try session.database.deliveryStates(ids: [id])[id]?.status ?? .pending >= .sent
            }
            #expect(try session.database.attachment(messageId: id)?.url != nil, "the file should have been uploaded")
            #expect(timeline.didResume, "the stream should have been resumed, not started anew")
        }

        /// A drop in the middle of the catch-up must not be reported as a
        /// finished sync, and the resumed stream finishes it.
        @Test func aDropDuringCatchUpNeverReadsConnectedAndSyncsAfterTheResume() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            // The archive query is the catch-up; its answer never comes.
            proxy.cutWhen(.toServer, sees: "urn:xmpp:mam:2")
            let session = try proxied(proxy, device: "alice-resume-catchup")
            let (timeline, watches) = watch(session)
            defer { _ = watches }
            session.connect()
            defer { session.disconnect() }

            try await waitUntil("the sync to finish after the drop", timeout: 60) {
                timeline.didResume && session.state.value == .connected(isSyncing: false)
            }
            #expect(proxy.firedTriggers == 1)
            let events = timeline.events
            let down = try #require(events.firstIndex { if case .state(.disconnected) = $0 { true } else { false } })
            let resumed = try #require(events.firstIndex(of: .resumed))
            #expect(!events[down..<max(down, resumed)].contains(.state(.connected(isSyncing: false))),
                    "reported connected and synced while the stream was down: \(events)")
        }

        /// A drop before the account's discovery is answered leaves the session
        /// without an archive version; the catch-up must still run after the resume.
        @Test func aDropBeforeDiscoveryAnswersStillCatchesUpAfterTheResume() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            // The answer is lost with the stream.
            proxy.cutWhen(.toClient, sees: "category='account'")
            let session = try proxied(proxy, device: "alice-resume-discovery")
            let (timeline, watches) = watch(session)
            defer { _ = watches }
            session.connect()
            defer { session.disconnect() }

            try await waitUntil("the sync to finish after the drop", timeout: 60) {
                proxy.firedTriggers == 1 && session.state.value == .connected(isSyncing: false)
            }
            // A server without SASL2 (ejabberd) answers discovery before it enables stream
            // management, so there the stream can't be resumed and the next one is new.
            // Either way the catch-up has to run.
            let wasResumable = proxy.serverTrafficAtCut.contains("<enabled")
            #expect(timeline.didResume == wasResumable)
        }

        /// A room whose join the drop cut off is joined again on the resumed stream.
        @Test func aDropDuringAJoinStillJoinsTheRoomAfterTheResume() async throws {
            // A room the account already belongs to, on a database a later session shares.
            let database = try Self.device("alice-resume-join")
            let creator = try LiveServer.makeSession(alice, resource: "join-\(UUID().uuidString.prefix(6))", database: database)
            creator.connect()
            try await waitUntil("the creator") { creator.state.value == .connected(isSyncing: false) }
            let room = try await creator.createGroup(name: "Join \(UUID().uuidString.prefix(4))", inviting: [])
            creator.disconnect()
            try await waitUntil("the creator to leave") { creator.state.value != .connected(isSyncing: false) }

            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            // The join starts with a disco query to the room; the presence it
            // leads to is written after the stream is gone, which Martin drops.
            proxy.cutWhen(.toServer, sees: "to='\(room)'")
            let session = try proxied(proxy, device: "alice-resume-join", database: database)
            let (timeline, watches) = watch(session)
            defer { _ = watches }
            session.connect()
            defer { session.disconnect() }

            try await waitUntil("the room to be joined", timeout: 60) {
                timeline.didResume && session.roomStatus(room)?.isJoined == true
            }
            #expect(proxy.firedTriggers == 1)
            // ejabberd caps the rooms one account can be in, and every later session rejoins the ones left.
            try await session.leaveGroup(room)
        }

        /// What the share extension leaves while the app is catching up is
        /// sent when the catch-up ends, without anyone telling the app.
        @Test func aMessageStagedDuringCatchUpIsSentWhenItEnds() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            // Keeps the catch-up open: the archive's answer is held back.
            proxy.holdServerWhen(.toServer, sees: "urn:xmpp:mam:2")
            let session = try proxied(proxy, device: "alice-resume-hold")
            session.connect()
            defer { session.disconnect() }
            try await waitUntil("the catch-up to start") { proxy.isHolding }
            #expect(session.state.value == .connected(isSyncing: true))
            try session.setEncrypted(false, with: bob)

            let body = "left during the sync \(UUID().uuidString.prefix(6))"
            let staged = try session.outgoingMessages.stage([.text(body)], to: bob)
            let id = try #require(staged[0].id)
            #expect(try session.database.deliveryStates(ids: [id])[id]?.status == .pending)
            proxy.release()

            try await waitUntil("the sync to finish") { session.state.value == .connected(isSyncing: false) }
            try await waitUntil("the message to be sent") {
                try session.database.deliveryStates(ids: [id])[id]?.status ?? .pending >= .sent
            }
        }

        /// Two sweeps for unsent messages in a row, while the first message is
        /// still waiting on the send queue, send it once.
        @Test func twoSweepsBeforeTheQueueRunsSendOnce() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let session = try proxied(proxy, device: "alice-resume-sweeps")
            session.connect()
            defer { session.disconnect() }
            try await waitUntil("the session") { session.state.value == .connected(isSyncing: false) }
            try session.setEncrypted(false, with: bob)

            // Holds the queue, so both sweeps come before the first send is claimed.
            let gate = DispatchSemaphore(value: 0)
            session.sendQueue(for: bob).async { gate.wait() }
            let body = "once \(UUID().uuidString.prefix(6))"
            let staged = try session.outgoingMessages.stage([.text(body)], to: bob)
            session.sendUnclaimedPending()
            session.sendUnclaimedPending()
            gate.signal()

            let dbId = try #require(staged[0].id)
            try await waitUntil("the message to be sent") {
                try session.database.deliveryStates(ids: [dbId])[dbId]?.status ?? .pending >= .sent
            }
            #expect(proxy.clientSent(body) == 1)
        }

        /// A room that keeps no archive never stamps its echoes, so a message
        /// we sent there looks unconfirmed for good. A new session must not
        /// send it into the room again.
        @Test func aRoomWithoutAnArchiveGetsNothingOldAgain() async throws {
            let database = try Self.device("alice-resume-noarchive")
            let bobSession = try LiveServer.makeSession(bob, resource: "noarchive-bob", database: try Self.device("bob-resume-noarchive"))
            let first = try LiveServer.makeSession(alice, resource: "noarchive-1", database: database)
            for session in [first, bobSession] {
                session.connect()
                try await waitUntil("\(session.account) to connect") { session.state.value == .connected(isSyncing: false) }
            }
            defer { first.disconnect(); bobSession.disconnect() }
            first.addContact(bob)
            bobSession.addContact(alice)
            try await waitUntil("each other in the roster") { try first.database.isInRoster(bob) && bobSession.database.isInRoster(alice) }

            let room = try await first.createGroup(name: "Bare \(UUID().uuidString.prefix(4))", inviting: [bob])
            try await waitUntil("bob to join") { bobSession.roomStatus(room)?.isJoined == true }
            // Plain, so the proxy can see the bodies go by.
            try first.setEncrypted(false, with: room)
            let turnedOffLogging = try await first.disableArchive(of: room)
            let offersArchive = try await first.roomOffersArchive(room)
            // Openfire's MUC service lists the archive for every room, logged or not.
            if turnedOffLogging && offersArchive { try Test.cancel("\(LiveServer.target.name) still advertises an archive for a room whose logging is off") }
            try #require(!offersArchive, "the room still keeps an archive")

            let old = "sent before \(UUID().uuidString.prefix(6))"
            try first.send(old, to: room)
            try await waitUntil("the message to be sent") { (try stored(old, in: first)?.status ?? .pending) >= .sent }
            try await waitUntil("bob to get it") { try stored(old, in: bobSession) != nil }
            first.disconnect()

            // Two new sessions, each of which must leave the room alone.
            for visit in 1...2 {
                let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
                defer { proxy.stop() }
                let session = try proxied(proxy, device: "alice-resume-noarchive", database: database)
                session.connect()
                defer { session.disconnect() }
                try await waitUntil("visit \(visit) to join the room") {
                    session.roomStatus(room)?.isJoined == true && session.roomStatus(room)?.isSyncing == false
                }
                // The room's queue is in order: whatever the visit resends comes before this.
                let marker = "marker \(visit) \(UUID().uuidString.prefix(6))"
                try session.send(marker, to: room)
                try await waitUntil("the marker to be written") { proxy.clientSent(marker) > 0 }
                #expect(proxy.clientSent(old) == 0, "visit \(visit) sent the old message into the room again")
                if visit == 2 {
                    try await session.leaveGroup(room)
                    try await bobSession.leaveGroup(room)
                }
            }
        }

        /// An address anyone can put in an invitation must not become a room.
        @Test func aDirectInvitationToNoRoomCreatesNothing() async throws {
            let a = try LiveServer.makeSession(alice, resource: "inv-a", database: try Self.device("alice-resume-invite"))
            let b = try LiveServer.makeSession(bob, resource: "inv-b", database: try Self.device("bob-resume-invite"))
            for session in [a, b] {
                session.connect()
                try await waitUntil("\(session.account) to connect") { session.state.value == .connected(isSyncing: false) }
            }
            defer { a.disconnect(); b.disconnect() }
            a.addContact(bob)
            b.addContact(alice)
            try await waitUntil("each other in the roster") { try a.database.isInRoster(bob) && b.database.isInRoster(alice) }

            let room = JID("nobody-\(UUID().uuidString.prefix(8).lowercased())@\(LiveServer.target.conference)")!
            let invitation = Martin.Message()
            invitation.to = Martin.JID(alice.martin)
            let x = Element(name: "x", xmlns: NS.conference)
            x.setAttribute("jid", value: room.description)
            invitation.addChild(x)
            b.write(invitation)

            try await Task.sleep(for: .seconds(4))
            #expect(try a.database.groupChat(room) == nil)
            #expect(a.roomStatus(room) == nil)
            // Joining would have created it on the server.
            let exists = (try? await a.client.module(.disco).info(for: Martin.JID(room.martin), node: nil)) != nil
            #expect(!exists)
        }
    }
}
