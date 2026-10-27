import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

private let alice = YapnestKit.JID("alice@example.org")!
private let aliceDevice = "alice@example.org/phone"
private let omemoNamespace = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification"
private let plainNamespace = "urn:xmpp:jingle:apps:dtls:0"

/// The `<fingerprint>` of a transport as Conversations sends it in a
/// `session-initiate` or `session-accept`. Reconstructed from its source
/// (codeberg.org/iNPUTmice/Conversations, `AxolotlService.encrypt(IceUdpTransportInfo, …)`
/// builds the wrapper and `XmppAxolotlMessage.toElement()` the OMEMO message):
/// the wrapper takes `hash` and `setup` from the plain fingerprint, and holds
/// the legacy OMEMO message with one `<key>` for the receiving device, whose
/// payload is the fingerprint text. Dino's `dtls_srtp_verification_draft.vala`
/// writes and reads the same layout.
private let conversationsFingerprint = """
<fingerprint xmlns='http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification' hash='sha-256' setup='actpass'>\
<encrypted xmlns='eu.siacs.conversations.axolotl'>\
<header sid='1234'><key rid='5678'>MwohBVjZuV7ahpEB</key><iv>AAECAwQFBgcICQoL</iv></header>\
<payload>sdQwKFzXQ0GHNvnMg1h1</payload>\
</encrypted></fingerprint>
"""

/// Stands for OMEMO, so what the call does with the keys is tested without
/// two devices that have sessions with each other.
private final class FakeCipher: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(fingerprint: String, peer: YapnestKit.JID, device: Int32)] = []
    var encryptResult: Result<Element, CallFingerprintError> = .success(Element.from(string: conversationsFingerprint)!.firstChild(name: "encrypted")!)
    var opened: Result<CallFingerprintCipher.Opened, CallFingerprintError> = .success(.init(fingerprint: "AB:CD:EF:01:23:45:67:89", device: 7, trust: .trusted))
    private var received = 0

    var encrypted: [(fingerprint: String, peer: YapnestKit.JID, device: Int32)] { lock.withLock { sent } }
    var decrypted: Int { lock.withLock { received } }

    var cipher: CallFingerprintCipher {
        CallFingerprintCipher(
            encrypt: { [self] fingerprint, peer, device in
                lock.withLock { sent.append((fingerprint, peer, device)) }
                return encryptResult
            },
            decrypt: { [self] _, _ in
                lock.withLock { received += 1 }
                return opened
            },
        )
    }
}

private func wrapped(_ iq: String) -> String {
    iq.replacingOccurrences(
        of: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89</fingerprint>",
        with: conversationsFingerprint,
    )
}

private func wrappedAccept(_ iq: String) -> String {
    iq.replacingOccurrences(
        of: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='active'>12:34:56:78</fingerprint>",
        with: conversationsFingerprint.replacingOccurrences(of: "setup='actpass'", with: "setup='active'"),
    )
}

private func fingerprints(in iq: Iq) -> [Element] {
    CallFingerprints.transports(in: iq.firstChild(name: "jingle")!).flatMap { $0.children.filter { $0.name == "fingerprint" } }
}

struct CallFingerprintsTests {
    private func jingle(_ transports: String...) -> Element {
        let contents = transports.enumerated().map {
            "<content creator='initiator' name='\($0.offset)'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='u' pwd='p'>\($0.element)</transport></content>"
        }.joined()
        return Element.from(string: "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='s'>\(contents)</jingle>")!
    }

    private let plain = "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD</fingerprint>"

    @Test func anEncryptedFingerprintIsPutBackInPlainForm() throws {
        let fake = FakeCipher()
        let element = jingle(conversationsFingerprint)
        let result = CallFingerprints.open(element, from: alice, with: fake.cipher)
        #expect(result == .success(.encrypted(device: 7, trust: .trusted)))
        let transport = try #require(CallFingerprints.transports(in: element).first)
        #expect(transport.firstChild(name: "fingerprint", xmlns: omemoNamespace) == nil)
        let restored = try #require(transport.firstChild(name: "fingerprint", xmlns: plainNamespace))
        #expect(restored.value == "AB:CD:EF:01:23:45:67:89")
        #expect(restored.getAttribute("hash") == "sha-256")
        #expect(restored.getAttribute("setup") == "actpass")
        // And Martin reads it as the fingerprint of the media.
        let transportElement = try #require(CallFingerprints.transports(in: element).first)
        let martin = try #require(Jingle.Transport.ICEUDPTransport(from: transportElement))
        #expect(martin.fingerprint?.value == "AB:CD:EF:01:23:45:67:89")
    }

