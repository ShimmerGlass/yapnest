import Foundation
import Observation
import Testing
import YapnestKit
@testable import Yapnest

@MainActor
struct TypingIndicatorTests {
    let peer = JID("peer@example.com")!

    private func signedIn(_ fixture: AppModelFixture) async throws -> XMPPSession {
        try await fixture.model.signIn(fixture.credentialsToSignIn)
        return try #require(fixture.model.session)
    }

    private func startTyping(_ session: XMPPSession, _ model: AppModel) async {
        session.events.send(.chatState(peer, .composing))
        await eventually("typing starts") { model.live.peer(peer).isTyping }
    }

    @Test func anOfflinePresenceEndsTheIndicator() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        session.peerUpdates.send(PeerUpdate(jid: peer, presence: .online, status: nil))
        await startTyping(session, fixture.model)

        session.peerUpdates.send(PeerUpdate(jid: peer, presence: .offline, status: nil))

        await eventually("typing ends") { fixture.model.typingPeers.isEmpty }
    }

    @Test func aPeerThePresencesNoLongerHoldStopsTyping() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        session.peerUpdates.send(PeerUpdate(jid: peer, presence: .online, status: nil))
        await startTyping(session, fixture.model)

        session.peerUpdates.send(PeerUpdate(jid: peer, presence: nil, status: nil))

        await eventually("typing ends") { fixture.model.typingPeers.isEmpty }
    }

    @Test func aStrangerWeHaveNoPresenceForKeepsTyping() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        await startTyping(session, fixture.model)

        session.peerUpdates.send(PeerUpdate(jid: JID("friend@example.com")!, presence: .online, status: nil))

        #expect(await stays { fixture.model.live.peer(peer).isTyping })
    }

    @Test func disconnectingEndsTheIndicator() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        await startTyping(session, fixture.model)

        session.state.send(.disconnected(error: nil))

        await eventually("typing ends") { fixture.model.typingPeers.isEmpty }
    }

    @Test func anActiveFromSomeoneNotTypingInvalidatesNoReader() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        let model: AppModel = fixture.model
        nonisolated(unsafe) var invalidated = false
        withObservationTracking { _ = model.live.peer(peer).isTyping } onChange: { invalidated = true }

        session.events.send(.chatState(peer, .active))

        #expect(await stays { !invalidated })
    }

    @Test func aRepeatedComposingInvalidatesNoReader() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        let model: AppModel = fixture.model
        await startTyping(session, model)
        nonisolated(unsafe) var invalidated = false
        withObservationTracking { _ = model.live.peer(peer).isTyping } onChange: { invalidated = true }

        session.events.send(.chatState(peer, .composing))

        #expect(await stays { !invalidated })
    }

    @Test func aComposingNeverFollowedByAnythingExpires() async throws {
        let fixture = AppModelFixture(typingLifetime: 0.5)
        let session = try await signedIn(fixture)
        await startTyping(session, fixture.model)

        await eventually("typing expires", timeout: .seconds(4)) { fixture.model.typingPeers.isEmpty }
    }
}
