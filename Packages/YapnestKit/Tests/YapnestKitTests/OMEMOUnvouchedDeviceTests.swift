import Foundation
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// A device met through a room whose sender's server won't vouch for it is
/// never trusted on the room's word, whatever happens to its message.
struct OMEMOUnvouchedDeviceTests {
    /// `alice` receives a first message of `bob`'s, a prekey message.
    private func firstMessage() throws -> (alice: OMEMOPeer, bob: OMEMOPeer, stanza: Martin.Message) {
        let alice = try OMEMOPeer("alice@example.org"), bob = try OMEMOPeer("bob@example.org")
        _ = try startSession(from: bob.omemo, to: alice.omemo, named: alice.account.description)
        let encrypted = try #require(bob.send("hello", to: alice))
        let stanza = Martin.Message()
        stanza.type = .groupchat
        stanza.addChild(encrypted)
        return (alice, bob, stanza)
    }

    private func status(of bob: OMEMOPeer, at alice: OMEMOPeer) -> IdentityStatus? {
        alice.omemo.store.status(forName: bob.account.description, deviceId: bob.device)
    }

    @Test func aRoomsNewDeviceIsUndecidedWhenItsMessageIsRead() throws {
        let (alice, bob, stanza) = try firstMessage()
        guard case .decrypted(let device, let trust) = alice.omemo.decrypt(stanza, from: bob.account, ownCopy: false, claim: .roomUnchecked) else {
            Issue.record("not decrypted")
            return
        }
        #expect(device == bob.device)
        #expect(trust == .undecided)
        #expect(status(of: bob, at: alice) == .undecidedActive)
        #expect(stanza.body == "hello")
    }

    @Test func aRoomsNewDeviceIsUndecidedEvenWhenItsPayloadFails() throws {
        let (alice, bob, stanza) = try firstMessage()
        let encrypted = try #require(stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy))
        let payload = try #require(encrypted.firstChild(name: "payload"))
        payload.value = Data((0..<40).map { UInt8(truncatingIfNeeded: $0 &* 11) }).base64EncodedString()
        guard case .failed = alice.omemo.decrypt(stanza, from: bob.account, ownCopy: false, claim: .roomUnchecked) else {
            Issue.record("the payload was read")
            return
        }
        #expect(status(of: bob, at: alice) == .undecidedActive)
    }

    @Test func aDeviceNamedByItsOwnStanzaIsStillTrustedOnFirstUse() throws {
        let (alice, bob, stanza) = try firstMessage()
        guard case .decrypted(_, let trust) = alice.omemo.decrypt(stanza, from: bob.account, ownCopy: false, claim: .stanza) else {
            Issue.record("not decrypted")
            return
        }
        #expect(trust == .trusted)
        #expect(status(of: bob, at: alice) == .trustedActive)
    }

    @Test func onlyTheAddressInTheScopeIsAdmittedUndecided() throws {
        let store = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: JID("me@example.org")!, identityKeys: MemoryIdentityKeyStore()).store
        let key = Data([0x05] + Array(repeating: 1, count: 32))
        let inScope = SignalAddress(name: "bob@example.org", deviceId: 1), other = SignalAddress(name: "bob@example.org", deviceId: 2)
        store.admittingUndecided(inScope) {
            #expect(store.save(identity: other, publicKeyData: key))
            #expect(store.save(identity: inScope, publicKeyData: key))
        }
        #expect(store.status(forName: "bob@example.org", deviceId: 1) == .undecidedActive)
        #expect(store.status(forName: "bob@example.org", deviceId: 2) == .trustedActive)
        let later = SignalAddress(name: "bob@example.org", deviceId: 3)
        #expect(store.save(identity: later, publicKeyData: key))
        #expect(store.status(forName: "bob@example.org", deviceId: 3) == .trustedActive, "the scope ended")
    }
}