    @Test func aPlainFingerprintIsLeftAlone() {
        let fake = FakeCipher()
        let element = jingle(plain)
        #expect(CallFingerprints.open(element, from: alice, with: fake.cipher) == .success(.plain))
        #expect(fake.decrypted == 0)
        #expect(CallFingerprints.transports(in: element).first?.firstChild(name: "fingerprint", xmlns: plainNamespace)?.value == "AB:CD")
    }

    @Test func aMixOfPlainAndEncryptedIsRefused() {
        let fake = FakeCipher()
        #expect(CallFingerprints.open(jingle(conversationsFingerprint, plain), from: alice, with: fake.cipher) == .failure(.malformed))
        #expect(CallFingerprints.open(jingle(plain, conversationsFingerprint), from: alice, with: fake.cipher) == .failure(.malformed))
    }

    @Test func bothFormsInOneTransportAreRefused() {
        let fake = FakeCipher()
        #expect(CallFingerprints.open(jingle(plain + conversationsFingerprint), from: alice, with: fake.cipher) == .failure(.malformed))
        #expect(fake.decrypted == 0)
    }

    @Test func twoEncryptedFingerprintsInOneTransportAreRefused() {
        let fake = FakeCipher()
        #expect(CallFingerprints.open(jingle(conversationsFingerprint + conversationsFingerprint), from: alice, with: fake.cipher) == .failure(.malformed))
    }

    @Test func aWrapperWithoutOrWithTwoMessagesIsRefused() {
        let fake = FakeCipher()
        let empty = "<fingerprint xmlns='\(omemoNamespace)' hash='sha-256' setup='actpass'/>"
        #expect(CallFingerprints.open(jingle(empty), from: alice, with: fake.cipher) == .failure(.malformed))
        let twice = conversationsFingerprint.replacingOccurrences(of: "</fingerprint>", with: "<encrypted xmlns='eu.siacs.conversations.axolotl'/></fingerprint>")
        #expect(CallFingerprints.open(jingle(twice), from: alice, with: fake.cipher) == .failure(.malformed))
    }

    @Test func aMessageThatDoesntDecryptIsRefused() {
        let fake = FakeCipher()
        fake.opened = .failure(.undecryptable)
        let element = jingle(conversationsFingerprint)
        #expect(CallFingerprints.open(element, from: alice, with: fake.cipher) == .failure(.undecryptable))
        // Nothing is left to be taken for a fingerprint.
        #expect(CallFingerprints.transports(in: element).first?.firstChild(name: "fingerprint", xmlns: plainNamespace) == nil)
    }

    @Test func contentsFromDifferentDevicesAreRefused() {
        final class Alternating: @unchecked Sendable {
            var next: Int32 = 7
        }
        let alternating = Alternating()
        let cipher = CallFingerprintCipher(
            encrypt: { _, _, _ in .failure(.noSession) },
            decrypt: { _, _ in
                defer { alternating.next += 1 }
                return .success(.init(fingerprint: "AB", device: alternating.next, trust: .verified))
            },
        )
        #expect(CallFingerprints.open(jingle(conversationsFingerprint, conversationsFingerprint), from: alice, with: cipher) == .failure(.wrongDevice))
    }

    @Test func plainFingerprintsAreWrappedForTheDeviceInTheConversationsLayout() async throws {
        let fake = FakeCipher()
        let element = jingle(plain, plain)
        let failure = await CallFingerprints.encrypt(element, to: alice, device: 5678, with: fake.cipher)
        #expect(failure == nil)
        #expect(fake.encrypted.map(\.device) == [5678, 5678])
        #expect(fake.encrypted.map(\.fingerprint) == ["AB:CD", "AB:CD"])
        for transport in CallFingerprints.transports(in: element) {
            #expect(transport.firstChild(name: "fingerprint", xmlns: plainNamespace) == nil)
            let wrapper = try #require(transport.firstChild(name: "fingerprint", xmlns: omemoNamespace))
            #expect(wrapper.getAttribute("hash") == "sha-256")
            #expect(wrapper.getAttribute("setup") == "actpass")
            #expect(wrapper.value == nil)
            let message = try #require(wrapper.firstChild(name: "encrypted", xmlns: "eu.siacs.conversations.axolotl"))
            #expect(message.firstChild(name: "header")?.getAttribute("sid") == "1234")
        }
    }

