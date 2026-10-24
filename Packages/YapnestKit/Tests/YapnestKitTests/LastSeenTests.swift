import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func ask(_ schedule: inout LastSeenSchedule, _ jid: YapnestKit.JID, now: Date) -> Bool {
    schedule.claim(jid, now: now)
}

struct LastSeenTests {
    // MARK: Answering

    @Test(arguments: [Contact.Subscription.none, .to, .from, .both])
    func answersOnlyContactsWhoSeeUs(subscription: Contact.Subscription) {
        let contact = Contact(jid: alice, subscription: subscription, isInRoster: true)
        #expect(LastActivity.mayAnswer(requester: contact) == (subscription == .from || subscription == .both))
    }

    @Test func refusesStrangersAndFormerContacts() {
        #expect(!LastActivity.mayAnswer(requester: nil))
        // Not in the roster any more, though the row remains.
        #expect(!LastActivity.mayAnswer(requester: Contact(jid: alice, subscription: .both, isInRoster: false)))
    }

    @Test func sessionAnswersFromTheDatabase() throws {
        let session = try makeSession(me)
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        // Off by default, so nobody is told anything.
        #expect(session.sharesLastSeen == false)
        #expect(session.lastActivityAnswer(for: alice) == nil)
        try session.database.setFlag(.sharesLastSeen, true)
        #expect(session.lastActivityAnswer(for: alice) == 0)
        #expect(session.lastActivityAnswer(for: YapnestKit.JID("eve@example.org")!) == nil)
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .to, isPending: false)
        #expect(session.lastActivityAnswer(for: alice) == nil)
    }

    @Test func offeredInCapabilitiesOnlyWhileSharing() throws {
        let session = try makeSession(me)
        let features = { session.client.modulesManager.availableFeatures }
        #expect(!features().contains(NS.last))
        try session.setSharesLastSeen(true)
        #expect(features().contains(NS.last))
        try session.setSharesLastSeen(false)
        #expect(!features().contains(NS.last))
    }

    // MARK: Idle time

    @Test func idleIsWholeSecondsAndNeverNegative() throws {
        let session = try makeSession(me)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(session.idleSeconds(now: now) == 0)
        session.lock.withLock { $0.idleSince = now.addingTimeInterval(-90.7) }
        #expect(session.idleSeconds(now: now) == 90)
        // A clock that stepped back doesn't give a negative time.
        session.lock.withLock { $0.idleSince = now.addingTimeInterval(10) }
        #expect(session.idleSeconds(now: now) == 0)
    }

    @Test func theMachinesIdleTimeWinsWhereThereIsOne() throws {
        let session = try makeSession(me)
        session.setActive(false)
        session.setIdleSource { 42.9 }
        #expect(session.idleSeconds() == 42)
        // In another app but still at the machine: not idle.
        session.setIdleSource { 0 }
        #expect(session.idleSeconds() == 0)
        session.setIdleSource(nil)
        session.lock.withLock { $0.idleSince = Date().addingTimeInterval(-30) }
        #expect(session.idleSeconds() >= 30)
    }

    @Test func sessionIdlesFromWhenItLeftTheApp() throws {
        let session = try makeSession(me)
        #expect(session.idleSeconds() == 0)
        session.setActive(false)
        let left = try #require(session.lock.withLock { $0.idleSince })
        // Going inactive again doesn't restart the clock.
        session.setActive(false)
        #expect(session.lock.withLock { $0.idleSince } == left)
        #expect(session.idleSeconds(now: left.addingTimeInterval(120)) == 120)
        session.setActive(true)
        #expect(session.idleSeconds(now: left.addingTimeInterval(120)) == 0)
    }

    // MARK: Parsing

    @Test func readsTheSeconds() throws {
        func iq(_ xml: String) throws -> Element { try #require(Element.from(string: xml)) }
        #expect(LastActivity.seconds(in: try iq("<iq type='result'><query xmlns='jabber:iq:last' seconds='7200'/></iq>")) == 7200)
        #expect(LastActivity.seconds(in: try iq("<iq type='result'><query xmlns='jabber:iq:last'/></iq>")) == nil)
        #expect(LastActivity.seconds(in: try iq("<iq type='result'><query xmlns='jabber:iq:last' seconds='soon'/></iq>")) == nil)
        #expect(LastActivity.seconds(in: try iq("<iq type='result'><query xmlns='jabber:iq:last' seconds='-5'/></iq>")) == nil)
        #expect(LastActivity.seconds(in: try iq("<iq type='result'><query xmlns='other' seconds='5'/></iq>")) == nil)
    }

    // MARK: Schedule

    @Test func asksAtMostOnceInAWhile() {
        var schedule = LastSeenSchedule()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(ask(&schedule, alice, now: start) == true)
        #expect(ask(&schedule, alice, now: start.addingTimeInterval(60)) == false)
        #expect(ask(&schedule, YapnestKit.JID("bob@example.org")!, now: start.addingTimeInterval(60)) == true)
        #expect(ask(&schedule, alice, now: start.addingTimeInterval(LastSeenSchedule.refreshInterval + 1)) == true)
    }

    @Test func aRefusingServerIsNotAskedAgain() {
        var schedule = LastSeenSchedule()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(ask(&schedule, alice, now: start) == true)
        schedule.refuse(alice)
        #expect(ask(&schedule, alice, now: start.addingTimeInterval(10 * LastSeenSchedule.refreshInterval)) == false)
        schedule.reset()
        #expect(ask(&schedule, alice, now: start) == true)
    }

    @Test func aDepartureWeSawIsNotAskedAbout() {
        var schedule = LastSeenSchedule()
        let start = Date(timeIntervalSince1970: 1_000_000)
        schedule.sawLeaving(alice)
        #expect(ask(&schedule, alice, now: start) == false)
        schedule.sawArriving(alice)
        #expect(ask(&schedule, alice, now: start) == true)
        schedule.sawLeaving(alice)
        schedule.forgetDepartures()
        #expect(ask(&schedule, alice, now: start.addingTimeInterval(10 * LastSeenSchedule.refreshInterval)) == true)
    }

    // MARK: Going offline

    private func receive(_ type: String?, on session: XMPPSession) {
        let type = type.map { " type='\($0)'" } ?? ""
        let xml = "<presence from='alice@example.org/phone'\(type)/>"
        session.presenceChanged(Stanza.from(element: Element.from(string: xml)!) as! Presence)
    }

    private func lastSeen(_ session: XMPPSession) throws -> Date? { try session.database.contact(alice)?.lastSeenAt }

    /// The write is made off the calling thread.
    private func waitForLastSeen(_ session: XMPPSession) async throws -> Date? {
        for _ in 0..<200 {
            if let seen = try lastSeen(session) { return seen }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func sessionWatching(sharing: Bool) throws -> XMPPSession {
        let session = try makeSession(me)
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        try session.database.setFlag(.sharesLastSeen, sharing)
        return session
    }

    @Test func leavingIsRecordedAsLastSeenNow() async throws {
        let session = try sessionWatching(sharing: true)
        receive(nil, on: session)
        #expect(try lastSeen(session) == nil)
        // The database keeps milliseconds, so the stored time can read back
        // a fraction of one before `before`.
        let before = Date().addingTimeInterval(-0.01)
        receive("unavailable", on: session)
        let seen = try #require(try await waitForLastSeen(session))
        #expect(seen >= before && seen <= Date())
    }

    @Test func leavingIsNotRecordedUnlessWeSawThemArrive() async throws {
        let session = try sessionWatching(sharing: true)
        receive("unavailable", on: session)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try lastSeen(session) == nil)
    }

    @Test func leavingIsNotRecordedWhileNotSharing() async throws {
        let session = try sessionWatching(sharing: false)
        receive(nil, on: session)
        receive("unavailable", on: session)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try lastSeen(session) == nil)
    }

    @Test func oneOfSeveralResourcesLeavingIsNotLeaving() async throws {
        let session = try sessionWatching(sharing: true)
        receive(nil, on: session)
        session.presenceChanged(Stanza.from(element: Element.from(string: "<presence from='alice@example.org/laptop'/>")!) as! Presence)
        receive("unavailable", on: session)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try lastSeen(session) == nil)
    }

    // MARK: Storage

    @Test func stoppingSharingForgetsWhatWeKnew() throws {
        let session = try makeSession(me)
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        try session.setSharesLastSeen(true)
        try session.database.setLastSeen(Date(timeIntervalSince1970: 5), for: alice)
        #expect(try session.database.contact(alice)?.lastSeenAt == Date(timeIntervalSince1970: 5))
        try session.setSharesLastSeen(false)
        #expect(try session.database.contact(alice)?.lastSeenAt == nil)
    }

    @Test func aRosterUpdateKeepsLastSeen() throws {
        let database = try AppDatabase.inMemory()
        try database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        try database.setLastSeen(Date(timeIntervalSince1970: 5), for: alice)
        try database.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        #expect(try database.contact(alice)?.lastSeenAt == Date(timeIntervalSince1970: 5))
    }
}
