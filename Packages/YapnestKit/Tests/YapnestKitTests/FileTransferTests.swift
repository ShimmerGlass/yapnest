import CryptoKit
import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let alice = YapnestKit.JID("alice@example.org")!
private let aliceDevice = "alice@example.org/phone"

private func sha256Base64(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).base64EncodedString()
}

/// A session of ours on a stand-in connection, with alice in the roster, for
/// the Jingle file transfers that come in and go out.
private struct TransferHarness {
    let harness: CallSessionHarness
    var session: XMPPSession { harness.session }
    var wire: FakeWire { harness.wire }
    var database: AppDatabase { harness.database }

    init(withMedia: Bool = false) throws {
        harness = try CallSessionHarness(withMedia: withMedia)
    }

    func offer(
        sid: String = "ft1", from: String = aliceDevice, size: Int, hash: String? = nil, ibb: String = "ibb1", block: Int = 8192,
        senders: String = "initiator", transport: String = "urn:xmpp:jingle:transports:ibb:1", extraContent: String = "", name: String = "photo.png",
    ) -> String {
        let hashElement = hash.map { "<hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>\($0)</hash>" } ?? ""
        return """
        <iq from='\(from)' to='me@example.org/phone' type='set' id='o1'><jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='\(from)' sid='\(sid)'>\
        <content creator='initiator' name='a-file-offer' senders='\(senders)'>\
        <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><media-type>image/png</media-type><name>\(name)</name>\(size >= 0 ? "<size>\(size)</size>" : "")\(hashElement)</file></description>\
        <transport xmlns='\(transport)' block-size='\(block)' sid='\(ibb)'/>\(extraContent)</content></jingle></iq>
        """
    }

    func jingle(_ action: String, sid: String = "ft1", from: String = aliceDevice, inner: String = "") throws {
        try harness.receive(iq: """
        <iq from='\(from)' to='me@example.org/phone' type='set' id='j-\(action)'><jingle xmlns='urn:xmpp:jingle:1' action='\(action)' sid='\(sid)'>\(inner)</jingle></iq>
        """)
    }

    func ibb(_ inner: String, from: String = aliceDevice) throws {
        let iq: Iq = parseStanza("<iq from='\(from)' to='me@example.org/phone' type='set' id='b1'>\(inner)</iq>")
        let module = try #require(session.client.modulesManager.moduleOrNil(IBBModule.IDENTIFIER))
        try module.process(stanza: iq)
    }

    func open(sid: String = "ibb1", block: Int = 8192, from: String = aliceDevice, stanza: String = "iq") throws {
        try ibb("<open xmlns='http://jabber.org/protocol/ibb' sid='\(sid)' block-size='\(block)' stanza='\(stanza)'/>", from: from)
    }

    func data(_ bytes: Data, seq: Int, sid: String = "ibb1", from: String = aliceDevice) throws {
        try ibb("<data xmlns='http://jabber.org/protocol/ibb' sid='\(sid)' seq='\(seq)'>\(bytes.base64EncodedString())</data>", from: from)
    }

    func close(sid: String = "ibb1") throws {
        try ibb("<close xmlns='http://jabber.org/protocol/ibb' sid='\(sid)'/>")
    }

    /// The Jingle iqs written, as (action, to, reason).
    var sent: [(action: String, to: String, reason: String?)] {
        wire.written.compactMap { $0 as? Iq }.compactMap { iq in
            guard let jingle = iq.firstChild(name: "jingle", xmlns: "urn:xmpp:jingle:1") else { return nil }
            return (jingle.getAttribute("action") ?? "", iq.to?.stringValue ?? "", jingle.firstChild(name: "reason")?.children.first?.name)
        }
    }

    func sentAction(_ action: String) -> Iq? {
        wire.written.compactMap { $0 as? Iq }.first { $0.firstChild(name: "jingle", xmlns: "urn:xmpp:jingle:1")?.getAttribute("action") == action }
    }

    /// Results written for incoming iqs.
    var results: [Stanza] { wire.written.filter { $0.type == .result } }

    var attachment: YapnestKit.Attachment? {
        try? database.reader.read { try YapnestKit.Attachment.fetchOne($0) }
    }

    var incomingRows: [YapnestKit.Message] {
        (try? database.reader.read { try YapnestKit.Message.filter(Column("direction") == YapnestKit.Message.Direction.incoming).fetchAll($0) }) ?? []
    }