    @Test func aFingerprintThatCantBeEncryptedSaysWhy() async {
        let fake = FakeCipher()
        fake.encryptResult = .failure(.compromisedDevice)
        #expect(await CallFingerprints.encrypt(jingle(plain), to: alice, device: 1, with: fake.cipher) == .compromisedDevice)
    }

    @Test func aProceedNamesTheDeviceAsConversationsWritesIt() throws {
        let proceed = OutboundStanza.call(.proceed(to: aliceDevice), sid: "s1", omemoDevice: 4242)
        let element = try #require(proceed.firstChild(name: "proceed", xmlns: "urn:xmpp:jingle-message:0"))
        #expect(element.firstChild(name: "device", xmlns: omemoNamespace)?.getAttribute("id") == "4242")
        #expect(CallFingerprints.device(in: element) == 4242)
        let without = OutboundStanza.call(.proceed(to: aliceDevice), sid: "s1")
        #expect(without.firstChild(name: "proceed")?.firstChild(name: "device") == nil)
        let other = OutboundStanza.call(.accept(to: "me@example.org"), sid: "s1", omemoDevice: 4242)
        #expect(other.firstChild(name: "accept")?.firstChild(name: "device") == nil)
    }

    @Test func aProceedFromConversationsGivesItsDevice() throws {
        let xml = "<message from='\(aliceDevice)' to='me@example.org/phone' type='chat' id='j'><proceed xmlns='urn:xmpp:jingle-message:0' id='s1'><device xmlns='\(omemoNamespace)' id='4242'/></proceed></message>"
        let stanza: Martin.Message = parseStanza(xml)
        let signal = try #require(CallSignal(stanza, account: YapnestKit.JID("me@example.org")!, source: .live))
        #expect(signal.omemoDevice == 4242)
        let plain: Martin.Message = parseStanza("<message from='\(aliceDevice)' to='me@example.org/phone' type='chat' id='j'><proceed xmlns='urn:xmpp:jingle-message:0' id='s1'/></message>")
        #expect(CallSignal(plain, account: YapnestKit.JID("me@example.org")!, source: .live)?.omemoDevice == nil)
    }
}

struct CallVerificationSessionTests {
    private func secured(_ h: CallSessionHarness) throws -> FakeCipher {
        let fake = FakeCipher()
        h.session.callCipherForTesting = fake.cipher
        return fake
    }

    private func answered(_ h: CallSessionHarness) async throws {
        h.receive(h.propose())
        h.session.answerCall()
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
    }

    private func calling(_ h: CallSessionHarness, device: Int32? = 7) async throws -> String {
        try h.session.startCall(to: alice)
        let sid = try #require(h.session.callState.value?.sid)
        let inner = device.map { "<device xmlns='\(omemoNamespace)' id='\($0)'/>" } ?? ""
        h.receive(h.jmi("proceed", sid: sid, inner: inner))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        return sid
    }

    private func terminatedForSecurity(_ h: CallSessionHarness) -> Bool {
        h.jingleIqs("session-terminate").contains { $0.firstChild(name: "jingle")?.firstChild(name: "reason")?.firstChild(name: "security-error") != nil }
    }

    // MARK: Incoming

