import Foundation
import GRDB
import Testing
@testable import YapnestKit
import MartinOMEMO

extension LiveServer {
    /// OMEMO between Yapnest sessions on the local dev server (`YAPNEST_SERVER`). Enable with
    /// `YAPNEST_INTEGRATION=1 swift test --filter OMEMOIntegration`.
    @Suite
    struct OMEMOIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// A device's database, kept across runs so the accounts' published
        /// device lists don't fill up with one-off test devices.
        static func device(_ name: String) throws -> AppDatabase {
            let dir = LiveServer.stateDirectory
            return try AppDatabase.open(at: dir.appending(path: "\(name).sqlite"))
        }

        private func session(_ jid: JID, device: String) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: device, database: try Self.device(device), attachments: AttachmentStore(directory: LiveServer.stateDirectory.appending(path: "\(device)-attachments")))
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try await !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        /// Connects the devices and waits until each has heard the others
        /// announce themselves: until then, they don't encrypt for each other.
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
                        // Without a cached list, sending fetches a fresh one.
                        let known = session.announcedDevices(of: other.account)
                        return known.isEmpty ? other.account != session.account : known.contains(device)
                    }
                }
            }
        }

        private func message(_ body: String, in session: XMPPSession) throws -> Message? {
            try session.database.reader.read { try Message.filter(Column("body") == body).fetchOne($0) }
        }

        @Test func encryptedMessageReplyAndReaction() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }

            let text = "secret \(UUID().uuidString.prefix(8))"
            let sent = try a.send(text, to: bob)
            #expect(sent.encryption == .omemo)

            var received: Message?
            try await waitUntil("bob to decrypt") {
                received = try message(text, in: b)
                return received != nil
            }
            let mine = try message(text, in: a)
            let theirs = try await b.database.reader.read { try Message.order(Column("id").desc).fetchOne($0) }
            let bobDevice = SignalAddress(name: bob.description, deviceId: Int32(bitPattern: b.omemoDeviceId))
            let state = """
                alice's copy: \(String(describing: mine?.status)); bob's last: \(String(describing: theirs?.encryption)); \
                alice has a session with bob's device \(bobDevice.deviceId): \(a.omemoStoreForTesting.containsSessionRecord(forAddress: bobDevice)); \
                alice knows bob's devices: \(a.announcedDevices(of: bob))
                """
            let original = try #require(received, "\(state)")
            #expect(original.encryption == .omemo)
            #expect(original.remoteId == sent.remoteId)
            try await waitUntil("alice's message to be sent") { try message(text, in: a)?.status ?? .pending >= .sent }

            // The reply's quote fallback is inside the ciphertext; it must still be stripped.
            let reply = "encrypted yes \(UUID().uuidString.prefix(8))"
            try b.send(reply, to: alice, replyingTo: original)
            try b.toggleReaction("🔐", on: original, peer: alice)
            try await waitUntil("alice to decrypt the reply") {
                try message(reply, in: a).map { $0.replyToId == sent.remoteId && $0.encryption == .omemo } ?? false
            }
            try await waitUntil("alice to get the reaction") { try a.database.reactions(on: sent, from: bob) == ["🔐"] }
        }

        @Test func messagesCarryDeviceTrust() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }

            let text = "trust \(UUID().uuidString.prefix(8))"
            try a.send(text, to: bob)
            var received: Message?
            try await waitUntil("bob to decrypt") {
                received = try message(text, in: b)
                return received != nil
            }
            #expect(received?.omemoDevice == Int32(bitPattern: a.omemoStoreForTesting.localRegistrationId()))
            #expect(received?.omemoTrust == .trusted)
            try await waitUntil("alice's copy to record recipient trust") { try message(text, in: a)?.omemoTrust == .trusted }

            // Verifying the device re-stamps what it sent; put trust back afterwards.
            let before = b.devices(of: alice)
            defer { for device in before { b.setTrust(device.trust, for: device) } }
            let device = try #require(before.first { $0.id == received?.omemoDevice })
            b.setTrust(.verified, for: device)
            #expect(try message(text, in: b)?.omemoTrust == .verified)
        }

        /// The first message from a device that appeared after the contact was
        /// verified must not look ordinary: it is undecided from its very first
        /// message, not only from the next.
        @Test func firstMessageFromANewDeviceOfAVerifiedContactIsUndecided() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            let before = a.devices(of: bob)
            let verified = try #require(before.first { $0.id == Int32(bitPattern: b.omemoDeviceId) })
            defer { for device in before { a.setTrust(device.trust, for: device) } }
            a.setTrust(.verified, for: verified)

            // A fresh store is a device the contact has never been seen with.
            let newDevice = try session(bob, device: "bob-new-\(UUID().uuidString.prefix(6))")
            try await connected(a, newDevice)
            defer { newDevice.disconnect() }

            let text = "new device \(UUID().uuidString.prefix(8))"
            try newDevice.send(text, to: alice)
            var received: Message?
            try await waitUntil("alice to decrypt") {
                received = try message(text, in: a)
                return received != nil
            }
            #expect(received?.omemoDevice == Int32(bitPattern: newDevice.omemoDeviceId))
            #expect(received?.omemoTrust == .undecided)
        }

        @Test func encryptedPhotoIsDownloadedAndDecrypted() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.requireUpload(of: a)
            a.addContact(bob)
            b.addContact(alice)
            try await waitUntil("bob to have alice in his roster") { try b.database.isInRoster(alice) }

            let file = FileManager.default.temporaryDirectory.appending(path: "yapnest-\(UUID().uuidString).jpg")
            try LinkPreviewerTests.jpeg(width: 3000, height: 2000).write(to: file)
            let sent = try await a.sendFile(at: file, asPhoto: true, to: bob)

            var url: String?
            try await waitUntil("alice to upload and send") {
                url = try a.database.attachment(messageId: sent.id!)?.url
                return try url != nil && (message(url!, in: a)?.status ?? .pending) >= .sent
            }
            #expect(url?.hasPrefix("aesgcm://") == true)

            // Alice is in bob's roster, so the photo downloads on its own.
            var received: YapnestKit.Attachment?
            try await waitUntil("bob to download the photo", timeout: 20) {
                guard let message = try message(url!, in: b) else { return false }
                received = try b.database.attachment(messageId: message.id!)
                return received?.state == .ready
            }
            let mine = try #require(try a.database.attachment(messageId: sent.id!))
            let theirs = try #require(received)
            #expect(theirs.imageSize == CGSize(width: 2048, height: 1365))
            let sentFile = try #require(a.attachments.url(for: mine)), receivedFile = try #require(b.attachments.url(for: theirs))
            #expect(try Data(contentsOf: receivedFile) == Data(contentsOf: sentFile))
        }

        /// A photo sent in a chat that isn't encrypted tells the receiver its
        /// shape and gives it a preview before anything is downloaded.
        @Test func plaintextPhotoAnnouncesItsShape() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connected(a, b)
            try a.setEncrypted(false, with: bob)
            defer { try? a.setEncrypted(true, with: bob); a.disconnect(); b.disconnect() }
            try await LiveServer.requireUpload(of: a)
            // Photos from the roster download on their own, which drops the preview.
            try await b.removeContact(alice)
            try await waitUntil("bob to drop alice from his roster") { try !b.database.isInRoster(alice) }

            let file = FileManager.default.temporaryDirectory.appending(path: "yapnest-\(UUID().uuidString).jpg")
            try LinkPreviewerTests.jpeg(width: 3000, height: 2000).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let sent = try await a.sendFile(at: file, asPhoto: true, to: bob)

            var url: String?
            try await waitUntil("alice to upload") {
                url = try a.database.attachment(messageId: sent.id!)?.url
                return url != nil
            }
            #expect(url?.hasPrefix(LiveServer.target.uploadPrefix) == true)
            var received: YapnestKit.Attachment?
            try await waitUntil("bob to get the photo") {
                received = try message(url!, in: b).flatMap { try b.database.attachment(messageId: $0.id!) }
                return received != nil
            }
            #expect(received?.state == .remote)
            #expect(received?.imageSize == CGSize(width: 2048, height: 1365))
            #expect(received?.thumbnail != nil)
            #expect(received?.size == (try a.database.attachment(messageId: sent.id!)?.size))
        }

        @Test func plaintextFileWaitsForTap() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connected(a, b)
            try a.setEncrypted(false, with: bob)
            defer { try? a.setEncrypted(true, with: bob); a.disconnect(); b.disconnect() }
            try await LiveServer.requireUpload(of: a)

            let contents = Data("meeting notes \(UUID())".utf8)
            let file = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString.prefix(6)).txt")
            try contents.write(to: file)
            let sent = try await a.sendFile(at: file, to: bob)

            var url: String?
            try await waitUntil("alice to upload") {
                url = try a.database.attachment(messageId: sent.id!)?.url
                return url != nil
            }
            #expect(url?.hasPrefix(LiveServer.target.uploadPrefix) == true)

            var received: YapnestKit.Attachment?
            try await waitUntil("bob to get the file") {
                received = try message(url!, in: b).flatMap { try b.database.attachment(messageId: $0.id!) }
                return received != nil
            }
            #expect(received?.state == .remote)
            b.download(try #require(received))
            try await waitUntil("bob to download") {
                received = try b.database.attachment(messageId: received!.messageId)
                return received?.state == .ready
            }
            let downloaded = try #require(received.flatMap(b.attachments.url(for:)))
            #expect(try Data(contentsOf: downloaded) == contents)
        }

        @Test func otherDeviceReadsBothDirections() async throws {
            let a1 = try session(alice, device: "alice-1"), a2 = try session(alice, device: "alice-2"), b = try session(bob, device: "bob-1")
            try await connected(a1, a2, b)
            defer { a1.disconnect(); a2.disconnect(); b.disconnect() }

            // a1 encrypts for our own other devices too, so a2 can read the carbon.
            let mine = "from alice-1 \(UUID().uuidString.prefix(8))"
            try a1.send(mine, to: bob)
            try await waitUntil("alice-2 to decrypt the sent carbon") {
                try message(mine, in: a2).map { $0.direction == .outgoing && $0.encryption == .omemo } ?? false
            }

            let theirs = "to both \(UUID().uuidString.prefix(8))"
            try b.send(theirs, to: alice)
            try await waitUntil("alice-1 to decrypt") { try message(theirs, in: a1)?.encryption == .omemo }
            try await waitUntil("alice-2 to decrypt") { try message(theirs, in: a2)?.encryption == .omemo }
        }

        @Test func offlineDeviceDecryptsFromArchive() async throws {
            let b = try session(bob, device: "bob-1")
            try await connected(b)
            b.disconnect()

            let a = try session(alice, device: "alice-1")
            try await connected(a)
            defer { a.disconnect() }
            let text = "while you were out \(UUID().uuidString.prefix(8))"
            try a.send(text, to: bob)
            try await waitUntil("alice's message to be sent") { try message(text, in: a)?.status ?? .pending >= .sent }

            let back = try session(bob, device: "bob-1")
            try await connected(back)
            defer { back.disconnect() }
            try await waitUntil("bob to decrypt from the archive") { try message(text, in: back)?.encryption == .omemo }
        }

        /// Our own encrypted messages come back from the archive unreadable to
        /// us; they must still count as delivered to the server, not be resent.
        @Test func ownEncryptedMessageConfirmedByArchive() async throws {
            let a = try session(alice, device: "alice-1")
            try await connected(a)
            let text = "confirm me \(UUID().uuidString.prefix(8))"
            try a.send(text, to: bob)
            try await waitUntil("alice's message to be sent") { try message(text, in: a)?.status ?? .pending >= .sent }
            a.disconnect()

            let again = try session(alice, device: "alice-1")
            try await connected(again)
            defer { again.disconnect() }
            let confirmed = try #require(try message(text, in: again))
            #expect(confirmed.serverId != nil)
        }

        @Test func peerWithoutOMEMOFailsWithReason() async throws {
            let a = try session(alice, device: "alice-1")
            try await connected(a)
            defer { a.disconnect() }
            let nobody = JID("nobody-\(UUID().uuidString.prefix(6).lowercased())@localhost")!
            let text = "unencryptable \(UUID().uuidString.prefix(8))"
            try a.send(text, to: nobody)
            try await waitUntil("the send to fail") { try message(text, in: a)?.status == .failed }
            let failed = try #require(try message(text, in: a))
            #expect(failed.error?.contains("can't receive encrypted messages") == true)
        }

        // MARK: Device usage

        private func usage(of device: UInt32, in session: XMPPSession, of jid: JID) -> OMEMODevice? {
            session.devices(of: jid).first { $0.id == Int32(bitPattern: device) }
        }

        @Test func lastUseIsRecordedForContactsAndOurOwnDevices() async throws {
            let a1 = try session(alice, device: "alice-1"), a2 = try session(alice, device: "alice-2"), b = try session(bob, device: "bob-1")
            try await connected(a1, a2, b)
            defer { a1.disconnect(); a2.disconnect(); b.disconnect() }

            let text = "last used \(UUID().uuidString.prefix(8))"
            try a1.send(text, to: bob)
            try await waitUntil("bob and alice-2 to decrypt") {
                try message(text, in: b)?.encryption == .omemo && message(text, in: a2)?.encryption == .omemo
            }
            let seenByBob = try #require(usage(of: a1.omemoDeviceId, in: b, of: alice))
            let seenByAlice2 = try #require(usage(of: a1.omemoDeviceId, in: a2, of: alice))
            for seen in [seenByBob, seenByAlice2] {
                let lastUsed = try #require(seen.lastUsed)
                #expect(abs(lastUsed.timeIntervalSinceNow) < 60)
                #expect(!seen.isInactive())
            }
        }

        /// Makes `session` think `device` of `jid` has been silent for `days`.
        private func makeQuiet(_ device: UInt32, of jid: JID, in session: XMPPSession, days: Double) throws {
            let then = Date().addingTimeInterval(-days * 86400)
            try session.database.writer.write { db in
                try db.execute(sql: "UPDATE omemoIdentity SET firstSeen = ?, lastUsed = ? WHERE name = ? AND deviceId = ?",
                               arguments: [then, then, jid.description, Int32(bitPattern: device)])
            }
        }

        @Test func aQuietDeviceStopsGettingMessagesUntilItSendsOne() async throws {
            let a = try session(alice, device: "alice-1"), b1 = try session(bob, device: "bob-1"), b2 = try session(bob, device: "bob-2")
            try await connected(a, b1, b2)
            defer { a.disconnect(); b1.disconnect(); b2.disconnect() }

            // Both must be known and fresh first.
            let warmup = "warm up \(UUID().uuidString.prefix(8))"
            try a.send(warmup, to: bob)
            try await waitUntil("both of bob's devices to decrypt") {
                try message(warmup, in: b1)?.encryption == .omemo && message(warmup, in: b2)?.encryption == .omemo
            }
            try makeQuiet(b1.omemoDeviceId, of: bob, in: a, days: 100)
            let device = try #require(usage(of: b1.omemoDeviceId, in: a, of: bob))
            #expect(device.isInactive())

            let skipped = "not for the old one \(UUID().uuidString.prefix(8))"
            try a.send(skipped, to: bob)
            try await waitUntil("bob-2 to decrypt") { try message(skipped, in: b2)?.encryption == .omemo }
            try await Task.sleep(for: .seconds(1))
            #expect(try message(skipped, in: b1)?.encryption != .omemo, "an inactive device was encrypted to")

            // It speaks, so it is active and gets the next one.
            let hello = "I'm still here \(UUID().uuidString.prefix(8))"
            try b1.send(hello, to: alice)
            try await waitUntil("alice to hear bob-1") { try message(hello, in: a) != nil }
            #expect(try #require(usage(of: b1.omemoDeviceId, in: a, of: bob)).isInactive() == false)
            let back = "welcome back \(UUID().uuidString.prefix(8))"
            try a.send(back, to: bob)
            try await waitUntil("bob-1 to decrypt again") { try message(back, in: b1)?.encryption == .omemo }
        }

        @Test func aRemovedDeviceLeavesThePublishedListAndAddsItselfBackWhenItReconnects() async throws {
            let a1 = try session(alice, device: "alice-1"), a2 = try session(alice, device: "alice-2"), b = try session(bob, device: "bob-1")
            try await connected(a1, a2, b)
            defer { a1.disconnect(); a2.disconnect(); b.disconnect() }
            // Bob only hears alice's device list as her contact; on a freshly
            // reset server nothing else has made them contacts.
            try await LiveServer.befriend(a1, b)
            let removed = Int32(bitPattern: a2.omemoDeviceId)
            let own = Int32(bitPattern: a1.omemoDeviceId)

            // Off, or it would put itself back the moment the new list reached it.
            a2.disconnect()
            let device = try #require(usage(of: a2.omemoDeviceId, in: a1, of: alice))
            try await a1.removeOwnDevices([device])

            #expect(a1.devices(of: alice).allSatisfy { $0.id != removed }, "it's still listed here")
            #expect(!a1.omemoStoreForTesting.allDevices(for: alice.description, activeAndTrusted: true).contains(removed))
            try await waitUntil("bob to hear the new list") {
                let known = b.announcedDevices(of: alice)
                return !known.isEmpty && !known.contains(removed) && known.contains(own)
            }

            // Bob no longer encrypts to it: this one has no key for alice-2.
            let text = "after removal \(UUID().uuidString.prefix(8))"
            try b.send(text, to: alice)
            try await waitUntil("alice-1 to decrypt") { try message(text, in: a1)?.encryption == .omemo }

            // Back in use, it puts itself back.
            a2.connect()
            try await waitUntil("alice-2 to publish itself again") {
                a2.state.value == .connected(isSyncing: false) && a2.isEncryptionReady && b.announcedDevices(of: alice).contains(removed)
            }
            try await waitUntil("alice-1 to meet it again") { usage(of: a2.omemoDeviceId, in: a1, of: alice) != nil }
        }

        @Test func aDeviceRemovedWhileConnectedAddsItselfBackWithItsBundleAndIsLeftBe() async throws {
            let a1 = try session(alice, device: "alice-1"), a2 = try session(alice, device: "alice-2")
            try await connected(a1, a2)
            defer { a1.disconnect(); a2.disconnect() }
            let removed = Int32(bitPattern: a2.omemoDeviceId)
            let publishesBefore = a1.omemoModuleForTesting.deviceListPublishes + a2.omemoModuleForTesting.deviceListPublishes

            let device = try #require(usage(of: a2.omemoDeviceId, in: a1, of: alice))
            try await a1.removeOwnDevices([device])

            // It sees itself missing and lists itself again, with a bundle:
            // this device can only start a session with it from that.
            let address = SignalAddress(name: alice.description, deviceId: removed)
            try await waitUntil("alice-2 to list itself again with its bundle") {
                a1.announcedDevices(of: alice).contains(removed) && a1.omemoStoreForTesting.containsSessionRecord(forAddress: address)
            }

            // And nobody fights over it afterwards.
            let settled = a1.omemoModuleForTesting.deviceListPublishes + a2.omemoModuleForTesting.deviceListPublishes
            try await Task.sleep(for: .seconds(30))
            let publishes = a1.omemoModuleForTesting.deviceListPublishes + a2.omemoModuleForTesting.deviceListPublishes
            #expect(publishes - settled == 0, "the list kept being rewritten: \(publishes - settled) publishes in 30 s")
            #expect(settled - publishesBefore <= 4, "\(settled - publishesBefore) publishes to settle")
            #expect(a1.announcedDevices(of: alice).contains(removed), "it was removed again")
            #expect(a2.announcedDevices(of: alice).contains(removed))
        }
    }
}
