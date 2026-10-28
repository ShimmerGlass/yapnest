import Combine
import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let bob = YapnestKit.JID("bob@example.org")!

/// The app follows contacts' presence one change at a time, so each presence
/// must publish exactly what it changed.
struct PeerUpdateTests {
    let session: XMPPSession
    let wire = FakeWire()
    private let updates = Locked<[PeerUpdate]>([])
    private let cancellable: AnyCancellable

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
        let updates = updates
        cancellable = session.peerUpdates.sink { updates.value.append($0) }
    }

    private func receive(_ from: String, show: String? = nil, status: String? = nil, type: String? = nil) {
        let type = type.map { " type='\($0)'" } ?? ""
        let show = show.map { "<show>\($0)</show>" } ?? ""
        let status = status.map { "<status>\($0)</status>" } ?? ""
        session.presenceChanged(parseStanza("<presence from='\(from)' to='me@example.org'\(type)>\(show)\(status)</presence>"))
    }

    @Test func aPresenceYieldsOneUpdateWithItsAvailabilityAndStatus() {
        receive("alice@example.org/phone", show: "away", status: "Out")

        #expect(updates.value.count == 1)
        #expect(updates.value.first?.jid == alice)
        #expect(updates.value.first?.presence == .away)
        #expect(updates.value.first?.status == "Out")
    }

    @Test func anIdenticalRepeatYieldsNothing() {
        receive("alice@example.org/phone", status: "Out")
        receive("alice@example.org/phone", status: "Out")
        // A quieter resource doesn't change what the best one says.
        receive("alice@example.org/laptop", show: "away", status: "Zzz")

        #expect(updates.value.count == 1)
    }

    @Test func aStatusOnlyChangeYieldsAnUpdate() {
        receive("alice@example.org/phone", status: "Out")
        receive("alice@example.org/phone", status: "Back")

        #expect(updates.value.count == 2)
        #expect(updates.value.last?.presence == .online)
        #expect(updates.value.last?.status == "Back")
    }

    @Test func goingUnavailableYieldsANilPresence() {
        receive("alice@example.org/phone", status: "Out")
        receive("alice@example.org/phone", type: "unavailable")

        #expect(updates.value.count == 2)
        #expect(updates.value.last?.jid == alice)
        #expect(updates.value.last?.presence == nil)
        #expect(updates.value.last?.status == nil)
    }

    @Test func clearingPresencesYieldsANilUpdateForEachContactThatHadOne() {
        receive("alice@example.org/phone")
        receive("bob@example.org/phone")
        receive("bob@example.org/laptop", type: "unavailable")
        receive("bob@example.org/phone", type: "unavailable")
        let before = updates.value.count

        session.clearPresences()

        let cleared = updates.value.dropFirst(before)
        #expect(cleared.map(\.jid) == [alice])
        #expect(cleared.allSatisfy { $0.presence == nil && $0.status == nil })
    }

    @Test func evictingAStrangerYieldsANilUpdateForThem() throws {
        for index in 0..<XMPPSession.maxPresenceSenders { receive("stranger\(index)@evil.example/x") }
        let stranger = YapnestKit.JID("stranger0@evil.example")!
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        let before = updates.value.count

        receive("alice@example.org/phone")

        let fresh = updates.value.dropFirst(before)
        #expect(fresh.count == 2)
        #expect(fresh.first?.jid == alice)
        #expect(fresh.first?.presence == .online)
        #expect(fresh.last?.jid == stranger)
        #expect(fresh.last?.presence == nil)
    }
}