    @Test func anEncryptedFingerprintVerifiesTheCallAndTheAnswerIsEncryptedToItsDevice() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        try await answered(h)
        try h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .trusted)
        let media = try #require(h.factory.last)
        await eventually("the answer") { !h.jingleIqs("session-accept").isEmpty }
        // The media got the decrypted fingerprint, to check the handshake against.
        #expect(media.answeredOffers.first?.contains("a=fingerprint:sha-256 AB:CD:EF:01:23:45:67:89") == true)
        // Our answer is for the device that vouched for the call.
        #expect(fake.encrypted.map(\.device) == [7])
        #expect(fake.encrypted.first?.peer == alice)
        let accept = try #require(h.jingleIqs("session-accept").first)
        let sent = fingerprints(in: accept)
        #expect(sent.count == 1)
        #expect(sent.first?.xmlns == omemoNamespace)
        #expect(sent.first?.getAttribute("setup") == "active")
        #expect(sent.first?.firstChild(name: "encrypted", xmlns: "eu.siacs.conversations.axolotl") != nil)
        #expect(!accept.element.stringValue.contains("urn:xmpp:jingle:apps:dtls:0"))
    }

    @Test func aVerifiedDeviceShowsTheCallAsVerified() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        fake.opened = .success(.init(fingerprint: "AB:CD", device: 7, trust: .verified))
        try await answered(h)
        try h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(h.session.callState.value?.verification == .verified)
    }

    @Test func aDeviceWeHaveNotDecidedOnDoesNotVerifyTheCall() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        fake.opened = .success(.init(fingerprint: "AB:CD", device: 7, trust: .undecided))
        try await answered(h)
        try h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .unverified)
        // It is still answered in kind, as the caller expects it.
        await eventually("the answer") { !h.jingleIqs("session-accept").isEmpty }
        #expect(fingerprints(in: try #require(h.jingleIqs("session-accept").first)).first?.xmlns == omemoNamespace)
    }

    @Test func aPlainFingerprintStillMakesACallThatIsUnverified() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        try await answered(h)
        try h.receive(iq: h.sessionInitiate())
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .unverified)
        await eventually("the answer") { !h.jingleIqs("session-accept").isEmpty }
        #expect(fake.encrypted.isEmpty)
        #expect(fingerprints(in: try #require(h.jingleIqs("session-accept").first)).first?.xmlns == plainNamespace)
        #expect(h.factory.last?.answeredOffers.first?.contains("a=fingerprint:sha-256 AB:CD:EF:01:23:45:67:89") == true)
    }

    @Test func anEncryptedFingerprintThatDoesntDecryptEndsTheCallWithAnError() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        fake.opened = .failure(.undecryptable)
        try await answered(h)
        try h.receive(iq: wrapped(h.sessionInitiate()))
        #expect(h.phase == .ended(.failed))
        await eventually("the session to be ended") { terminatedForSecurity(h) }
        // Never taken for a plain fingerprint: the media was not given the offer.
        #expect(h.factory.last?.answeredOffers.isEmpty == true)
        #expect(h.jingleIqs("session-accept").isEmpty)
        #expect(h.session.warnings.current.contains { $0.key == "call-verification" })
    }

    @Test func aTamperedMessageFailsTheCallThroughTheRealCipher() async throws {
        let h = try CallSessionHarness()
        try await answered(h)
        let tampered = conversationsFingerprint.replacingOccurrences(of: "rid='5678'", with: "rid='\(h.session.omemoDeviceId)'")
        try h.receive(iq: h.sessionInitiate().replacingOccurrences(
            of: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89</fingerprint>", with: tampered,
        ))
        #expect(h.phase == .ended(.failed))
        #expect(h.factory.last?.answeredOffers.isEmpty == true)
        #expect(h.session.warnings.current.contains { $0.key == "call-verification" })
    }

    @Test func aCompromisedDeviceCantVerifyACall() async throws {
        let h = try CallSessionHarness()
        try h.database.addOMEMODeviceForFixture(of: alice, id: 1234, keyByte: 9, firstSeen: Date(), lastUsed: nil)
        let address = SignalAddress(name: alice.description, deviceId: 1234)
        _ = h.session.omemoStoreForTesting.setStatus(.compromisedActive, forIdentity: address)
        try await answered(h)
        let valid = conversationsFingerprint.replacingOccurrences(of: "rid='5678'", with: "rid='\(h.session.omemoDeviceId)'")
        try h.receive(iq: h.sessionInitiate().replacingOccurrences(
            of: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>AB:CD:EF:01:23:45:67:89</fingerprint>", with: valid,
        ))
        #expect(h.phase == .ended(.failed))
        #expect(h.factory.last?.answeredOffers.isEmpty == true)
        let warning = try #require(h.session.warnings.current.first { $0.key == "call-verification" })
        #expect(warning.detail.contains("blocked"))
    }

    @Test func aFingerprintFromADeviceOtherThanTheCallersSessionIsNotRead() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        try await answered(h)
        #expect(throws: (any Error).self) { try h.receive(iq: wrapped(h.sessionInitiate(from: "alice@example.org/other"))) }
        #expect(fake.decrypted == 0)
        #expect(h.phase == .accepted)
    }

    @Test func aMixOfEncryptedAndPlainContentsEndsTheCall() async throws {
        let h = try CallSessionHarness()
        _ = try secured(h)
        try await answered(h)
        let mixed = wrapped(h.sessionInitiate()).replacingOccurrences(
            of: "</transport>", with: "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='actpass'>EE:EE</fingerprint></transport>",
        )
        try h.receive(iq: mixed)
        #expect(h.phase == .ended(.failed))
    }

    // MARK: Outgoing

    @Test func aProceedWithADeviceHasTheOfferEncryptedToIt() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        let sid = try await calling(h)
        #expect(fake.encrypted.map(\.device) == [7])
        #expect(fake.encrypted.first?.peer == alice)
        #expect(fake.encrypted.first?.fingerprint == "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99")
        let sent = fingerprints(in: try #require(h.jingleIqs("session-initiate").first))
        #expect(sent.count == 1)
        #expect(sent.first?.xmlns == omemoNamespace)
        #expect(sent.first?.getAttribute("setup") == "actpass")
        let text = h.jingleIqs("session-initiate").first?.element.stringValue ?? ""
        #expect(!text.contains("urn:xmpp:jingle:apps:dtls:0"))

        // The answer from that device, encrypted, is what verifies the call.
        try h.receive(iq: wrappedAccept(h.sessionAccept(sid: sid)))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .trusted)
        await eventually("the answer to reach the media") { h.factory.last?.answersSet.count == 1 }
        #expect(h.factory.last?.answersSet.first?.contains("a=fingerprint:sha-256 AB:CD:EF:01:23:45:67:89") == true)
    }

    @Test func aProceedWithoutADeviceGetsAPlainOffer() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        let sid = try await calling(h, device: nil)
        #expect(fake.encrypted.isEmpty)
        #expect(fingerprints(in: try #require(h.jingleIqs("session-initiate").first)).first?.xmlns == plainNamespace)
        try h.receive(iq: h.sessionAccept(sid: sid))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .unverified)
    }

    @Test func anOfferThatCantBeEncryptedGoesOutPlainAndTheCallIsUnverified() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        fake.encryptResult = .failure(.noSession)
        let sid = try await calling(h)
        #expect(fingerprints(in: try #require(h.jingleIqs("session-initiate").first)).first?.xmlns == plainNamespace)
        try h.receive(iq: h.sessionAccept(sid: sid))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .unverified)
    }

    @Test func anOfferInAChatThatIsntEncryptedGoesOutPlain() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        try h.database.setEncrypted(false, with: alice)
        _ = try await calling(h)
        #expect(fake.encrypted.isEmpty)
        #expect(fingerprints(in: try #require(h.jingleIqs("session-initiate").first)).first?.xmlns == plainNamespace)
    }

    @Test func aPlainAnswerToAnEncryptedOfferEndsTheCall() async throws {
        let h = try CallSessionHarness()
        _ = try secured(h)
        let sid = try await calling(h)
        try h.receive(iq: h.sessionAccept(sid: sid))
        #expect(h.phase == .ended(.failed))
        await eventually("the session to be ended") { terminatedForSecurity(h) }
        #expect(h.factory.last?.answersSet.isEmpty == true)
        #expect(h.session.warnings.current.contains { $0.key == "call-verification" })
    }

    @Test func anAnswerFromAnotherDeviceThanTheOneNamedEndsTheCall() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        let sid = try await calling(h)
        fake.opened = .success(.init(fingerprint: "AB:CD", device: 9, trust: .verified))
        try h.receive(iq: wrappedAccept(h.sessionAccept(sid: sid)))
        #expect(h.phase == .ended(.failed))
        #expect(h.factory.last?.answersSet.isEmpty == true)
    }

    @Test func anAnswerThatDoesntDecryptEndsTheCall() async throws {
        let h = try CallSessionHarness()
        let fake = try secured(h)
        let sid = try await calling(h)
        fake.opened = .failure(.undecryptable)
        try h.receive(iq: wrappedAccept(h.sessionAccept(sid: sid)))
        #expect(h.phase == .ended(.failed))
        #expect(h.factory.last?.answersSet.isEmpty == true)
    }

    @Test func anEncryptedAnswerToAPlainOfferIsStillRead() async throws {
        let h = try CallSessionHarness()
        _ = try secured(h)
        let sid = try await calling(h, device: nil)
        try h.receive(iq: wrappedAccept(h.sessionAccept(sid: sid)))
        #expect(h.phase == .connecting)
        #expect(h.session.callState.value?.verification == .trusted)
    }
}
