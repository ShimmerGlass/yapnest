import Martin
import Testing
@testable import YapnestKit

/// The kinds an extension's wake logs, which have to tell a wake its own doing caused from one the
/// contacts' traffic did, without naming anyone.
struct StreamTallyTests {
    private let account = YapnestKit.JID("alice@example.org")!
    private let room = YapnestKit.JID("room@muc.example.org")!

    private func kind(_ xml: String) throws -> StreamTally.Kind? {
        let element = try #require(Element.from(string: xml))
        return StreamTally.kind(of: element, account: account, isRoom: { $0 == room })
    }

    @Test func presencesAreToldApartByWhoSentThem() throws {
        #expect(try kind("<presence from='alice@example.org/mac' type='unavailable'/>") == .ownPresence)
        #expect(try kind("<presence from='room@muc.example.org/bob'/>") == .roomPresence)
        #expect(try kind("<presence from='bob@example.org/phone'/>") == .contactPresence)
        #expect(try kind("<presence from='eve@example.org' type='subscribe'/>") == .subscription)
    }

    @Test func pubsubEventsAreToldApartByNode() throws {
        func event(_ node: String) -> String {
            "<message from='bob@example.org'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='\(node)'/></event></message>"
        }
        #expect(try kind(event("eu.siacs.conversations.axolotl.devicelist")) == .omemoDevices)
        #expect(try kind(event("eu.siacs.conversations.axolotl.bundles:42")) == .omemoBundle)
        #expect(try kind(event("urn:xmpp:avatar:metadata")) == .avatar)
        #expect(try kind(event("urn:xmpp:bookmarks:1")) == .bookmarks)
        #expect(try kind(event("urn:example:other")) == .otherEvent)
    }

    @Test func messagesAreToldApartByWhatTheyCarry() throws {
        #expect(try kind("<message from='bob@example.org/p' type='chat'><body>hi</body></message>") == .chat)
        #expect(try kind("<message from='bob@example.org/p'><encrypted xmlns='eu.siacs.conversations.axolotl'/></message>") == .encrypted)
        #expect(try kind("<message from='bob@example.org/p'><received xmlns='urn:xmpp:receipts' id='x'/></message>") == .receipt)
        #expect(try kind("<message from='bob@example.org/p'><active xmlns='http://jabber.org/protocol/chatstates'/></message>") == .chatState)
        #expect(try kind("<message from='alice@example.org'><received xmlns='urn:xmpp:carbons:2'/></message>") == .carbon)
        #expect(try kind("<message from='bob@example.org/p'><propose xmlns='urn:xmpp:jingle-message:0' id='s'/></message>") == .call)
        #expect(try kind("<message from='room@muc.example.org/bob' type='groupchat'><body>hi</body></message>") == .groupchat)
        #expect(try kind("<message to='alice@example.org/x'><result xmlns='urn:xmpp:mam:2' queryid='q' id='1'/></message>") == .archive)
    }

    @Test func iqsAreToldApartByType() throws {
        #expect(try kind("<iq type='get' id='1'><ping xmlns='urn:xmpp:ping'/></iq>") == .ping)
        #expect(try kind("<iq type='set' id='2'><query xmlns='jabber:iq:roster'/></iq>") == .iqSet)
        #expect(try kind("<iq type='result' id='3'/>") == .iqResult)
    }

    /// Every wake reads the stream's features, the sign-in's success and stream management's acks alike;
    /// counted, they showed as unknown messages and hid what the wake was for.
    @Test func whatIsNotAStanzaIsNotCounted() throws {
        #expect(try kind("<r xmlns='urn:xmpp:sm:3'/>") == nil)
        #expect(try kind("<resumed xmlns='urn:xmpp:sm:3' h='3' previd='x'/>") == nil)
        #expect(try kind("<features xmlns='http://etherx.jabber.org/streams'/>") == nil)
    }

    @Test func fieldsListOnlyTheKindsSeen() throws {
        let tally = StreamTally()
        let presence = try #require(Element.from(string: "<presence from='bob@example.org/phone'/>"))
        tally.count(presence, account: account, isRoom: { _ in false })
        tally.count(presence, account: account, isRoom: { _ in false })
        #expect(tally.total == 2)
        #expect(tally.count(of: .contactPresence) == 2)
        #expect(tally.fields.count == 1)
    }
}
