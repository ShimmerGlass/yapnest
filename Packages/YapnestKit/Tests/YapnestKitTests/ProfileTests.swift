import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!

struct ProfileTests {
    let session: XMPPSession

    init() throws {
        session = try makeSession(me)
    }

    @Test func ownStatusFollowsTheAvailabilityAndMessage() async throws {
        var values = session.observeOwnStatus()
            .values(in: session.database.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        #expect(try await values.next() == .init(availability: .available, message: ""))
        try session.setAvailability(.dnd)
        #expect(try await values.next() == .init(availability: .dnd, message: ""))
        try session.setStatusMessage("  At the\nbeach ")
        #expect(try await values.next() == .init(availability: .dnd, message: "At the beach"))
    }

    @Test func avatarNodesAreOpenToEveryone() throws {
        let options = ProfileStanza.publishOptions(accessModel: "open")
        let fields = options.children.reduce(into: [String: String]()) { fields, field in
            fields[field.getAttribute("var") ?? ""] = field.firstChild(name: "value")?.value
        }
        #expect(options.getAttribute("type") == "submit")
        #expect(fields["FORM_TYPE"] == "http://jabber.org/protocol/pubsub#publish-options")
        #expect(fields["pubsub#access_model"] == "open")
        #expect(fields["pubsub#persist_items"] == "true")
    }

    @Test func avatarPayloads() throws {
        let data = Data([1, 2, 3])
        let payload = ProfileStanza.avatarData(data)
        #expect(payload.name == "data")
        #expect(payload.xmlns == "urn:xmpp:avatar:data")
        #expect(payload.value == data.base64EncodedString())

        let info = PEPUserAvatarModule.Info(id: AvatarStore.hash(of: data), size: 3, mimeType: "image/jpeg", height: 8, width: 8)
        let metadata = ProfileStanza.avatarMetadata(info)
        #expect(metadata.xmlns == "urn:xmpp:avatar:metadata")
        let element = try #require(metadata.firstChild(name: "info"))
        #expect(element.getAttribute("type") == "image/jpeg")
        #expect(element.getAttribute("bytes") == "3")
        #expect(element.getAttribute("id") == AvatarStore.hash(of: data))
    }

    @Test func removingSaysNoAvatarWithEmptyMetadata() {
        let metadata = ProfileStanza.avatarMetadata(nil)
        #expect(metadata.name == "metadata")
        #expect(metadata.children.isEmpty)
    }

    @Test func offlineSessionRefusesToPublish() async {
        await #expect(throws: XMPPSession.ProfileError.self) {
            try await session.publishAvatar(Data([1]), mimeType: "image/png")
        }
        await #expect(throws: XMPPSession.ProfileError.self) {
            try await session.removeAvatar()
        }
    }

    // MARK: Nicknames

    private let alice = YapnestKit.JID("alice@example.org")!

    @Test func nicknamesAreOneTrimmedBoundedLine() {
        #expect(XMPPSession.normalizedNickname("  Ada \n Lovelace ") == "Ada   Lovelace")
        #expect(XMPPSession.normalizedNickname("   ") == nil)
        #expect(XMPPSession.normalizedNickname(nil) == nil)
        #expect(XMPPSession.normalizedNickname(String(repeating: "a", count: 500))?.count == XMPPSession.maxNicknameLength)
    }

    @Test func nickPayloadsRoundTrip() {
        let payload = ProfileStanza.nick("Ada")
        #expect(payload.xmlns == "http://jabber.org/protocol/nick")
        #expect(ProfileStanza.nick(from: payload) == "Ada")
        #expect(ProfileStanza.nick(from: Element(name: "nick", cdata: "x", xmlns: "other")) == nil)
        #expect(ProfileStanza.nick(from: nil) == nil)
    }

    @Test func subscriptionRequestsCarryOurName() {
        let named = OutboundStanza.subscriptionRequest(to: alice, nickname: "Ada")
        #expect(named.type == .subscribe)
        #expect(named.to?.description == "alice@example.org")
        #expect(named.nickname == "Ada")
        #expect(OutboundStanza.subscriptionRequest(to: alice, nickname: nil).nickname == nil)
    }

    @Test func subscriptionRequestsCarryAnInvitationsPreauth() throws {
        let request = OutboundStanza.subscriptionRequest(to: alice, nickname: "Ada", preauth: "tok-123")
        let preauth = try #require(request.firstChild(name: "preauth", xmlns: "urn:xmpp:pars:0"))
        #expect(preauth.attribute("token") == "tok-123")
        #expect(request.nickname == "Ada")
        #expect(OutboundStanza.subscriptionRequest(to: alice, nickname: nil).firstChild(name: "preauth") == nil)
    }

    @Test func formatCharactersAreRemovedFromNames() throws {
        // Right-to-left override, isolates, marks, zero-width space and joiner, BOM.
        let hostile = "\u{202E}Mom\u{202C}\u{2066}\u{2069}\u{200E}\u{200F}\u{200B}\u{200D}\u{FEFF}"
        #expect(XMPPSession.removingFormatCharacters(hostile) == "Mom")
        #expect(XMPPSession.normalizedNickname(hostile) == "Mom")
        #expect(XMPPSession.normalizedNickname("\u{202E}\u{200B}") == nil)
        #expect(XMPPSession.normalizedNickname(" Ada\nL. ") == "Ada L.")
        #expect(XMPPSession.normalizedNickname("Zoë 🙂") == "Zoë 🙂")
        session.nicknameChanged(alice, to: "\u{202E}Mom")
        #expect(try session.database.contact(alice)?.nickname == "Mom")
    }

    @Test func requestNamesAreCleanedAndNeverBecomeTheRosterName() throws {
        try session.recordContactRequest(from: alice, nickname: "\u{202E}Mom\u{200B}\n")
        var contact = try #require(try session.database.contact(alice))
        #expect(contact.requestedNickname == "Mom")
        #expect(contact.name == nil)
        #expect(contact.displayName == "alice")

        // Accepting adds them without a name (see `acceptContactRequest`), so
        // the roster's push carries none, and nothing replaces it.
        try session.database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        contact = try #require(try session.database.contact(alice))
        #expect(contact.name == nil)
    }

    @Test func ourNameIsKeptAndClearedFromTheServer() {
        #expect(session.nickname == nil)
        session.nicknameChanged(me, to: " Mat ")
        #expect(session.nickname == "Mat")
        session.nicknameChanged(me, to: nil)
        #expect(session.nickname == nil)
    }

    @Test func publishedNamesShowOnlyWithoutARosterName() throws {
        let database = session.database
        session.nicknameChanged(alice, to: "Alice P.")
        // Anyone can publish a name; only someone the user added is shown by it.
        #expect(try database.contact(alice)?.displayName == "alice")
        try database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        #expect(try database.contact(alice)?.displayName == "Alice P.")

        // The roster's name wins, and a later nickname doesn't replace it.
        try database.updateRosterItem(jid: alice, name: "Ally", subscription: .both, isPending: false)
        #expect(try database.contact(alice)?.displayName == "Ally")
        session.nicknameChanged(alice, to: "Alice Q.")
        #expect(try database.contact(alice)?.displayName == "Ally")
        #expect(try database.contact(alice)?.nickname == "Alice Q.")

        // Without a roster name again, theirs shows, and without either, the address.
        try database.updateRosterItem(jid: alice, name: nil, subscription: .both, isPending: false)
        #expect(try database.contact(alice)?.displayName == "Alice Q.")
        session.nicknameChanged(alice, to: nil)
        #expect(try database.contact(alice)?.displayName == "alice")
    }

    // MARK: Status

    @Test func statusDefaultsToAvailableWithNoMessage() {
        #expect(session.availability == .available)
        #expect(session.statusMessage == "")
    }

    @Test func statusSurvivesRelaunch() throws {
        try session.setStatus(availability: .dnd, message: "  In a meeting \n until 3 ")
        #expect(session.availability == .dnd)
        #expect(session.statusMessage == "In a meeting   until 3")
        // A new session on the same database starts from what was saved.
        let relaunched = try makeSession(me, database: session.database)
        #expect(relaunched.availability == .dnd)
        #expect(relaunched.statusMessage == "In a meeting   until 3")

        try session.setStatus(availability: .available, message: "")
        #expect(session.availability == .available)
        #expect(session.statusMessage == "")
        #expect(try session.database.setting(.availability) == nil)
        #expect(try session.database.setting(.statusMessage) == nil)
    }

    @Test func availabilityMapsToShow() {
        #expect(XMPPSession.Availability.available.show == .online)
        #expect(XMPPSession.Availability.away.show == .away)
        #expect(XMPPSession.Availability.dnd.show == .dnd)
        #expect(XMPPSession.normalizedStatus(String(repeating: "a", count: 500))?.count == XMPPSession.maxStatusLength)
    }

    // MARK: Contacts' status

    private func receive(_ xml: String) {
        session.presenceChanged(Stanza.from(element: Element.from(string: xml)!) as! Presence)
    }

    private func presence(_ resource: String, show: String? = nil, status: String? = nil, type: String? = nil) -> String {
        let type = type.map { " type='\($0)'" } ?? ""
        let show = show.map { "<show>\($0)</show>" } ?? ""
        let status = status.map { "<status>\($0)</status>" } ?? ""
        return "<presence from='alice@example.org/\(resource)' to='me@example.org'\(type)>\(show)\(status)</presence>"
    }

    @Test func aContactsStatusIsKept() {
        receive(presence("phone", status: "At the beach"))
        #expect(session.statuses.value[alice] == "At the beach")
        #expect(session.presence(of: alice) == .online)
    }

    @Test func noStatusMeansNone() {
        receive(presence("phone", status: "At the beach"))
        receive(presence("phone", show: "away"))
        #expect(session.statuses.value[alice] == nil)
        #expect(session.presence(of: alice) == .away)
    }

    @Test func theMostAvailableResourceSpeaks() {
        receive(presence("phone", show: "away", status: "Back soon"))
        receive(presence("laptop", status: "Working"))
        #expect(session.statuses.value[alice] == "Working")
        // Equally available: the newest.
        receive(presence("phone", status: "On the train"))
        #expect(session.statuses.value[alice] == "On the train")
        // Less available again.
        receive(presence("phone", show: "dnd", status: "Busy"))
        #expect(session.statuses.value[alice] == "Working")
        // The laptop leaves, and the phone speaks.
        receive(presence("laptop", type: "unavailable"))
        #expect(session.statuses.value[alice] == "Busy")
        #expect(session.presence(of: alice) == .busy)
    }

    @Test func goingOfflineClearsTheStatus() {
        receive(presence("phone", status: "Hi"))
        receive(presence("phone", status: "Gone", type: "unavailable"))
        #expect(session.statuses.value[alice] == nil)
        #expect(session.presence(of: alice) == .offline)
    }

    @Test func clearingPresencesClearsStatuses() {
        receive(presence("phone", status: "Hi"))
        session.clearPresences()
        #expect(session.statuses.value.isEmpty)
        #expect(session.presences.value.isEmpty)
    }

    @Test func aContactsStatusIsOneBoundedLine() {
        receive(presence("phone", status: String(repeating: "x", count: 2000)))
        #expect(session.statuses.value[alice]?.count == XMPPSession.maxContactStatusLength)
    }
}
