import Foundation
import GRDB
import Synchronization
import Testing
@testable import YapnestKit
import MartinOMEMO

extension LiveServer {
    /// Guards the fixes Vendor/README.md lists for MartinOMEMO, through
    /// YapnestKit's API only, so they would catch a regression from a later
    /// switch or merge of the library. Every device here is new (its database
    /// is in memory, its resource unique), unlike `OMEMOIntegrationTests`,
    /// which keeps its devices between runs and so only meets registration
    /// after a server reset.
    /// `YAPNEST_INTEGRATION=1 swift test --filter OMEMORegressionIntegration`;
    /// `YAPNEST_OMEMO_ROUNDS` sets the rounds of the first test (10).
    @Suite
    struct OMEMORegressionIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")
        let carol = LiveServer.jid("carol")

        // MARK: Helpers

        /// A brand-new device: nothing of it exists on the server or anywhere else.
        private func newDevice(_ jid: JID, _ name: String, port: Int = LiveServer.target.port) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "\(name)-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: port)
        }

        /// Until `session` has heard of `other`'s device, or has no list for
        /// the account and so fetches a fresh one when it sends.
        private func awaitAnnouncement(of other: XMPPSession, at session: XMPPSession) async throws {
            let device = Int32(bitPattern: other.omemoDeviceId)
            try await LiveServer.waitUntil("\(session.account) to hear of \(other.account)'s device") {
                let known = session.announcedDevices(of: other.account)
                return known.isEmpty ? other.account != session.account : known.contains(device)
            }
        }

        private func message(_ body: String, in session: XMPPSession) throws -> YapnestKit.Message? {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("body") == body).fetchOne($0) }
        }

        private func undecryptable(in session: XMPPSession) throws -> Int {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("encryption") == YapnestKit.Message.Encryption.omemoUndecryptable.rawValue).fetchCount($0) }
        }

        private func incomingCount(in session: XMPPSession) throws -> Int {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("direction") == YapnestKit.Message.Direction.incoming.rawValue).fetchCount($0) }
        }

        /// Takes `a` and `b` out of each other's rosters, so neither hears the
        /// other's device list by notification and each is a stranger to the other.
        private func makeStrangers(_ a: JID, _ b: JID) async throws {
            let first = try newDevice(a, "strangers-1"), second = try newDevice(b, "strangers-2")
            try await LiveServer.connected(first, second, timeout: 60)
            defer { first.disconnect(); second.disconnect() }
            for (one, other) in [(first, b), (second, a)] where try one.database.isInRoster(other) { try? await one.removeContact(other) }
            try await LiveServer.waitUntil("\(a) and \(b) to leave each other's rosters") {
                try !first.database.isInRoster(b) && !second.database.isInRoster(a)
            }
        }

        private func sentOverTheWire(_ body: String, by session: XMPPSession) throws {
            try #require(true)
        }

        /// The devices this run has left on each account, to take out again: with
        /// every run the lists would grow, and with them what each first message
        /// is encrypted for and every other suite's sign-ins.
        private static let leftOver = Mutex<[JID: [Int32]]>([:])

        /// Signs `sessions` out for good, and has a device of each account's
        /// remove them, and the ones earlier tests left, from its list. Does
        /// nothing for a test that failed before it: the next reset clears those.
        private func retire(_ sessions: XMPPSession...) async {
            for session in sessions {
                session.disconnect()
                Self.leftOver.withLock { $0[session.account, default: []].append(Int32(bitPattern: session.omemoDeviceId)) }
            }
            for account in Set(sessions.map(\.account)) {
                guard let janitor = try? newDevice(account, "janitor") else { continue }
                janitor.connect()
                try? await LiveServer.waitUntil("the janitor to sign in", timeout: 20) { janitor.state.value == .connected(isSyncing: false) && janitor.isEncryptionReady }
                let own = Int32(bitPattern: janitor.omemoDeviceId)
                let gone = Self.leftOver.withLock { $0.updateValue([own], forKey: account) ?? [] }
                try? await LiveServer.waitUntil("the janitor to hear of the devices", timeout: 5) {
                    let known = Set(janitor.devices(of: account).map(\.id))
                    return gone.allSatisfy(known.contains)
                }
                let devices = janitor.devices(of: account).filter { gone.contains($0.id) }
                if !devices.isEmpty { try? await janitor.removeOwnDevices(devices) }
                janitor.disconnect()
            }
        }

        // MARK: First messages

        /// The races between a new device's two publishes, and the reading of
        /// device lists that were still being written, made the first message to
        /// a new device fail about one run in four.
        @Test func firstMessageToBrandNewDevicesDecrypts() async throws {
            let rounds = ProcessInfo.processInfo.environment["YAPNEST_OMEMO_ROUNDS"].flatMap { Int($0) } ?? 10
            var previous: (a: XMPPSession, b: XMPPSession)?
            defer { previous?.a.disconnect(); previous?.b.disconnect() }

            for round in 1...rounds {
                let a = try newDevice(alice, "fresh-a"), b = try newDevice(bob, "fresh-b")
                try await LiveServer.connected(a, b, encryptionReady: true, timeout: 60)
                try await awaitAnnouncement(of: b, at: a)
                try await awaitAnnouncement(of: a, at: b)
                // A new device also reads the account's archive, where earlier
                // messages for other devices can't be decrypted; only new ones count.
                let unreadable = try [a, b].map { try undecryptable(in: $0) }
                // Alternates, so each direction is the first one in half the rounds.
                let (first, second, firstTo, secondTo) = round.isMultiple(of: 2) ? (b, a, alice, bob) : (a, b, bob, alice)

                let hello = "first \(round) \(UUID().uuidString.prefix(8))"
                let sent = try first.send(hello, to: firstTo)
                #expect(sent.encryption == .omemo, "round \(round): sent in the clear")
                try await LiveServer.waitUntil("round \(round): \(second.account) to receive the first message") { try message(hello, in: second) != nil }
                let received = try message(hello, in: second)
                #expect(received?.encryption == .omemo, "round \(round): the first message to a new device came as \(String(describing: received?.encryption))")
                #expect(received?.body == hello)

                let reply = "reply \(round) \(UUID().uuidString.prefix(8))"
                try second.send(reply, to: secondTo)
                try await LiveServer.waitUntil("round \(round): \(first.account) to receive the reply") { try message(reply, in: first) != nil }
                #expect(try message(reply, in: first)?.encryption == .omemo, "round \(round): the reply was not decrypted")

                for (session, before) in zip([a, b], unreadable) {
                    #expect(try undecryptable(in: session) == before, "round \(round): \(session.account) has a message it couldn't decrypt")
                }

                // The accounts' lists would otherwise grow with every device, and with
                // them the keys each next first message is encrypted for.
                if let old = previous {
                    old.a.disconnect(); old.b.disconnect()
                    for (session, gone) in [(a, old.a), (b, old.b)] {
                        if let device = session.devices(of: session.account).first(where: { $0.id == Int32(bitPattern: gone.omemoDeviceId) }) {
                            try? await session.removeOwnDevices([device])
                        }
                    }
                }
                previous = (a, b)
            }
            if let last = previous { previous = nil; await retire(last.a, last.b) }
        }

        // MARK: A refused publish

        /// A key publish that never gets an answer, because the link drops,
        /// is made again; a device whose keys aren't published never registers.
        @Test func aRefusedBundlePublishIsRetried() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            // The publish is swallowed, as is the answer to it, with the stream.
            proxy.cutWhen(.toServer, sees: "<publish node='eu.siacs.conversations.axolotl.bundles:")
            let a = try newDevice(alice, "bundle-cut", port: proxy.port), b = try newDevice(bob, "bundle-peer")
            a.connect()
            defer { a.disconnect(); b.disconnect() }

            try await LiveServer.waitUntil("the cut", timeout: 60) { proxy.firedTriggers == 1 }
            try await LiveServer.waitUntil("the device to publish its keys after the cut", timeout: 40) { a.state.value == .connected(isSyncing: false) && a.isEncryptionReady }
            #expect(a.isEncryptionReady)
            #expect(proxy.firedTriggers == 1)
            // It was made again, on the stream that was resumed rather than on a new one,
            // which is where nothing would start it but the registration retry.
            #expect(proxy.clientSent("<resume") >= 1, "the stream was not resumed, so this is not the case the retry is for")
            #expect(proxy.clientSent("<publish node='eu.siacs.conversations.axolotl.bundles:") >= 2, "the keys were not published again")

            // Registered for real: a contact can encrypt to it, and it decrypts.
            try await LiveServer.connected(b, encryptionReady: true, timeout: 60)
            let text = "after a lost publish \(UUID().uuidString.prefix(8))"
            try await LiveServer.waitUntil("bob to know the device") { b.announcedDevices(of: alice).isEmpty || b.announcedDevices(of: alice).contains(Int32(bitPattern: a.omemoDeviceId)) }
            let sent = try b.send(text, to: alice)
            #expect(sent.encryption == .omemo)
            try await LiveServer.waitUntil("the new device to decrypt") { try message(text, in: a)?.encryption == .omemo }
            #expect(try message(text, in: a)?.body == text)
            await retire(a, b)
        }

        // MARK: Strangers

        /// Openfire kept its own presence-based access model for the device list
        /// and keys unless told again afterwards. Elsewhere this just holds.
        @Test func aStrangerCanReadOurDeviceList() async throws {
            try await makeStrangers(alice, carol)
            let a = try newDevice(alice, "known-list"), c = try newDevice(carol, "stranger")
            try await LiveServer.connected(a, c, encryptionReady: true, timeout: 60)
            defer { a.disconnect(); c.disconnect() }
            #expect(try !a.database.isInRoster(carol) && !c.database.isInRoster(alice), "they are not strangers")

            let text = "from a stranger \(UUID().uuidString.prefix(8))"
            let sent = try c.send(text, to: alice)
            #expect(sent.encryption == .omemo)
            try await LiveServer.waitUntil("alice to decrypt a stranger's message") { try message(text, in: a) != nil }
            #expect(try message(text, in: a)?.encryption == .omemo)
            let failed = try message(text, in: c)
            #expect(failed?.status != .failed, "the send failed: \(failed?.error ?? "no reason")")
            await retire(a, c)
        }

        // MARK: One fetch per burst

        /// Device lists that don't come by notification are fetched again for
        /// every message unless remembered.
        @Test func aBurstToAContactFetchesTheirListOnce() async throws {
            try await makeStrangers(alice, carol)
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try newDevice(alice, "burst", port: proxy.port), c = try newDevice(carol, "burst-peer")
            try await LiveServer.connected(a, c, encryptionReady: true, timeout: 60)
            defer { a.disconnect(); c.disconnect() }
            #expect(a.announcedDevices(of: carol).isEmpty, "the list came by notification")

            let before = Self.listFetches(of: carol, in: proxy)
            let bodies = (1...5).map { "burst \($0) \(UUID().uuidString.prefix(6))" }
            for body in bodies { try a.send(body, to: carol) }
            try await LiveServer.waitUntil("the burst to be sent") { try bodies.allSatisfy { (try message($0, in: a)?.status ?? .pending) >= .sent } }
            try await LiveServer.waitUntil("carol to decrypt the burst") { try bodies.allSatisfy { try message($0, in: c)?.encryption == .omemo } }

            let fetches = Self.listFetches(of: carol, in: proxy) - before
            #expect(fetches >= 1, "no fetch was seen, so this proves nothing")
            #expect(fetches <= 1, "carol's device list was fetched \(fetches) times for five messages")
            await retire(a, c)
        }

        /// Queries for `jid`'s device list that the client has written.
        private static func listFetches(of jid: JID, in proxy: FreezableProxy) -> Int {
            proxy.clientTraffic.replacingOccurrences(of: "\"", with: "'").components(separatedBy: "<iq").filter {
                $0.contains("to='\(jid)'") && $0.contains("<items") && $0.contains("node='eu.siacs.conversations.axolotl.devicelist'")
            }.count
        }

        // MARK: Repair

        /// Messages that arrive in a session the receiver lost are not
        /// decryptable; one empty message per device sets it up again, after the
        /// archive sync rather than once per message in it.
        @Test func aBrokenSessionIsRepairedOnceAfterSync() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try newDevice(alice, "heal-a"), b = try newDevice(bob, "heal-b", port: proxy.port)
            try await LiveServer.connected(a, b, encryptionReady: true, timeout: 60)
            try await awaitAnnouncement(of: b, at: a)
            try await awaitAnnouncement(of: a, at: b)
            defer { a.disconnect(); b.disconnect() }

            // Both directions, so the sessions are settled and a sends ordinary messages.
            let hello = "hello \(UUID().uuidString.prefix(8))", back = "back \(UUID().uuidString.prefix(8))"
            try a.send(hello, to: bob)
            try await LiveServer.waitUntil("bob to decrypt") { try message(hello, in: b)?.encryption == .omemo }
            try b.send(back, to: alice)
            try await LiveServer.waitUntil("alice to decrypt") { try message(back, in: a)?.encryption == .omemo }

            b.disconnect()
            try await LiveServer.waitUntil("bob to leave") { !b.isConnected }
            // Until the server has seen bob go, it hands alice's messages to his old stream and
            // they reach him only from the archive. After, it keeps them as offline messages and
            // delivers them live on his next sign-in, ahead of the archive.
            try await Task.sleep(for: .seconds(2))
            let aDevice = SignalAddress(name: alice.description, deviceId: Int32(bitPattern: a.omemoDeviceId))
            #expect(b.omemoStoreForTesting.containsSessionRecord(forAddress: aDevice))
            #expect(b.omemoStoreForTesting.deleteSessionRecord(forAddress: aDevice))

            let missed = (1...5).map { "missed \($0) \(UUID().uuidString.prefix(6))" }
            for body in missed { try a.send(body, to: bob) }
            try await LiveServer.waitUntil("alice's messages to be sent") { try missed.allSatisfy { (try message($0, in: a)?.status ?? .pending) >= .sent } }
            let incoming = try incomingCount(in: b)
            let sessionAfterSending = a.omemoStoreForTesting.sessionRecord(forAddress: SignalAddress(name: bob.description, deviceId: Int32(bitPattern: b.omemoDeviceId)))
            let repairsBefore = Self.keyTransports(sentBy: proxy)

            try await LiveServer.connected(b, encryptionReady: true, timeout: 60)
            // They can't be read, so they are rows without their text.
            try await LiveServer.waitUntil("bob to have the messages") { try incomingCount(in: b) >= incoming + missed.count }
            // The repair is a key transport to alice's device, which replaces her session.
            try await LiveServer.waitUntil("alice to take the repaired session", timeout: 40) {
                a.omemoStoreForTesting.sessionRecord(forAddress: SignalAddress(name: bob.description, deviceId: Int32(bitPattern: b.omemoDeviceId))) != sessionAfterSending
            }

            let later = "after the repair \(UUID().uuidString.prefix(8))"
            try a.send(later, to: bob)
            try await LiveServer.waitUntil("bob to decrypt a message after the repair") { try message(later, in: b)?.encryption == .omemo }
            #expect(try message(later, in: b)?.body == later)
            let repairs = Self.keyTransports(sentBy: proxy) - repairsBefore
            #expect(repairs == 1, "bob sent \(repairs) repair messages for one broken session")
            await retire(a, b)
        }

        /// Encrypted messages without a payload, which is what a repair sends.
        private static func keyTransports(sentBy proxy: FreezableProxy) -> Int {
            proxy.clientTraffic.replacingOccurrences(of: "\"", with: "'").components(separatedBy: "<message").filter {
                $0.contains("<encrypted") && !$0.contains("<payload")
            }.count
        }
    }
}
