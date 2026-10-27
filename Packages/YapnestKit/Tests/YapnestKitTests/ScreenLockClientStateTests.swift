import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!

/// The Mac says it is inactive while its screen is locked, and nothing else changes.
struct ScreenLockClientStateTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
        // The session only takes features that offer TLS or arrive over it.
        let features: Stanza = parseStanza("<features xmlns='http://etherx.jabber.org/streams'><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/><csi xmlns='urn:xmpp:csi:0'/></features>")
        try session.client.module(.streamFeatures).process(stanza: features)
    }

    private var states: [String] {
        wire.written.compactMap { $0.element.xmlns == "urn:xmpp:csi:0" ? $0.element.name : nil }
    }

    @Test func lockingSaysInactiveAndUnlockingActive() {
        session.setScreenLocked(true)
        #expect(states == ["inactive"])
        session.setScreenLocked(true)
        #expect(states == ["inactive"])
        session.setScreenLocked(false)
        #expect(states == ["inactive", "active"])
    }

    @Test func lockingDoesNotMakeTheAppInactive() {
        session.setScreenLocked(true)
        #expect(session.lock.withLock { $0.isActive })
    }

    @Test func aReconnectWhileLockedSaysInactive() {
        session.setScreenLocked(true)
        // A new session starts active on the server's side.
        session.client.module(.csi).reset(scopes: [.session])
        session.resumeWork()
        #expect(states == ["inactive", "inactive"])
        #expect(session.client.module(.csi).state == false)
    }

    @Test func aReconnectAfterUnlockingSaysActive() {
        session.setScreenLocked(true)
        session.setScreenLocked(false)
        session.resumeWork()
        #expect(states.last == "active")
    }
}
