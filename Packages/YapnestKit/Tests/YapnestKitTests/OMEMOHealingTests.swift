import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

/// Records the bundle fetches that session repair starts, and never answers.
private final class BundleFetchWriter: PacketWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String] = []
    var fetched: [String] { lock.withLock { nodes } }
    /// Answers every fetch with an error, as a device without a bundle would.
    var failsFetches = false

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {
        if let node = iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.attribute("node") {
            lock.withLock { nodes.append(node) }
            if failsFetches, let failure = errorDecoder(nil) as? Failure { completionHandler?(.failure(failure)) }
        }
    }
    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

struct OMEMOHealingTests {
    let me = JID("me@example.org")!
    let bob = "bob@example.org"

    private func setUp() throws -> (OMEMOEncryption, BundleFetchWriter, XMPPClient) {
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me)
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        let writer = BundleFetchWriter()
        client.writer = writer
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        return (encryption, writer, client)
    }

    /// A well-formed Signal message (version 3, a ratchet key, counters, a
    /// ciphertext and a MAC) for a session nobody has, so decrypting it fails
    /// with `noSession` rather than as malformed.
    static let whisperMessage: Data = {
        var bytes: [UInt8] = [0x33, 0x0a, 0x21, 0x05] + Array(repeating: 9, count: 32)
        bytes += [0x10, 0x01, 0x18, 0x00, 0x22, 0x10] + Array(repeating: 4, count: 16)
        return Data(bytes + Array(repeating: 5, count: 8))
    }()

    /// A message from `device` of Bob's for us, in a session we don't have.
    private func undecryptable(from device: Int32, to encryption: OMEMOEncryption) -> Martin.Message {
        let message = Message()
        message.type = .chat
        message.from = Martin.JID(bob)
        let encrypted = Element(name: "encrypted", xmlns: OMEMOModule.XMLNS)
        let header = Element(name: "header")
        header.attribute("sid", newValue: String(device))
        let key = Element(name: "key", cdata: Self.whisperMessage.base64EncodedString())
        key.attribute("rid", newValue: String(encryption.deviceId))
        header.addChild(key)
        header.addChild(Element(name: "iv", cdata: Data(repeating: 2, count: 12).base64EncodedString()))
        encrypted.addChild(header)
        encrypted.addChild(Element(name: "payload", cdata: Data(repeating: 3, count: 8).base64EncodedString()))
        message.addChild(encrypted)
        return message
    }

    private func decryptFailures(_ count: Int, from device: Int32, _ encryption: OMEMOEncryption) {
        for _ in 0..<count {
        _ = encryption.decrypt(undecryptable(from: device, to: encryption), from: JID(bob)!, ownCopy: false)
        }
    }

    @Test func repairWaitsForTheArchiveAndRunsOncePerDevice() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        encryption.module.mamSyncStarted(for: nil)
        decryptFailures(5, from: 7, encryption)
        decryptFailures(2, from: 8, encryption)
        #expect(writer.fetched.isEmpty, "repair is held back while the archive syncs")

        encryption.module.mamSyncFinished(for: nil)
        #expect(Set(writer.fetched) == [bundleNode(7), bundleNode(8)])
        #expect(writer.fetched.count == 2, "each device is repaired once")
    }

    /// A server that stored a burst while we were away delivers it live, before
    /// any sync holds repairs back; the archive then repeats it.
    @Test func aBurstOutsideASyncAndTheArchiveAfterItRepairOnce() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        decryptFailures(5, from: 7, encryption)
        decryptFailures(1, from: 8, encryption)
        #expect(Set(writer.fetched) == [bundleNode(7), bundleNode(8)])
        #expect(writer.fetched.count == 2, "each device is repaired once")

        encryption.module.mamSyncStarted(for: nil)
        decryptFailures(5, from: 7, encryption)
        encryption.module.mamSyncFinished(for: nil)
        #expect(writer.fetched.count == 2, "the archive's copies started no second repair")
    }

    @Test func aRepairThatFailsDoesNotBlockTheNextOne() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        writer.failsFetches = true
        decryptFailures(1, from: 7, encryption)
        // The claim is given up on the module's own queue.
        encryption.module.mamSyncStarted(for: nil)
        encryption.module.mamSyncFinished(for: nil)
        decryptFailures(1, from: 7, encryption)
        #expect(writer.fetched.count == 2, "the failed repair left the device open to another")
    }

    /// A message from the same device that decrypts while its repair is still
    /// fetching the bundle must not reopen the device to a second repair.
    @Test func aDecryptDuringARepairDoesNotStartAnother() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        decryptFailures(1, from: 7, encryption)
        #expect(writer.fetched.count == 1)

        encryption.module.sessionWorksForTesting(SignalAddress(name: bob, deviceId: 7))
        decryptFailures(1, from: 7, encryption)
        #expect(writer.fetched.count == 1, "the repair under way still holds the device")
    }

    /// A repair that ended in failure gave its claim up, and a working session
    /// afterwards doesn't change that.
    @Test func aDecryptAfterAFailedRepairLeavesTheDeviceOpen() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        writer.failsFetches = true
        decryptFailures(1, from: 7, encryption)
        encryption.module.sessionWorksForTesting(SignalAddress(name: bob, deviceId: 7))
        encryption.module.mamSyncStarted(for: nil)
        encryption.module.mamSyncFinished(for: nil)
        decryptFailures(1, from: 7, encryption)
        #expect(writer.fetched.count == 2)
    }

    @Test func aResetForgetsWhatWasRepaired() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        decryptFailures(2, from: 7, encryption)
        encryption.module.reset(scopes: [.session])
        decryptFailures(2, from: 7, encryption)
        #expect(writer.fetched.count == 2)
    }

    @Test func repairIsImmediateOutsideASync() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        decryptFailures(1, from: 7, encryption)
        #expect(writer.fetched.count == 1)
    }

    @Test func historyNeverStartsRepair() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        _ = encryption.decrypt(undecryptable(from: 7, to: encryption), from: JID(bob)!, ownCopy: false, isHistory: true)
        #expect(writer.fetched.isEmpty)
    }

    @Test func aSyncCutShortByDisconnectingDoesNotHoldBackRepair() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        encryption.module.mamSyncStarted(for: nil)
        decryptFailures(2, from: 7, encryption)
        encryption.module.reset(scopes: [.stream])
        decryptFailures(1, from: 8, encryption)
        #expect(writer.fetched == [bundleNode(8)], "the dropped sync's repairs are forgotten, and later ones aren't held")
    }

    @Test func aRoomSyncHoldsBackItsOwnRepairOnly() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        let room = BareJID("room@muc.example.org")!
        encryption.module.mamSyncStarted(for: room)
        // A one-to-one message isn't part of the room's archive.
        decryptFailures(1, from: 7, encryption)
        #expect(writer.fetched.count == 1)
        encryption.module.mamSyncFinished(for: room)
    }

    /// Stands in for a message that would decrypt: a compromised device must be
    /// refused before decoding, which for an unknown session shows as a repair.
    @Test func compromisedDeviceIsRefusedBeforeDecoding() throws {
        let (encryption, writer, client) = try setUp()
        defer { withExtendedLifetime(client) {} }
        for device: Int32 in [7, 8] {
            _ = encryption.store.save(identity: SignalAddress(name: bob, deviceId: device), publicKeyData: Data([0x05] + Array(repeating: UInt8(device), count: 32)))
        }
        let compromised = SignalAddress(name: bob, deviceId: 7)
        let status = try #require(encryption.store.identities(forName: bob).first { $0.address.deviceId == 7 }?.status)
        _ = encryption.store.setStatus(status.toTrust(.compromised), forIdentity: compromised)

        guard case .failed(let reason) = encryption.decrypt(undecryptable(from: 7, to: encryption), from: JID(bob)!, ownCopy: false) else {
            Issue.record("a compromised device's message was not refused")
            return
        }
        #expect(reason.contains("compromised"))
        #expect(writer.fetched.isEmpty, "a refused message starts no session repair")

        // Another device of the same contact is still handed to the decoder.
        guard case .failed(let other) = encryption.decrypt(undecryptable(from: 8, to: encryption), from: JID(bob)!, ownCopy: false) else {
            Issue.record("expected the stand-in message to fail to decrypt")
            return
        }
        #expect(!other.contains("compromised"))
        #expect(writer.fetched == [bundleNode(8)])
    }
}

private func bundleNode(_ device: Int32) -> String { "eu.siacs.conversations.axolotl.bundles:\(device)" }