    func advertiseFileTransfer(features: [String] = JingleFile.requiredFeatures) throws {
        let caps = try #require(session.client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER))
        let presence = Presence()
        presence.from = Martin.JID(aliceDevice)
        presence.addChild(Element(name: "c", attributes: ["xmlns": "http://jabber.org/protocol/caps", "hash": "sha-1", "node": "https://example.org/client", "ver": "abc"]))
        session.client.module(.presence).store.update(presence: presence, for: session.client)
        session.presenceChanged(presence)
        caps.cache.store(node: "https://example.org/client#abc", identity: nil, features: features)
    }
}

struct JingleFileOfferTests {
    private func jingle(_ xml: String) -> Element {
        let iq: Iq = parseStanza("<iq type='set' from='a@b/c' id='1'>\(xml)</iq>")
        return iq.firstChild(name: "jingle")!
    }

    @Test func anOfferRoundTripsWithItsHash() throws {
        let hash = Data(SHA256.hash(data: Data("x".utf8)))
        let offer = JingleFileOffer(
            name: "a.png", mediaType: "image/png", size: 12, date: nil, sha256: hash, ibbSid: "i", blockSize: 4096,
        )
        let iq = offer.sessionInitiate(to: Martin.JID("alice@example.org/phone"), sid: "s", initiator: Martin.JID("me@example.org/phone"))
        let parsed = JingleFileOffer.parse(try #require(iq.firstChild(name: "jingle")))
        #expect(try parsed.get() == offer)
        #expect(JingleFileOffer.isFileOffer(try #require(iq.firstChild(name: "jingle"))))
    }

    @Test func aBlockSizeAboveOursIsLowered() throws {
        let element = jingle("<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='s'><content creator='initiator' name='a' senders='initiator'><description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>a</name><size>3</size></file></description><transport xmlns='urn:xmpp:jingle:transports:ibb:1' block-size='65535' sid='i'/></content></jingle>")
        #expect(try JingleFileOffer.parse(element).get().blockSize == JingleFile.blockSize)
    }

    @Test func aChecksumInSessionInfoIsRead() {
        let hash = Data(SHA256.hash(data: Data("x".utf8)))
        let element = jingle("<jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid='s'><checksum xmlns='urn:xmpp:jingle:apps:file-transfer:5' creator='initiator' name='a'><file><hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>\(hash.base64EncodedString())</hash></file></checksum></jingle>")
        #expect(JingleFileOffer.checksum(in: element) == hash)
        let other = jingle("<jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid='s'><received xmlns='urn:xmpp:jingle:apps:file-transfer:5'/></jingle>")
        #expect(JingleFileOffer.checksum(in: other) == nil)
    }

    @Test func aHashThatIsNotASha256IsIgnored() throws {
        let element = jingle("<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='s'><content creator='initiator' name='a' senders='initiator'><description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>a</name><size>3</size><hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>AAAA</hash></file></description><transport xmlns='urn:xmpp:jingle:transports:ibb:1' block-size='4096' sid='i'/></content></jingle>")
        #expect(try JingleFileOffer.parse(element).get().sha256 == nil)
    }

    @Test func aFileNameCannotLeaveItsFolder() throws {
        let element = jingle("<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='s'><content creator='initiator' name='a' senders='initiator'><description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>../../etc/passwd</name><size>3</size></file></description><transport xmlns='urn:xmpp:jingle:transports:ibb:1' block-size='4096' sid='i'/></content></jingle>")
        #expect(try JingleFileOffer.parse(element).get().name == "passwd")
    }
}

struct FileTransferReceivingTests {
    private let content = Data((0..<20_000).map { UInt8($0 % 251) })

    private func receiveAll(_ h: TransferHarness, blocks: Int = 8192) throws {
        try h.open(block: 8192)
        var seq = 0
        var offset = 0
        while offset < content.count {
            let end = min(offset + blocks, content.count)
            try h.data(content[offset..<end], seq: seq)
            seq += 1
            offset = end
        }
    }

