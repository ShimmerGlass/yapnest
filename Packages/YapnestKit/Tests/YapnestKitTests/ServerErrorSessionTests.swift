import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
/// What a request is for, when it has to be answered by what it asks.
private func isDisco(_ iq: Iq, _ suffix: String) -> Bool {
    iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#\(suffix)") != nil
}

/// A server error that passes, and one that doesn't, as a read of a node can fail.
private func timeout(_ iq: Iq) -> Iq { FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait") }
private func internalError(_ iq: Iq) -> Iq { FakeWire.error(to: iq, condition: "internal-server-error", type: "wait") }

// MARK: Joining

struct RoomLookupFailureTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
    }

    @Test func aTimeoutLookingUpAnInvitedRoomIsNotAMissingGroup() async throws {
        wire.answer { iq in isDisco(iq, "info") ? timeout(iq) : nil }
        session.join(room, nickname: "me", mayCreate: false)
        #expect(await eventually { session.roomStatus(room)?.canRetry == true })
        guard case .failed(let reason)? = session.roomStatus(room)?.phase else {
            Issue.record("the join did not fail")
            return
        }
        #expect(!reason.contains("doesn't exist"))
        #expect(reason.contains("remote-server-timeout"))
        #expect(session.hasScheduledRejoin(room))
        session.cancelAllRejoins()
    }

    @Test func aRoomThatIsNotFoundIsAMissingGroup() async throws {
        wire.answer { iq in isDisco(iq, "info") ? FakeWire.error(to: iq) : nil }
        session.join(room, nickname: "me", mayCreate: false)
        #expect(await eventually { session.roomStatus(room)?.phase == .failed("This group doesn't exist.") })
        #expect(session.roomStatus(room)?.canRetry == false)
    }

    @Test func aTimeoutLookingUpOurOwnRoomStillJoinsIt() async throws {
        wire.answer { iq in isDisco(iq, "info") ? timeout(iq) : nil }
        session.join(room, nickname: "me")
        #expect(await eventually { wire.written.contains { $0 is Presence } })
        #expect(session.roomStatus(room)?.canRetry != true)
    }

    @Test func aTimeoutRereadingARoomsInfoLearnsNothingOfItsArchive() async throws {
        wire.answer { iq in isDisco(iq, "info") ? timeout(iq) : nil }
        #expect(await session.refreshedRoomInfo(room) == nil)
        wire.answer { iq in isDisco(iq, "info") ? FakeWire.discoInfo(to: iq, category: "conference", type: "text", features: ["urn:xmpp:mam:2"]) : nil }
        #expect(await session.refreshedRoomInfo(room) == true)
    }

    @Test func aFinalRefusalOfTheLookupStillJoinsSoTheRoomGivesItsOwnReason() async throws {
        wire.answer { iq in isDisco(iq, "info") ? FakeWire.error(to: iq, condition: "forbidden", type: "auth") : nil }
        session.join(room, nickname: "me")
        #expect(await eventually { wire.written.contains { $0 is Presence } })
    }
}

// MARK: Group chat service

struct MucServiceLookupTests {
    @Test func aTimeoutAskingAComponentWhatItIsIsNotAServerWithoutGroups() async throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { iq in
            if isDisco(iq, "items") {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                query.addChild(Element(name: "item", attributes: ["jid": "rooms.example.org"]))
                return FakeWire.result(to: iq, query)
            }
            return isDisco(iq, "info") ? timeout(iq) : nil
        }
        do {
            _ = try await session.createGroup(name: "Cake", inviting: [])
            Issue.record("the group was created")
        } catch let GroupError.lookupFailed(error) {
            #expect(error.condition == "remote-server-timeout")
        } catch {
            Issue.record("failed with \(error) instead of a lookup failure")
        }
    }

    @Test func theFirstListedGroupChatServiceIsTheServers() async throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { iq in
            if isDisco(iq, "items") {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                for jid in ["upload.example.org", "rooms.example.org", "gateway.example.org"] {
                    query.addChild(Element(name: "item", attributes: ["jid": jid]))
                }
                return FakeWire.result(to: iq, query)
            }
            guard isDisco(iq, "info") else { return nil }
            if iq.to?.stringValue == "upload.example.org" { return FakeWire.discoInfo(to: iq, category: "store", type: "file") }
            return FakeWire.discoInfo(to: iq, category: "conference", type: "text")
        }
        _ = try? await session.createGroup(name: "Cake", inviting: [])
        #expect(session.lock.withLock { $0.mucService } == "rooms.example.org")
    }

    @Test func aWaitAnswerOfInternalErrorIsNotAServerWithoutGroups() async throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { iq in
            if isDisco(iq, "items") {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                query.addChild(Element(name: "item", attributes: ["jid": "rooms.example.org"]))
                return FakeWire.result(to: iq, query)
            }
            return isDisco(iq, "info") ? internalError(iq) : nil
        }
        do {
            _ = try await session.createGroup(name: "Cake", inviting: [])
            Issue.record("the group was created")
        } catch GroupError.lookupFailed {
        } catch {
            Issue.record("failed with \(error)")
        }
    }

    @Test func aServerWhoseComponentsAreNotGroupChatsHasNone() async throws {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer { iq in
            if isDisco(iq, "items") {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                query.addChild(Element(name: "item", attributes: ["jid": "upload.example.org"]))
                return FakeWire.result(to: iq, query)
            }
            return isDisco(iq, "info") ? FakeWire.discoInfo(to: iq, category: "store", type: "file") : nil
        }
        await #expect(throws: GroupError.self) { _ = try await session.createGroup(name: "Cake", inviting: []) }
    }
}

