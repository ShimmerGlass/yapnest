import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!

/// Our own avatar metadata and name nodes, as a server holds them.
private final class ProfilePEPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var currentAvatar: String?
    private var names: [String: String] = [:]
    private var published: [(node: String, id: String?)] = []
    private var failure: (condition: String, type: String)?
    private var hook: (@Sendable () -> Void)?

    /// The id of the picture in the metadata; nil for empty metadata.
    var avatar: String? {
        get { lock.withLock { currentAvatar } }
        set { lock.withLock { currentAvatar = newValue } }
    }

    /// The name items by item id.
    var nicks: [String: String] {
        get { lock.withLock { names } }
        set { lock.withLock { names = newValue } }
    }

    var publishes: [(node: String, id: String?)] { lock.withLock { published } }

    func fail(_ condition: String, type: String) { lock.withLock { failure = (condition, type) } }
    func recover() { lock.withLock { failure = nil } }
    func onPublish(_ hook: @escaping @Sendable () -> Void) { lock.withLock { self.hook = hook } }

    func attach(to wire: FakeWire) {
        wire.answer { [self] iq in
            guard let pubsub = iq.firstChild(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub") else { return FakeWire.result(to: iq) }
            if let items = pubsub.firstChild(name: "items") { return read(items, iq) }
            if let publish = pubsub.firstChild(name: "publish") { return handlePublish(publish, iq) }
            if let retract = pubsub.firstChild(name: "retract") {
                lock.withLock { _ = names.removeValue(forKey: retract.firstChild(name: "item")?.attribute("id") ?? "") }
            }
            return FakeWire.result(to: iq)
        }
    }

    private func read(_ items: Element, _ iq: Iq) -> Iq {
        let node = items.attribute("node") ?? ""
        let list = Element(name: "items", attributes: ["node": node])
        lock.withLock {
            switch node {
            case NS.avatarMetadata:
                let metadata = Element(name: "metadata", xmlns: NS.avatarMetadata)
                if let currentAvatar {
                    metadata.addChild(Element(name: "info", attributes: ["id": currentAvatar, "bytes": "1", "type": "image/png"]))
                }
                let item = Element(name: "item", attributes: ["id": currentAvatar ?? "empty"])
                item.addChild(metadata)
                list.addChild(item)
            case NS.nick:
                let all = names.sorted(by: { $0.key < $1.key })
                let wanted = items.attribute("max_items").flatMap(Int.init).map { all.suffix($0) } ?? all[...]
                for (id, name) in wanted {
                    let item = Element(name: "item", attributes: ["id": id])
                    item.addChild(ProfileStanza.nick(name))
                    list.addChild(item)
                }
            default: break
            }
        }
        let result = Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        result.addChild(list)
        return FakeWire.result(to: iq, result)
    }

    private func handlePublish(_ publish: Element, _ iq: Iq) -> Iq {
        let node = publish.attribute("node") ?? ""
        let item = publish.firstChild(name: "item")
        let id = item?.attribute("id")
        let (failure, hook): ((condition: String, type: String)?, (@Sendable () -> Void)?) = lock.withLock { (self.failure, self.hook) }
        if let failure { return FakeWire.error(to: iq, condition: failure.condition, type: failure.type) }
        lock.withLock {
            published.append((node, id))
            switch node {
            case NS.avatarMetadata: currentAvatar = item?.firstChild(name: "metadata")?.firstChild(name: "info")?.attribute("id")
            case NS.nick: names = [id ?? "": item?.firstChild(name: "nick")?.value ?? ""]
            default: break
            }
        }
        hook?()
        return FakeWire.result(to: iq)
    }
}

struct OwedProfileTests {
    private let db: AppDatabase
    private let session: XMPPSession
    private let wire = FakeWire()
    fileprivate let server = ProfilePEPServer()