    @Test func anOfferFromAContactIsAcceptedAndReceived() async throws {
        let h = try TransferHarness()
        var events: [XMPPSession.Event] = []
        let subscription = h.session.events.sink { events.append($0) }
        defer { subscription.cancel() }

        try h.harness.receive(iq: h.offer(size: content.count, hash: sha256Base64(content)))
        // The row is the offer's, like a file message.
        let row = try #require(h.incomingRows.first)
        #expect(row.remoteId == "ft1" && row.body.isEmpty && row.encryption == .none && !row.isRead)
        #expect(events.count == 1)
        let offered = try #require(h.attachment)
        #expect(offered.name == "photo.png" && offered.size == Int64(content.count) && offered.url == nil)
        #expect(offered.summary == "📷 Photo")
        #expect(offered.state == .offered)
        // Small enough to take at once.
        let accept = try #require(h.sentAction("session-accept"))
        #expect(accept.to?.stringValue == aliceDevice)
        #expect(accept.firstChild(name: "jingle")?.firstChild(name: "content")?.firstChild(name: "transport")?.getAttribute("sid") == "ibb1")
        #expect(h.results.count == 1)

        try receiveAll(h, blocks: 5000)
        try h.close()
        await eventually("the file to be stored") { h.attachment?.state == .ready }
        let stored = try #require(h.attachment)
        let file = try #require(h.session.attachments.url(for: stored))
        #expect(try Data(contentsOf: file) == content)
        #expect(stored.size == Int64(content.count))
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "success" })
        // No half-written file is left, and the progress is over.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.session.attachments.directory.path)
        #expect(leftovers.allSatisfy { !$0.hasPrefix(AttachmentStore.partialPrefix) })
        #expect(h.session.transfers.value.isEmpty)
    }

    @Test func theFileIsCompleteOnceAllItsBytesArrived() async throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: content.count))
        try receiveAll(h)
        await eventually("the file to be stored") { h.attachment?.state == .ready }
        // The sender's close after it is answered, not refused.
        try h.close()
    }

    @Test func aHashGivenLaterInSessionInfoIsChecked() async throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: content.count))
        try h.jingle("session-info", inner: "<checksum xmlns='urn:xmpp:jingle:apps:file-transfer:5' creator='initiator' name='a-file-offer'><file><hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>\(sha256Base64(Data("other".utf8)))</hash></file></checksum>")
        try receiveAll(h)
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "media-error" })
        await eventually("the offer to end") { h.attachment?.state == .unavailable }
    }

    @Test func aWrongHashFailsTheTransferAndKeepsNothing() async throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: content.count, hash: sha256Base64(Data("other".utf8))))
        try receiveAll(h)
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "media-error" })
        await eventually("the offer to end") { h.attachment?.state == .unavailable }
        #expect(h.attachment?.localFile == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: h.session.attachments.directory.path)
        #expect(files.isEmpty)
        #expect(h.session.transfers.value.isEmpty)
    }

    @Test func aStreamThatEndsShortFails() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: content.count))
        try h.open()
        try h.data(content[0..<100], seq: 0)
        try h.close()
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "media-error" })
    }

    @Test func aGapInTheSequenceFailsTheTransfer() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: content.count))
        try h.open()
        try h.data(content[0..<100], seq: 0)
        #expect(throws: XMPPError.self) { try h.data(content[100..<200], seq: 2) }
        #expect(h.wire.written.contains { ($0 as? Iq)?.firstChild(name: "close", xmlns: "http://jabber.org/protocol/ibb") != nil })
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "failed-transport" })
        #expect(h.attachment?.state == .unavailable)
    }

    @Test func theSequenceWrapsAfter65535() throws {
        let size = 65_537
        let offer = JingleFileOffer(name: "a", mediaType: nil, size: Int64(size), date: nil, sha256: nil, ibbSid: "i", blockSize: 1)
        let ft = FileTransferSession(sid: "s", messageId: 1, role: .receiver, peer: Martin.JID(aliceDevice), offer: offer)
        let file = FileManager.default.temporaryDirectory.appending(path: "ft-wrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try ft.startReceiving(into: file, blockSize: 1)
        #expect(ft.move(from: [.offered], to: .accepted))
        #expect(ft.opened(blockSize: 1))
        for index in 0..<size {
            guard case .accepted(_, let isComplete) = ft.append(seq: index & 0xFFFF, Data([1])) else {
                Issue.record("block \(index) refused")
                return
            }
            #expect(isComplete == (index == size - 1))
        }
        // The sequence starts over at 0 after 65535, so a block that repeats it is broken.
        #expect(ft.append(seq: 0, Data([1])) == .broken)
    }

    @Test func aBlockBiggerThanAgreedFailsTheTransfer() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: 20_000, block: 1024))
        try h.open(block: 1024)
        #expect(throws: XMPPError.self) { try h.data(Data(count: 2048), seq: 0) }
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "failed-transport" })
    }

    @Test func anOpenAskingForMoreThanAgreedIsRefused() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: 20_000, block: 1024))
        #expect(throws: XMPPError.self) { try h.open(block: 4096) }
    }

    @Test func moreBytesThanOfferedFailTheTransfer() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: 10))
        try h.open()
        #expect(throws: XMPPError.self) { try h.data(Data(count: 11), seq: 0) }
    }

    @Test func aStreamFromAnotherDeviceOrOfAnotherSessionIsNotFound() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: 100))
        try h.open()
        #expect(throws: XMPPError.self) { try h.data(Data(count: 10), seq: 0, from: "alice@example.org/tablet") }
        #expect(throws: XMPPError.self) { try h.data(Data(count: 10), seq: 0, sid: "nobody") }
        #expect(throws: XMPPError.self) { try h.close(sid: "nobody") }
        #expect(throws: XMPPError.self) { try h.open(from: "mallory@example.org/x") }
        // The real one is untouched.
        try h.data(Data(count: 10), seq: 0)
    }

    @Test func aStreamOfMessagesIsNotAccepted() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: 100))
        #expect(throws: XMPPError.self) { try h.open(stanza: "message") }
    }

    @Test func aStreamWaitsForTheAccept() throws {
        let h = try TransferHarness()
        h.session.autoAcceptedOfferSize = 10
        try h.harness.receive(iq: h.offer(size: 100))
        #expect(throws: XMPPError.self) { try h.open() }
    }

    // MARK: Turning offers down

    private func turnedDown(_ xml: String, reason: String, row: Bool = false, sourceLine: Int = #line) throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: xml)
        #expect(h.results.count == 1, "answered first")
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == reason }, "\(reason)")
        #expect(!h.sent.contains { $0.action == "session-accept" })
        #expect(h.incomingRows.isEmpty == !row)
    }

    @Test func offersWeCantTakeAreTurnedDownWithTheirReason() throws {
        let h = TransferHarness.self
        _ = h
        let probe = try TransferHarness()
        try turnedDown(probe.offer(size: 10, senders: "both"), reason: "unsupported-applications")
        try turnedDown(probe.offer(size: 10, transport: "urn:xmpp:jingle:transports:s5b:1"), reason: "unsupported-transports")
        try turnedDown(probe.offer(size: 10, extraContent: "<security xmlns='urn:xmpp:jingle:jet:0'/>"), reason: "security-error")
        try turnedDown(probe.offer(size: -1), reason: "decline")
        try turnedDown(probe.offer(size: Int(JingleFile.maxSize) + 1), reason: "decline")
        try turnedDown(probe.offer(from: "bob@example.org/phone", size: 10), reason: "decline")
        try turnedDown(probe.offer(from: "me@example.org/tablet", size: 10), reason: "decline")
        try turnedDown(probe.offer(from: "alice@example.org", size: 10), reason: "decline")
    }

    @Test func aRoomOccupantIsNotAContact() throws {
        let h = try TransferHarness()
        try h.database.writer.write { db in
            try Contact(jid: YapnestKit.JID("room@conference.example.org")!, isInRoster: true).insert(db)
        }
        try turnedDown(h.offer(from: "room@conference.example.org/alice", size: 10), reason: "decline")
    }

    @Test func aRosterItemWithoutASubscriptionIsNotAContact() throws {
        let h = try TransferHarness()
        try h.database.updateRosterItem(jid: alice, name: nil, subscription: .none, isPending: false)
        try h.harness.receive(iq: h.offer(size: 10))
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "decline" })
        #expect(h.sentAction("session-accept") == nil)
        #expect(h.incomingRows.isEmpty)
    }

    @Test(arguments: [Contact.Subscription.to, .from, .both])
    func anApprovedOrSubscribedContactsOfferIsTaken(subscription: Contact.Subscription) throws {
        let h = try TransferHarness()
        try h.database.updateRosterItem(jid: alice, name: nil, subscription: subscription, isPending: false)
        try h.harness.receive(iq: h.offer(size: 10))
        #expect(h.sentAction("session-accept") != nil)
    }

    @Test func aContactTheUserAddedIsTakenEvenBeforeTheyAnswer() throws {
        let h = try TransferHarness()
        try h.database.updateRosterItem(jid: alice, name: nil, subscription: .none, isPending: false)
        try h.database.markAddedByUser(alice)
        try h.harness.receive(iq: h.offer(size: 10))
        #expect(h.sentAction("session-accept") != nil)
    }

    @Test func aRepeatedSessionIdIsAnErrorAndChangesNothing() throws {
        let h = try TransferHarness()
        h.session.autoAcceptedOfferSize = 0
        try h.harness.receive(iq: h.offer(size: 100))
        #expect(throws: XMPPError.self) { try h.harness.receive(iq: h.offer(size: 100)) }
        #expect(h.incomingRows.count == 1)
        #expect(h.results.count == 1)
    }

    @Test func aSessionIdFromAnEarlierLaunchIsAnError() throws {
        let h = try TransferHarness()
        _ = try h.database.insertFileOffer(from: alice, sid: "ft1", offer: JingleFileOffer(name: "a", mediaType: nil, size: 1, date: nil, sha256: nil, ibbSid: "i", blockSize: 10))
        #expect(throws: XMPPError.self) { try h.harness.receive(iq: h.offer(size: 100)) }
        #expect(h.incomingRows.count == 1)
    }

    // MARK: Waiting for the user

    @Test func anOfferAboveTheLimitWaitsUntilItIsTaken() async throws {
        let h = try TransferHarness()
        h.session.autoAcceptedOfferSize = 100
        try h.harness.receive(iq: h.offer(size: content.count, hash: sha256Base64(content)))
        #expect(h.sentAction("session-accept") == nil)
        let waiting = try #require(h.attachment)
        #expect(waiting.state == .offered)

        h.session.download(waiting)
        #expect(h.sentAction("session-accept") != nil)
        try receiveAll(h)
        await eventually("the file to arrive") { h.attachment?.state == .ready }
    }

    @Test func declineTellsTheSenderAndEndsTheOffer() throws {
        let h = try TransferHarness()
        h.session.autoAcceptedOfferSize = 0
        try h.harness.receive(iq: h.offer(size: 100))
        h.session.declineOffer(try #require(h.attachment))
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "decline" })
        #expect(h.attachment?.state == .unavailable)
    }

    @Test func takingAnOfferWhoseSessionIsGoneEndsIt() async throws {
        let h = try TransferHarness()
        _ = try h.database.insertFileOffer(from: alice, sid: "old", offer: JingleFileOffer(name: "a", mediaType: nil, size: 1, date: nil, sha256: nil, ibbSid: "i", blockSize: 10))
        let stale = try #require(h.attachment)
        h.session.download(stale)
        #expect(h.attachment?.state == .unavailable)
        #expect(h.sentAction("session-accept") == nil)
    }

    @Test func theSenderEndingTheSessionEndsTheOffer() throws {
        let h = try TransferHarness()
        h.session.autoAcceptedOfferSize = 0
        try h.harness.receive(iq: h.offer(size: 100))
        let before = h.results.count
        try h.jingle("session-terminate", inner: "<reason><cancel/></reason>")
        #expect(h.results.count == before + 1)
        #expect(h.attachment?.state == .unavailable)
        // Not answered with one of our own.
        #expect(!h.sent.contains { $0.action == "session-terminate" })
    }

    @Test func aDisconnectEndsTheTransfers() throws {
        let h = try TransferHarness()
        try h.harness.receive(iq: h.offer(size: 100))
        try h.open()
        h.session.failFileTransfers()
        #expect(h.attachment?.state == .unavailable)
        #expect(h.session.transfers.value.isEmpty)
    }

    @Test func aStalledTransferTimesOut() async throws {
        let h = try TransferHarness()
        h.session.fileTransfers.timeouts.idle = 0.1
        try h.harness.receive(iq: h.offer(size: 100))
        await eventually("the timeout") { h.attachment?.state == .unavailable }
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "timeout" })
    }

    @Test func offersLeftFromAnEarlierLaunchAreOverWhenTheSessionStarts() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { try Contact(jid: alice, subscription: .both, isInRoster: true).insert($0) }
        let offer = JingleFileOffer(name: "a", mediaType: nil, size: 1, date: nil, sha256: nil, ibbSid: "i", blockSize: 10)
        _ = try database.insertFileOffer(from: alice, sid: "left", offer: offer)
        let attachments = AttachmentStore.temporary()
        try FileManager.default.createDirectory(at: attachments.directory, withIntermediateDirectories: true)
        let partial = attachments.directory.appending(path: AttachmentStore.partialPrefix + "x")
        try Data([1]).write(to: partial)
        defer { try? FileManager.default.removeItem(at: attachments.directory) }
        let session = try XMPPSession(credentials: .init(jid: YapnestKit.JID("me@example.org")!, password: "x"), resource: "phone", database: database, attachments: attachments)
        // What connecting does first.
        session.expireFileOffers()
        await eventually("the sweep") { (try? database.attachment(messageId: 1))?.state == .unavailable }
        await eventually("the leftover to go") { !FileManager.default.fileExists(atPath: partial.path) }
        _ = session
    }

    // MARK: Routing

    @Test func aTerminateForAnUnknownSessionStillGetsItemNotFound() throws {
        let h = try TransferHarness()
        #expect(throws: XMPPError.self) { try h.jingle("session-terminate", sid: "nope", inner: "<reason><success/></reason>") }
    }

    @Test func extensionSessionsTakeNoFileTransfers() throws {
        for mode in [XMPPSession.Mode.share, .notificationService] {
            let session = try XMPPSession(
                credentials: .init(jid: YapnestKit.JID("me@example.org")!, password: "x"), resource: "ext", database: AppDatabase.inMemory(), mode: mode,
            )
            let features = session.client.modulesManager.availableFeatures
            for feature in JingleFile.features { #expect(!features.contains(feature), "\(feature) in \(mode)") }
            #expect(session.client.modulesManager.moduleOrNil(JingleModule.IDENTIFIER) == nil)
            #expect(session.client.modulesManager.moduleOrNil(IBBModule.IDENTIFIER) == nil)
        }
    }

    @Test func theAppAdvertisesFileTransfers() throws {
        for withMedia in [false, true] {
            let h = try TransferHarness(withMedia: withMedia)
            let features = h.session.client.modulesManager.availableFeatures
            for feature in JingleFile.features + ["urn:xmpp:jingle:1"] { #expect(features.contains(feature), "\(feature)") }
            #expect(features.contains("urn:xmpp:jingle:apps:rtp:audio") == withMedia)
        }
    }

    @Test func aCallStillReachesTheCallPath() throws {
        let h = try TransferHarness(withMedia: true)
        // No call was proposed first, so the call layer refuses it as it always did.
        #expect(throws: XMPPError.self) { try h.harness.receive(iq: h.harness.sessionInitiate(sid: "call1")) }
        #expect(h.incomingRows.isEmpty)
        #expect(h.sentAction("session-accept") == nil)
    }
}

/// One at a time: the capabilities cache is read with a blocking `sync` that waits behind a pending
/// store, and a dozen of these at once hold every thread of the pool that store needs.
@Suite(.serialized)
struct FileTransferSendingTests {
    private func makeFile(bytes: Int) throws -> (URL, Data) {
        let data = Data((0..<bytes).map { UInt8(($0 &* 7) % 253) })
        let url = FileManager.default.temporaryDirectory.appending(path: "ft-\(UUID().uuidString).bin")
        try data.write(to: url)
        return (url, data)
    }

    private func outgoing(_ h: TransferHarness, bytes: Int, encrypted: Bool = false) async throws -> (YapnestKit.Message, Data) {
        // Chats are encrypted unless they are set not to be.
        var conversation = try h.database.conversation(with: alice)
        conversation.isEncrypted = encrypted
        try await h.database.writer.write { [conversation] in try conversation.update($0) }
        let (url, data) = try makeFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        // What `sendFile` does, but for donating a share suggestion, which stalls a test process.
        let outgoing = h.session.outgoingMessages
        let file = try await outgoing.prepareFile(at: url, name: "report.bin")
        let message = try outgoing.stage([.file(file)], to: alice)[0]
        h.session.transmit(message, to: alice)
        return (message, data)
    }

    private func status(_ h: TransferHarness) -> YapnestKit.Message? {
        try? h.database.reader.read { try YapnestKit.Message.filter(Column("direction") == YapnestKit.Message.Direction.outgoing).fetchOne($0) }
    }

    private func accept(_ h: TransferHarness, block: Int = 4096) async throws -> Iq {
        await eventually("the offer") { h.sentAction("session-initiate") != nil }
        let initiate = try #require(h.sentAction("session-initiate"))
        let jingle = try #require(initiate.firstChild(name: "jingle"))
        let sid = try #require(jingle.getAttribute("sid"))
        let ibb = try #require(jingle.firstChild(name: "content")?.firstChild(name: "transport")?.getAttribute("sid"))
        try h.harness.receive(iq: """
        <iq from='\(aliceDevice)' to='me@example.org/phone' type='set' id='acc'><jingle xmlns='urn:xmpp:jingle:1' action='session-accept' sid='\(sid)' responder='\(aliceDevice)'>\
        <content creator='initiator' name='a-file-offer' senders='initiator'><description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>report.bin</name></file></description>\
        <transport xmlns='urn:xmpp:jingle:transports:ibb:1' block-size='\(block)' sid='\(ibb)'/></content></jingle></iq>
        """)
        return initiate
    }

    @Test func aFileTooBigForTheServerGoesOverJingleToADeviceThatTakesIt() async throws {
        let h = try TransferHarness()
        try h.advertiseFileTransfer()
        let (message, data) = try await outgoing(h, bytes: 40_000)
        let initiate = try await accept(h)
        let jingle = try #require(initiate.firstChild(name: "jingle"))
        let sid = try #require(jingle.getAttribute("sid"))
        let file = try #require(jingle.firstChild(name: "content")?.firstChild(name: "description")?.firstChild(name: "file"))
        #expect(file.firstChild(name: "size")?.value == "40000")
        #expect(file.firstChild(name: "hash")?.value == sha256Base64(data))
        #expect(initiate.to?.stringValue == aliceDevice)

        await eventually("the stream to close") { h.wire.written.contains { ($0 as? Iq)?.firstChild(name: "close", xmlns: "http://jabber.org/protocol/ibb") != nil } }
        let iqs = h.wire.written.compactMap { $0 as? Iq }
        let open = try #require(iqs.compactMap { $0.firstChild(name: "open", xmlns: "http://jabber.org/protocol/ibb") }.first)
        #expect(open.getAttribute("block-size") == "4096")
        let blocks = iqs.compactMap { $0.firstChild(name: "data", xmlns: "http://jabber.org/protocol/ibb") }
        #expect(blocks.compactMap { $0.getAttribute("seq").flatMap(Int.init) } == Array(0..<blocks.count))
        let bytes = blocks.reduce(into: Data()) { $0.append(Data(base64Encoded: $1.value ?? "")!) }
        #expect(bytes == data)
        #expect(blocks.allSatisfy { (Data(base64Encoded: $0.value ?? "")?.count ?? 0) <= 4096 })
        // Still waiting for the receiver to say it has it.
        #expect(status(h)?.status == .pending)

        try h.jingle("session-terminate", sid: sid, inner: "<reason><success/></reason>")
        await eventually("the message to be delivered") { status(h)?.status == .delivered }
        let attachment = try #require(h.attachment)
        #expect(attachment.state == .ready && attachment.url == nil)
        #expect(status(h)?.id == message.id)
        // Nothing was sent as a message, and it isn't picked up to be resent.
        #expect(h.wire.messages.isEmpty)
        #expect(try h.database.unconfirmedOutgoing(before: .distantFuture, since: .distantPast).isEmpty)
        #expect(h.session.transfers.value.isEmpty)
    }

    @Test func aDeclineFailsTheMessageWithTheReason() async throws {
        let h = try TransferHarness()
        try h.advertiseFileTransfer()
        _ = try await outgoing(h, bytes: 1000)
        await eventually("the offer") { h.sentAction("session-initiate") != nil }
        let sid = try #require(h.sentAction("session-initiate")?.firstChild(name: "jingle")?.getAttribute("sid"))
        try h.jingle("session-terminate", sid: sid, inner: "<reason><decline/></reason>")
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "Declined.")
        #expect(h.attachment?.state == .pendingUpload)
    }

    @Test func noAnswerFailsTheMessage() async throws {
        let h = try TransferHarness()
        h.session.fileTransfers.timeouts.accept = 0.1
        try h.advertiseFileTransfer()
        _ = try await outgoing(h, bytes: 1000)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "No answer from the contact's device.")
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "timeout" })
    }

    @Test func aReceiverThatNeverConfirmsFailsTheMessage() async throws {
        let h = try TransferHarness()
        h.session.fileTransfers.timeouts.confirmation = 0.1
        try h.advertiseFileTransfer()
        _ = try await outgoing(h, bytes: 1000)
        _ = try await accept(h)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "The contact's device didn't confirm it got the file.")
    }

    @Test func aStreamThatIsRefusedFailsTheMessage() async throws {
        let h = try TransferHarness()
        h.wire.answer { iq in
            if iq.firstChild(name: "open", xmlns: "http://jabber.org/protocol/ibb") != nil { return FakeWire.error(to: iq, condition: "not-acceptable") }
            return FakeWire.result(to: iq)
        }
        try h.advertiseFileTransfer()
        _ = try await outgoing(h, bytes: 1000)
        _ = try await accept(h)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "The transfer failed.")
        #expect(h.sent.contains { $0.action == "session-terminate" && $0.reason == "failed-transport" })
    }

    @Test func withoutADeviceThatTakesFilesTheUploadErrorStands() async throws {
        let h = try TransferHarness()
        // A device with Jingle but not file transfers.
        try h.advertiseFileTransfer(features: ["urn:xmpp:jingle:1", JingleFile.application])
        _ = try await outgoing(h, bytes: 1000)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "Your server doesn't support sending files.")
        #expect(h.sentAction("session-initiate") == nil)
    }

    @Test func aContactWhoIsOfflineGetsTheUploadError() async throws {
        let h = try TransferHarness()
        _ = try await outgoing(h, bytes: 1000)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "Your server doesn't support sending files.")
    }

    @Test func anEncryptedMessageNeverGoesOverJingle() async throws {
        let h = try TransferHarness()
        try h.advertiseFileTransfer()
        let (url, _) = try makeFile(bytes: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let stored = try h.session.attachments.save(Data(count: 100), name: "a.bin")
        var message = YapnestKit.Message(conversationId: 1, direction: .outgoing, sender: YapnestKit.JID("me@example.org")!, body: "", encryption: .omemo, remoteId: "m")
        message.id = 1
        let attachment = YapnestKit.Attachment(messageId: 1, url: nil, name: "a.bin", localFile: stored, state: .pendingUpload)
        let handled = await h.session.sendOverJingleInstead(after: XMPPSession.AttachmentError.noUploadService, message, attachment, to: alice)
        #expect(!handled)
        #expect(h.sentAction("session-initiate") == nil)
        // The same message, unencrypted, does.
        message.encryption = .none
        let handledPlain = await h.session.sendOverJingleInstead(after: XMPPSession.AttachmentError.noUploadService, message, attachment, to: alice)
        #expect(handledPlain)
        #expect(h.sentAction("session-initiate") != nil)
    }

    @Test func anEncryptedChatIsNotSentOverJingleEvenToADeviceThatCould() async throws {
        let h = try TransferHarness()
        try h.advertiseFileTransfer()
        _ = try await outgoing(h, bytes: 1000, encrypted: true)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.encryption == .omemo)
        #expect(status(h)?.error == "Your server doesn't support sending files.")
        #expect(h.sentAction("session-initiate") == nil)
    }

    @Test func noMoreThanTheWindowIsSentBeforeAcknowledgements() async throws {
        let h = try TransferHarness()
        h.wire.answer { iq in
            // Blocks are never acknowledged.
            iq.firstChild(name: "data", xmlns: "http://jabber.org/protocol/ibb") != nil ? nil : FakeWire.result(to: iq)
        }
        try h.advertiseFileTransfer()
        _ = try await outgoing(h, bytes: 100_000)
        _ = try await accept(h)
        func dataCount() -> Int { h.wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "data", xmlns: "http://jabber.org/protocol/ibb") != nil }.count }
        await eventually("the window to fill") { dataCount() == XMPPSession.fileTransferWindow }
        try await Task.sleep(for: .milliseconds(200))
        #expect(dataCount() == XMPPSession.fileTransferWindow)
        // A dropped connection ends it, and the message with it.
        h.session.failFileTransfers()
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error == "The transfer was interrupted.")
    }

    @Test func otherUploadErrorsAreNotRetriedOverJingle() async throws {
        let h = try TransferHarness()
        try h.advertiseFileTransfer()
        let stored = try h.session.attachments.save(Data(count: 100), name: "a.bin")
        var message = YapnestKit.Message(conversationId: 1, direction: .outgoing, sender: YapnestKit.JID("me@example.org")!, body: "", remoteId: "m")
        message.id = 1
        let attachment = YapnestKit.Attachment(messageId: 1, url: nil, name: "a.bin", localFile: stored, state: .pendingUpload)
        let handled = await h.session.sendOverJingleInstead(after: XMPPSession.AttachmentError.uploadFailed("boom"), message, attachment, to: alice)
        #expect(!handled)
    }

    @Test func aFileOverTheLimitIsNotReadJustToFail() async throws {
        let h = try TransferHarness()
        h.wire.answer { iq in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items") != nil {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                query.addChild(Element(name: "item", attributes: ["jid": "upload.example.org"]))
                return FakeWire.result(to: iq, query)
            }
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                let result = FakeWire.discoInfo(to: iq, category: "store", type: "file", features: ["urn:xmpp:http:upload:0"])
                let form = Element(name: "x", attributes: ["xmlns": "jabber:x:data", "type": "result"])
                for (name, value) in [("FORM_TYPE", "urn:xmpp:http:upload:0"), ("max-file-size", "500")] {
                    let field = Element(name: "field", attributes: ["var": name])
                    field.addChild(Element(name: "value", cdata: value))
                    form.addChild(field)
                }
                result.firstChild(name: "query")?.addChild(form)
                return result
            }
            return FakeWire.result(to: iq)
        }
        _ = try await outgoing(h, bytes: 1000)
        await eventually("the failure") { status(h)?.status == .failed }
        #expect(status(h)?.error?.hasPrefix("The file is too large.") == true)
    }
}