// MARK: Bookmarks

struct BookmarkFetchFailureTests {
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try makeSession(me)
        session.connectForTesting(wire)
    }

    private func read(answering: @escaping @Sendable (Iq) -> Iq?) async -> (list: [Bookmark]?, isRead: Bool) {
        wire.answer(answering)
        return await withCheckedContinuation { continuation in
            session.readBookmarks { continuation.resume(returning: ($0, $1)) }
        }
    }

    @Test func aTimeoutIsAFailureNotAnEmptyList() async {
        let result = await read { timeout($0) }
        #expect(result.list == nil)
        #expect(!result.isRead)
    }

    @Test func aServerErrorIsAFailureNotAnEmptyList() async {
        let result = await read { internalError($0) }
        #expect(result.list == nil)
        #expect(!result.isRead)
    }

    @Test func aMissingNodeIsAnEmptyList() async {
        let result = await read { FakeWire.error(to: $0) }
        #expect(result.list?.isEmpty == true)
        #expect(result.isRead)
    }

    @Test func aServerWithoutTheNodeHasNoListToApplyAndNothingOwed() async {
        let result = await read { FakeWire.error(to: $0, condition: "service-unavailable") }
        #expect(result.list == nil)
        #expect(result.isRead)
    }

    @Test func aFailedSyncLeavesOurGroupsAloneAndIsOwed() async throws {
        try session.database.joinGroupChat(room, nickname: "me", name: "Cake", isBookmarked: true)
        wire.answer { timeout($0) }
        let read = Locked<Bool?>(nil)
        session.syncBookmarks { read.value = $0 }
        #expect(await eventually { read.value != nil })
        #expect(read.value == false)
        #expect(try session.database.groupChat(room)?.hasLeft == false)
        session.cancelAllRejoins()
    }

    @Test func aSyncOfAServerWithoutTheNodeKeepsOurGroupsAndIsRead() async throws {
        try session.database.joinGroupChat(room, nickname: "me", name: "Cake", isBookmarked: true)
        wire.answer { FakeWire.error(to: $0, condition: "service-unavailable") }
        let read = Locked<Bool?>(nil)
        session.syncBookmarks { read.value = $0 }
        #expect(await eventually { read.value != nil })
        #expect(read.value == true)
        #expect(try session.database.groupChat(room)?.hasLeft == false)
        session.cancelAllRejoins()
    }

    @Test func aRefreshOnAnOldBookmarksServerReadsTheOldList() async throws {
        let sawLegacy = Locked(false)
        wire.answer { iq in
            if iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.attribute("node") == "storage:bookmarks" { sawLegacy.value = true }
            return timeout(iq)
        }
        #expect(session.usesLegacyBookmarks)
        let read = Locked<Bool?>(nil)
        session.refreshBookmarks { read.value = $0 }
        #expect(await eventually { read.value != nil })
        #expect(sawLegacy.value)
        #expect(read.value == false)
    }

    @Test func aSyncOfAMissingNodeIsRead() async throws {
        wire.answer { FakeWire.error(to: $0) }
        let read = Locked<Bool?>(nil)
        session.syncBookmarks { read.value = $0 }
        #expect(await eventually { read.value != nil })
        #expect(read.value == true)
    }
}

// MARK: Read states

struct DisplayedFetchFailureTests {
    private func fetch(_ respond: @escaping @Sendable (Iq) -> Iq?) async throws -> Bool? {
        let session = try makeSession(me)
        let wire = FakeWire()
        session.connectForTesting(wire)
        wire.answer(respond)
        let result = Locked<Bool?>(nil)
        session.fetchDisplayed { result.value = $0 }
        _ = await eventually { result.value != nil }
        return result.value
    }

    @Test func aTimeoutIsOwedAgain() async throws {
        #expect(try await fetch { timeout($0) } == false)
    }

    @Test func aServerWithoutTheNodeOwesNothing() async throws {
        #expect(try await fetch { FakeWire.error(to: $0, condition: "service-unavailable") } == true)
        #expect(try await fetch { FakeWire.error(to: $0) } == true)
    }
}
