import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

/// Anyone can send presence, so what it costs to keep is bounded.
struct PresenceLimitTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
    }

    private func receive(_ from: String, _ inner: String = "") {
        session.presenceChanged(Stanza.from(element: Element.from(string: "<presence from='\(from)' to='me@example.org'>\(inner)</presence>")!) as! Presence)
    }

    private func resources(of jid: YapnestKit.JID) -> Int { session.lock.withLock { $0.resources[jid]?.count ?? 0 } }
    private var senders: Int { session.lock.withLock { $0.resources.count } }

    @Test func aSendersOldestResourceMakesWayForANewOne() {
        for index in 0..<(XMPPSession.maxResourcesPerSender + 10) { receive("alice@example.org/r\(index)") }
        #expect(resources(of: alice) == XMPPSession.maxResourcesPerSender)
        // The newest is kept, and still counts.
        #expect(session.lock.withLock { $0.resources[alice]?["r\(XMPPSession.maxResourcesPerSender + 9)"] } != nil)
        #expect(session.lock.withLock { $0.resources[alice]?["r0"] } == nil)
        #expect(session.presence(of: alice) == .online)
    }

    @Test func pastTheLimitOnlyThoseWeAreSubscribedToAreTaken() throws {
        for index in 0..<XMPPSession.maxPresenceSenders { receive("stranger\(index)@evil.example/x") }
        #expect(senders == XMPPSession.maxPresenceSenders)

        receive("stranger-more@evil.example/x")
        #expect(session.presence(of: YapnestKit.JID("stranger-more@evil.example")!) == .offline)
        #expect(senders == XMPPSession.maxPresenceSenders)

        // A contact still gets in, in place of the stalest stranger.
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        receive("alice@example.org/phone")
        #expect(session.presence(of: alice) == .online)
        #expect(session.presence(of: YapnestKit.JID("stranger0@evil.example")!) == .offline)
        #expect(senders == XMPPSession.maxPresenceSenders)
    }

    @Test func belowTheLimitAContactAheadOfTheRosterIsTaken() {
        // At sign-in, presences can arrive before the roster is stored.
        receive("alice@example.org/phone")
        #expect(session.presence(of: alice) == .online)
    }

    private let photo = "<x xmlns='vcard-temp:x:update'><photo>\(String(repeating: "a", count: 40))</photo></x>"
    private var vCardRequests: Int {
        wire.written.filter { ($0 as? Iq)?.findChild(name: "vCard", xmlns: "vcard-temp") != nil }.count
    }

    @Test func aStrangersPhotoIsNotFetched() {
        receive("eve@evil.example/x", photo)
        #expect(vCardRequests == 0)
    }

    @Test func aContactsPhotoIsFetched() throws {
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        receive("alice@example.org/phone", photo)
        #expect(vCardRequests == 1)
    }
}