    private static let base = String(repeating: "a", count: 40)
    private let small: Data
    private let large: Data

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(me, database: db)
        session.lock.withLock { $0.retryBackoff = 0 }
        small = try AvatarImages.png(side: 8)
        large = try AvatarImages.png(side: 16)
    }

    private func connect(_ session: XMPPSession? = nil, wire: FakeWire? = nil) {
        let wire = wire ?? self.wire
        server.attach(to: wire)
        (session ?? self.session).connectForTesting(wire)
    }

    private func send(_ session: XMPPSession? = nil) async {
        await (session ?? self.session).sendOwedProfile()?.value
    }

    private var avatarHash: String? { try? db.contact(me)?.avatarHash }

    /// Makes `data` the picture the server and this device both have.
    private func serverHolds(_ data: Data) throws -> String {
        let hash = AvatarStore.hash(of: data)
        #expect(session.avatars.save(data, hash: hash))
        try db.setAvatarHash(hash, for: me)
        server.avatar = hash
        return hash
    }

    private func warning(_ key: String) -> AccountWarning? { session.warnings.current.first { $0.key == key } }

    // MARK: Avatar

    @Test func anAvatarSetOfflineShowsAtOnceAndIsPublishedOnceConnected() async throws {
        try db.setAvatarHash(Self.base, for: me)
        server.avatar = Self.base

        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        let hash = AvatarStore.hash(of: small)
        #expect(avatarHash == hash)
        #expect(session.avatarPending)
        #expect(server.publishes.isEmpty)

        connect()
        await send()

        #expect(server.publishes.map(\.node) == [NS.avatarData, NS.avatarMetadata])
        #expect(server.publishes.compactMap(\.id) == [hash, hash])
        #expect(!session.avatarPending)
        #expect(avatarHash == hash)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func anAvatarChangedOnAnotherDeviceMeanwhileWinsAndIsToldSo() async throws {
        let theirs = try serverHolds(large)
        try db.setAvatarHash(Self.base, for: me)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        #expect(avatarHash == AvatarStore.hash(of: small))

        connect()
        await send()

        #expect(server.publishes.isEmpty)
        #expect(avatarHash == theirs)
        #expect(!session.avatarPending)
        let notice = try #require(warning("profile/avatar"))
        #expect(notice.retry == nil)
    }

    @Test func removingTheAvatarOfflineTakesItBackOnceConnected() async throws {
        _ = try serverHolds(large)
        try await session.removeAvatar()
        #expect(avatarHash == nil)
        #expect(session.avatarPending)

        connect()
        await send()

        #expect(server.publishes.count == 1)
        #expect(server.publishes.first?.node == NS.avatarMetadata)
        #expect(server.avatar == nil)
        #expect(!session.avatarPending)
        #expect(avatarHash == nil)
    }

    @Test func removingTheAvatarIsDroppedWhenAnotherDeviceChangedItMeanwhile() async throws {
        try db.setAvatarHash(Self.base, for: me)
        try await session.removeAvatar()
        let theirs = AvatarStore.hash(of: small)
        #expect(session.avatars.save(small, hash: theirs))
        server.avatar = theirs

        connect()
        await send()

        #expect(server.publishes.isEmpty)
        #expect(avatarHash == theirs)
        #expect(warning("profile/avatar") != nil)
    }

    @Test func aSecondAvatarChangeKeepsTheFirstOnesBase() async throws {
        try db.setAvatarHash(Self.base, for: me)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        try await session.publishAvatar(large, mimeType: "image/png", width: 16, height: 16)
        #expect(try db.owedAvatarChange()?.base == Self.base)
        #expect(try db.owedAvatarChange()?.image?.hash == AvatarStore.hash(of: large))
        try await session.removeAvatar()
        #expect(try db.owedAvatarChange()?.base == Self.base)
        #expect(try db.owedAvatarChange()?.image == nil)
    }

    @Test func anAvatarRefusedForGoodIsPutBackWithARetry() async throws {
        let before = try serverHolds(large)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        server.fail("forbidden", type: "auth")

        connect()
        await send()

        #expect(avatarHash == before)
        #expect(!session.avatarPending)
        #expect(warning("profile/avatar")?.retry != nil)

        server.recover()
        #expect(await session.warnings.retry("profile/avatar"))
        #expect(server.avatar == AvatarStore.hash(of: small))
        #expect(avatarHash == AvatarStore.hash(of: small))
        #expect(session.warnings.current.isEmpty)
    }

    @Test func anAvatarThatPassesStaysOwed() async throws {
        _ = try serverHolds(large)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        server.fail("remote-server-timeout", type: "wait")

        connect()
        await send()

        #expect(session.avatarPending)
        #expect(avatarHash == AvatarStore.hash(of: small))
        #expect(session.warnings.current.isEmpty)

        server.recover()
        await send()
        #expect(server.avatar == AvatarStore.hash(of: small))
        #expect(!session.avatarPending)
    }

    @Test func anOwnAvatarNotificationDoesNotReplaceOneThatIsOwed() async throws {
        let theirs = try serverHolds(large)
        try db.setAvatarHash(Self.base, for: me)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)

        session.pepAvatarChanged(me, info: [PEPUserAvatarModule.Info(id: theirs, size: 1, mimeType: "image/png", height: 16, width: 16)])
        #expect(avatarHash == AvatarStore.hash(of: small))

        connect()
        await send()
        #expect(server.publishes.isEmpty)
        #expect(avatarHash == theirs)
    }

    // MARK: Nickname

    @Test func aNicknameSetOfflineShowsAtOnceAndIsPublishedOnceConnected() async throws {
        try db.setSetting(.nickname, "Old")
        server.nicks = ["current": "Old"]

        try await session.setNickname("Ada")
        #expect(session.nickname == "Ada")
        #expect(session.nicknamePending)
        #expect(server.publishes.isEmpty)

        connect()
        await send()

        #expect(server.nicks == ["current": "Ada"])
        #expect(!session.nicknamePending)
        #expect(session.nickname == "Ada")
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aNicknameChangedOnAnotherDeviceMeanwhileWinsAndIsToldSo() async throws {
        try db.setSetting(.nickname, "Old")
        try await session.setNickname("Ada")
        server.nicks = ["current": "Grace"]

        connect()
        await send()

        #expect(server.publishes.isEmpty)
        #expect(session.nickname == "Grace")
        #expect(!session.nicknamePending)
        #expect(try #require(warning("profile/nickname")).retry == nil)
    }

    @Test func aBlankNicknameSetOfflineTakesBackEveryItemOnceConnected() async throws {
        try db.setSetting(.nickname, "Ada")
        server.nicks = ["current": "Ada", "other-client": "Ada"]

        try await session.setNickname("  ")
        #expect(session.nickname == nil)
        #expect(session.nicknamePending)

        connect()
        await send()

        #expect(server.nicks.isEmpty)
        #expect(!session.nicknamePending)
        #expect(session.nickname == nil)
    }

    @Test func aBlankNicknameIsDroppedWhenAnotherDeviceChangedItMeanwhile() async throws {
        try db.setSetting(.nickname, "Ada")
        try await session.setNickname(nil)
        server.nicks = ["current": "Grace"]

        connect()
        await send()

        #expect(server.nicks == ["current": "Grace"])
        #expect(session.nickname == "Grace")
        #expect(warning("profile/nickname") != nil)
    }

    @Test func aSecondNicknameChangeKeepsTheFirstOnesBase() async throws {
        try db.setSetting(.nickname, "Old")
        try await session.setNickname("A")
        try await session.setNickname("B")
        #expect(try db.owedNicknameChange() == OwedNicknameChange(value: "B", base: "Old"))
    }

    @Test func aChangeMadeWhileOneIsBeingSentIsBasedOnWhatWasSent() async throws {
        server.onPublish { [db, session] in
            try? db.queueNicknameChange("B")
            session.sendOwedProfile()
        }
        try await session.setNickname("A")
        connect()
        await send()

        #expect(await eventually { server.nicks == ["current": "B"] && !session.nicknamePending })
        #expect(session.nickname == "B")
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aNicknameRefusedForGoodIsPutBackWithARetry() async throws {
        try db.setSetting(.nickname, "Old")
        server.nicks = ["current": "Old"]
        try await session.setNickname("New")
        server.fail("forbidden", type: "auth")

        connect()
        await send()

        #expect(session.nickname == "Old")
        #expect(!session.nicknamePending)
        #expect(warning("profile/nickname")?.retry != nil)

        // Refused again, so it stays shown, not cleared.
        #expect(await !session.warnings.retry("profile/nickname"))
        #expect(warning("profile/nickname") != nil)
        #expect(session.nickname == "Old")

        server.recover()
        #expect(await session.warnings.retry("profile/nickname"))
        #expect(server.nicks == ["current": "New"])
        #expect(session.nickname == "New")
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aNicknameThatPassesStaysOwed() async throws {
        try await session.setNickname("New")
        server.fail("remote-server-timeout", type: "wait")

        connect()
        await send()

        #expect(session.nicknamePending)
        #expect(session.nickname == "New")
        #expect(session.warnings.current.isEmpty)

        server.recover()
        await send()
        #expect(server.nicks == ["current": "New"])
        #expect(!session.nicknamePending)
    }

    @Test func anOwnNicknameNotificationDoesNotReplaceOneThatIsOwed() async throws {
        try await session.setNickname("Mine")
        session.nicknameChanged(me, to: "Theirs")
        #expect(session.nickname == "Mine")

        connect()
        await send()
        session.nicknameChanged(me, to: "Theirs")
        #expect(session.nickname == "Theirs")
    }

    // MARK: Lost answers, unknown bases and retries

    @Test func anAvatarTheServerAlreadyHasFromALostAnswerIsSettledNotRevertedAsAConflict() async throws {
        try db.setAvatarHash(Self.base, for: me)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        let hash = AvatarStore.hash(of: small)
        server.avatar = hash

        connect()
        await send()

        #expect(server.publishes.isEmpty)
        #expect(!session.avatarPending)
        #expect(avatarHash == hash)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aNicknameTheServerAlreadyHasFromALostAnswerIsSettledNotRevertedAsAConflict() async throws {
        try db.setSetting(.nickname, "Old")
        try await session.setNickname("Ada")
        server.nicks = ["current": "Ada"]

        connect()
        await send()

        #expect(server.publishes.isEmpty)
        #expect(!session.nicknamePending)
        #expect(session.nickname == "Ada")
        #expect(session.warnings.current.isEmpty)
    }

    @Test func anAvatarChangedBeforeOursWasEverReadIsSentRatherThanTakenForAConflict() async throws {
        _ = try serverHolds(large)
        try db.setAvatarHash(nil, for: me)
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        #expect(try db.owedAvatarChange()?.baseKnown == false)

        connect()
        await send()

        #expect(server.avatar == AvatarStore.hash(of: small))
        #expect(!session.avatarPending)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aNicknameChangedBeforeOursWasEverReadIsSentRatherThanTakenForAConflict() async throws {
        server.nicks = ["current": "Old"]
        try await session.setNickname("Ada")
        #expect(try db.owedNicknameChange()?.baseKnown == false)

        connect()
        await send()

        #expect(server.nicks == ["current": "Ada"])
        #expect(!session.nicknamePending)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func noAvatarKnownToBeNoneIsStillCheckedAgainstTheServer() async throws {
        try db.markOwnAvatarRead()
        try db.markOwnNicknameRead()
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        try await session.setNickname("Ada")
        #expect(try db.owedAvatarChange()?.baseKnown == true)
        #expect(try db.owedNicknameChange()?.baseKnown == true)
        server.avatar = AvatarStore.hash(of: large)
        server.nicks = ["current": "Grace"]

        connect()
        await send()

        #expect(server.publishes.isEmpty)
        #expect(warning("profile/avatar") != nil)
        #expect(warning("profile/nickname") != nil)
    }

    @Test func aChangeStoredBeforeBasesCouldBeUnknownIsStillKnown() throws {
        let avatar = try JSONDecoder().decode(OwedAvatarChange.self, from: Data(#"{"base":"abc"}"#.utf8))
        #expect(avatar == OwedAvatarChange(image: nil, base: "abc"))
        let nickname = try JSONDecoder().decode(OwedNicknameChange.self, from: Data(#"{"value":"A"}"#.utf8))
        #expect(nickname == OwedNicknameChange(value: "A", base: nil))
        #expect(avatar.baseKnown && nickname.baseKnown)
    }

    @Test func theNicknameIsComparedOnTheNewestItemLikeTheBaseIs() async throws {
        try db.setSetting(.nickname, "New")
        try await session.setNickname("Ada")
        server.nicks = ["a-old": "Old", "b-new": "New"]

        connect()
        await send()

        #expect(server.publishes.map(\.node) == [NS.nick])
        #expect(!session.nicknamePending)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func retryingARefusedAvatarWhoseOldPictureIsNotStoredKeepsTheBase() async throws {
        try db.setAvatarHash(Self.base, for: me)
        server.avatar = Self.base
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)
        server.fail("forbidden", type: "auth")

        connect()
        await send()

        #expect(avatarHash == nil)
        #expect(warning("profile/avatar")?.retry != nil)

        server.recover()
        #expect(await session.warnings.retry("profile/avatar"))
        #expect(server.avatar == AvatarStore.hash(of: small))
        #expect(session.warnings.current.isEmpty)
    }

    @Test func retryingARefusedNicknameKeepsAnUnknownBase() async throws {
        server.nicks = ["current": "Theirs"]
        try await session.setNickname("New")
        server.fail("forbidden", type: "auth")

        connect()
        await send()
        #expect(session.nickname == nil)

        server.recover()
        #expect(await session.warnings.retry("profile/nickname"))
        #expect(server.nicks == ["current": "New"])
    }

    // MARK: Sending

    @Test func whatIsOwedSurvivesANewSession() async throws {
        try await session.setNickname("Ada")
        try await session.publishAvatar(small, mimeType: "image/png", width: 8, height: 8)

        let next = try XMPPSession(
            credentials: .init(jid: me, password: "x"), resource: "t", database: db, avatars: session.avatars, mode: .app,
            identityKeys: testIdentityKeys(for: db),
        )
        let nextWire = FakeWire()
        connect(next, wire: nextWire)
        await send(next)

        #expect(server.nicks == ["current": "Ada"])
        #expect(server.avatar == AvatarStore.hash(of: small))
        #expect(!next.nicknamePending)
        #expect(!next.avatarPending)
    }

    @Test func aResumedStreamSendsWhatWasChangedWhileItWasDown() async throws {
        server.attach(to: wire)
        session.client.writer = wire
        try await session.setNickname("Ada")
        #expect(server.publishes.isEmpty)

        session.client.update(state: .connected(resumed: true))

        #expect(await eventually { server.nicks == ["current": "Ada"] })
    }

    @Test func anExtensionLeavesItToTheApp() async throws {
        let quiet = try makeSession(me, database: db, mode: .notificationService)
        try await quiet.setNickname("Ada")
        connect(quiet)
        #expect(quiet.sendOwedProfile() == nil)
        _ = await eventually(timeout: 0.3) { false }
        #expect(server.publishes.isEmpty)
        #expect(quiet.nicknamePending)
    }
}
