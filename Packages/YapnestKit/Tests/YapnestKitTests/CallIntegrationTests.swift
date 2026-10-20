import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Audio calls between alice and bob with media that does nothing, so this
    /// tests the signalling: ringing, answering, declining and hanging up,
    /// across the devices of one account.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=ejabberd swift test --filter CallIntegration`
    @Suite
    struct CallIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func device(_ jid: JID, _ name: String) async throws -> (XMPPSession, FakeCallMediaFactory) {
            let factory = FakeCallMediaFactory()
            let session = try LiveServer.makeSession(
                jid, resource: "call-\(name)-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), callMedia: factory,
            )
            try await LiveServer.connected(session)
            return (session, factory)
        }

        /// Two accounts that can see each other's capabilities.
        private func callers(bobDevices: Int = 1) async throws -> (alice: (XMPPSession, FakeCallMediaFactory), bobs: [(XMPPSession, FakeCallMediaFactory)]) {
            let a = try await device(alice, "alice")
            var bobs: [(XMPPSession, FakeCallMediaFactory)] = []
            for index in 0..<bobDevices { bobs.append(try await device(bob, "bob\(index)")) }
            try await LiveServer.befriend(a.0, bobs[0].0)
            // The second device of bob gets alice's roster entry through bob's account.
            try await LiveServer.waitUntil("alice to be able to call bob") { a.0.canCall(bob) }
            return (a, bobs)
        }

        /// The rows of one call: the server's archive hands a new device the calls
        /// of earlier runs too.
        private func rows(_ session: XMPPSession, _ sid: String?) throws -> [Message] {
            try session.database.reader.read { try Message.filter(Column("callOutcome") != nil && Column("remoteId") == sid).fetchAll($0) }
        }

        @Test func aCallRingsIsAnsweredAndHungUp() async throws {
            let (a, bobs) = try await callers()
            let (aliceSession, aliceMedia) = a
            let (bobSession, bobMedia) = bobs[0]
            defer { aliceSession.disconnect(); bobSession.disconnect() }

            try aliceSession.startCall(to: bob)
            let sid = aliceSession.callState.value?.sid
            try await LiveServer.waitUntil("bob to ring") { bobSession.callState.value?.phase == .incoming }
            #expect(bobSession.callState.value?.peer == alice)
            try await LiveServer.waitUntil("alice to hear it ring") { aliceSession.callState.value?.phase == .ringing }

            bobSession.answerCall()
            try await LiveServer.waitUntil("alice to be answered") {
                let phase = aliceSession.callState.value?.phase
                return phase == .accepted || phase == .connecting
            }
            // The Jingle session is set up between the two: the offer reaches bob's media, and the answer alice's.
            try await LiveServer.waitUntil("bob's media to answer") { bobMedia.last?.answeredOffers.count == 1 }
            try await LiveServer.waitUntil("alice's media to be answered") { aliceMedia.last?.answersSet.count == 1 }
            #expect(bobMedia.last?.answeredOffers.first?.contains("a=ice-ufrag:FakeU") == true)

            aliceMedia.last?.emit(.state(.connected))
            bobMedia.last?.emit(.state(.connected))
            try await LiveServer.waitUntil("both to be active") {
                aliceSession.callState.value?.phase == .active && bobSession.callState.value?.phase == .active
            }

            // Candidates are trickled across.
            aliceMedia.last?.emit(.candidate(CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1 1 udp 2122260223 10.0.0.2 40000 typ host generation 0 ufrag FakeU network-id 1")))
            try await LiveServer.waitUntil("bob's media to get the candidate") { bobMedia.last?.remoteCandidates.count == 1 }

            aliceSession.hangUpCall()
            try await LiveServer.waitUntil("bob to be hung up on") { bobSession.callState.value?.phase == .ended(.completed) }
            try await LiveServer.waitUntil("both to record it") { (try? rows(aliceSession, sid).count) == 1 && (try? rows(bobSession, sid).count) == 1 }
            #expect(try rows(aliceSession, sid).first?.callOutcome == .answered)
            #expect(try rows(aliceSession, sid).first?.direction == .outgoing)
            #expect(try rows(bobSession, sid).first?.callOutcome == .answered)
            #expect(try rows(bobSession, sid).first?.direction == .incoming)
            #expect(try rows(bobSession, sid).first?.remoteId == rows(aliceSession, sid).first?.remoteId)
        }

        @Test func aDeclinedCallEndsForTheCaller() async throws {
            let (a, bobs) = try await callers()
            let aliceSession = a.0, bobSession = bobs[0].0
            defer { aliceSession.disconnect(); bobSession.disconnect() }

            try aliceSession.startCall(to: bob)
            let sid = aliceSession.callState.value?.sid
            try await LiveServer.waitUntil("bob to ring") { bobSession.callState.value?.phase == .incoming }
            bobSession.declineCall()
            try await LiveServer.waitUntil("alice to be declined") { aliceSession.callState.value?.phase == .ended(.declined) }
            try await LiveServer.waitUntil("both to record it") { (try? rows(aliceSession, sid).count) == 1 && (try? rows(bobSession, sid).count) == 1 }
            #expect(try rows(aliceSession, sid).first?.callOutcome == .declined)
            #expect(try rows(bobSession, sid).first?.callOutcome == .declined)
        }

        @Test func aCallerGivingUpIsAMissedCall() async throws {
            let (a, bobs) = try await callers()
            let aliceSession = a.0, bobSession = bobs[0].0
            defer { aliceSession.disconnect(); bobSession.disconnect() }

            try aliceSession.startCall(to: bob)
            let sid = aliceSession.callState.value?.sid
            try await LiveServer.waitUntil("bob to ring") { bobSession.callState.value?.phase == .incoming }
            aliceSession.hangUpCall()
            try await LiveServer.waitUntil("bob to stop ringing") { bobSession.callState.value?.phase == .ended(.missed) }
            try await LiveServer.waitUntil("both to record it") { (try? rows(aliceSession, sid).count) == 1 && (try? rows(bobSession, sid).count) == 1 }
            #expect(try rows(aliceSession, sid).first?.callOutcome == .cancelled)
            let missed = try #require(try rows(bobSession, sid).first)
            #expect(missed.callOutcome == .missed)
            #expect(!missed.isRead)
        }

        @Test func answeringOnOneDeviceStopsTheOthers() async throws {
            let (a, bobs) = try await callers(bobDevices: 2)
            let aliceSession = a.0
            let first = bobs[0].0, second = bobs[1].0
            defer { aliceSession.disconnect(); first.disconnect(); second.disconnect() }

            try aliceSession.startCall(to: bob)
            let sid = aliceSession.callState.value?.sid
            try await LiveServer.waitUntil("both of bob's devices to ring") {
                first.callState.value?.phase == .incoming && second.callState.value?.phase == .incoming
            }
            second.answerCall()
            try await LiveServer.waitUntil("the other device to stop ringing") { first.callState.value?.phase == .ended(.answeredElsewhere) }
            try await LiveServer.waitUntil("the call to be set up with the one that answered") {
                bobs[1].1.last?.answeredOffers.count == 1 && a.1.last?.answersSet.count == 1
            }
            #expect(bobs[0].1.made.isEmpty)
            a.1.last?.emit(.state(.connected))
            bobs[1].1.last?.emit(.state(.connected))
            try await LiveServer.waitUntil("the call to be active") { second.callState.value?.phase == .active }
            try await LiveServer.waitUntil("the other device to record it as answered") { (try? rows(first, sid).first?.callOutcome) == .answered }
            #expect(try rows(first, sid).first?.isRead == true)
            second.hangUpCall()
            try await LiveServer.waitUntil("alice to be hung up on") { aliceSession.callState.value?.phase == .ended(.completed) }
        }

        @Test func decliningOnOneDeviceStopsTheOthers() async throws {
            let (a, bobs) = try await callers(bobDevices: 2)
            let aliceSession = a.0
            defer { aliceSession.disconnect(); bobs.forEach { $0.0.disconnect() } }

            try aliceSession.startCall(to: bob)
            let sid = aliceSession.callState.value?.sid
            try await LiveServer.waitUntil("both of bob's devices to ring") {
                bobs.allSatisfy { $0.0.callState.value?.phase == .incoming }
            }
            bobs[1].0.declineCall()
            try await LiveServer.waitUntil("the other device to stop ringing") { bobs[0].0.callState.value?.phase == .ended(.declinedElsewhere) }
            try await LiveServer.waitUntil("alice to be declined") { aliceSession.callState.value?.phase == .ended(.declined) }
        }

        @Test func theServerOffersRelays() async throws {
            let (session, _) = try await device(alice, "relays")
            defer { session.disconnect() }
            let servers = await session.discoverIceServers()
            if servers.isEmpty { try Test.cancel("\(LiveServer.target.name) offers no STUN or TURN") }
            let turn = try #require(servers.first { $0.urls.contains { $0.hasPrefix("turn:") } })
            #expect(turn.username?.isEmpty == false)
            #expect(turn.credential?.isEmpty == false)
            #expect(servers.contains { $0.urls.contains { $0.hasPrefix("stun:") } })
        }
    }
}
