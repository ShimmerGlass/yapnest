import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let alice = YapnestKit.JID("alice@example.org")!
private let warningKey = "call-verification"

/// Never answers, as a server that has stopped talking.
private final class SilentWriter: PacketWriter, @unchecked Sendable {
    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
}

/// What a stanza the call won't take, or a call that can't be verified, may
/// and may not do.
struct CallVerificationHardeningTests {
    private func secured(_ h: CallSessionHarness) -> FakeCipher {
        let fake = FakeCipher()
        h.session.callCipherForTesting = fake.cipher
        return fake
    }

    private func answered(_ h: CallSessionHarness) async {
        h.receive(h.propose())
        h.session.answerCall()
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
    }

    private func proceeded(_ h: CallSessionHarness) async throws -> String {
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid, inner: "<device xmlns='\(omemoNamespace)' id='7'/>"))
        return sid
    }

    @Test func anEncryptedInitiateAfterAPlainOneWasTakenCantVerifyTheCall() async throws {
        let h = try CallSessionHarness()
        let fake = secured(h)
        await answered(h)
        try h.receive(iq: h.sessionInitiate())
        #expect(h.phase == .connecting)
        // What a server in the middle would forward next: the real, encrypted one.
        try? h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(fake.decrypted == 0)
        #expect(h.session.callState.value?.verification == .unverified)
        #expect(h.phase == .connecting)
        #expect(!h.session.warnings.current.contains { $0.key == warningKey })
        await eventually("the answer") { !h.jingleIqs("session-accept").isEmpty }
        #expect(fake.encrypted.isEmpty)
        #expect(fingerprints(in: try #require(h.jingleIqs("session-accept").first)).first?.xmlns == plainNamespace)
    }

    @Test func aRetransmittedEncryptedInitiateChangesNothing() async throws {
        let h = try CallSessionHarness()
        let fake = secured(h)
        await answered(h)
        try h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(h.session.callState.value?.verification == .trusted)
        // The second copy would not decrypt, as OMEMO refuses a message twice.
        fake.opened = .failure(.undecryptable)
        try? h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .trusted)
        #expect(!h.session.warnings.current.contains { $0.key == warningKey })
        #expect(fake.decrypted == 1)
    }

    @Test func aRetransmittedEncryptedAnswerChangesNothing() async throws {
        let h = try CallSessionHarness()
        let fake = secured(h)
        let sid = try await proceeded(h)
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        try h.receive(iq: wrappedAccept(h.sessionAccept(sid: sid)))
        #expect(h.session.callState.value?.verification == .trusted)
        fake.opened = .failure(.undecryptable)
        try? h.receive(iq: wrappedAccept(h.sessionAccept(sid: sid)))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .trusted)
        #expect(!h.session.warnings.current.contains { $0.key == warningKey })
    }

    @Test func aCompromisedDeviceEndsAnOutgoingCallInsteadOfGoingPlain() async throws {
        let h = try CallSessionHarness()
        let fake = secured(h)
        fake.encryptResult = .failure(.compromisedDevice)
        _ = try await proceeded(h)
        await eventually("the call to end") { h.phase == .ended(.failed) }
        #expect(h.jingleIqs("session-initiate").isEmpty)
        #expect(h.session.warnings.current.contains { $0.key == warningKey })
    }

    @Test func waitingForTheDeviceListGivesUpQuicklyAndSaysSo() async throws {
        let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: YapnestKit.JID("me@example.org")!, identityKeys: MemoryIdentityKeyStore())
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("me@example.org")
        client.writer = SilentWriter()
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        defer { withExtendedLifetime(client) {} }
        encryption.setupTimeout = 30
        encryption.callFetchTimeout = 0.3
        let start = Date()
        let result = await encryption.encryptCallFingerprint("AB:CD", to: alice, device: 7)
        guard case .failure(let error) = result else {
            Issue.record("Expected a failure")
            return
        }
        #expect(error == .setupFailed)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
