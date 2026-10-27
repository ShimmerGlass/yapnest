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
        await eventually("typing starts") { model.typing.contains(peer) }
    }

    @Test func anOfflinePresenceEndsTheIndicator() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        session.presences.send([peer: .online])
        await startTyping(session, fixture.model)

        session.presences.send([peer: .offline])

        await eventually("typing ends") { fixture.model.typing.isEmpty }
    }

    @Test func aPeerThatDropsOutOfThePresencesStopsTyping() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        session.presences.send([peer: .online])
        await startTyping(session, fixture.model)

        session.presences.send([:])

        await eventually("typing ends") { fixture.model.typing.isEmpty }
    }

    @Test func aStrangerWeHaveNoPresenceForKeepsTyping() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        await startTyping(session, fixture.model)

        session.presences.send([JID("friend@example.com")!: .online])

        #expect(await stays { fixture.model.typing.contains(peer) })
    }

    @Test func disconnectingEndsTheIndicator() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        await startTyping(session, fixture.model)

        session.state.send(.disconnected(error: nil))

        await eventually("typing ends") { fixture.model.typing.isEmpty }
    }

    @Test func anActiveFromSomeoneNotTypingInvalidatesNoReader() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        let model: AppModel = fixture.model
        nonisolated(unsafe) var invalidated = false
        withObservationTracking { _ = model.typing } onChange: { invalidated = true }

        session.events.send(.chatState(peer, .active))

        #expect(await stays { !invalidated })
    }

    @Test func aRepeatedComposingInvalidatesNoReader() async throws {
        let fixture = AppModelFixture()
        let session = try await signedIn(fixture)
        let model: AppModel = fixture.model
        await startTyping(session, model)
        nonisolated(unsafe) var invalidated = false
        withObservationTracking { _ = model.typing } onChange: { invalidated = true }

        session.events.send(.chatState(peer, .composing))

        #expect(await stays { !invalidated })
    }

    @Test func aComposingNeverFollowedByAnythingExpires() async throws {
        let fixture = AppModelFixture(typingLifetime: 0.5)
        let session = try await signedIn(fixture)
        await startTyping(session, fixture.model)

        await eventually("typing expires", timeout: .seconds(4)) { fixture.model.typing.isEmpty }
    }
}
