import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func signal(_ xml: String, source: InboundMessage.Source = .live) -> CallSignal? {
    CallSignal(parseStanza(xml) as Martin.Message, account: me, source: source)
}

private func wrap(_ child: String, from: String = "alice@example.org/phone", to: String = "me@example.org", extra: String = "") -> String {
    "<message from='\(from)' to='\(to)' type='chat' id='m1'>\(child)\(extra)<store xmlns='urn:xmpp:hints'/></message>"
}

private let audio = "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>"

struct CallSignalTests {
    @Test func aProposeNamesItsMedia() throws {
        let parsed = try #require(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'>\(audio)</propose>")))
        #expect(parsed.sid == "s1")
        #expect(parsed.action == .propose(media: [.audio]))
        #expect(parsed.sender == alice)
        #expect(parsed.peer == alice)
        #expect(parsed.from == "alice@example.org/phone")
        #expect(!parsed.isFromAccount)

        let video = try #require(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'>\(audio)<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='video'/></propose>")))
        #expect(video.action == .propose(media: [.audio, .video]))
    }

    @Test func aProposeOfSomethingElseIsNotACall() {
        #expect(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'><description xmlns='urn:xmpp:jingle:apps:file-transfer:5'/></propose>")) == nil)
        #expect(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'/>")) == nil)
        #expect(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'><description xmlns='urn:xmpp:jingle:apps:rtp:1' media='hologram'/></propose>")) == nil)
    }

    @Test func eachActionIsRecognised() throws {
        let cases: [(String, CallSignal.Action)] = [
            ("ringing", .ringing), ("proceed", .proceed), ("accept", .accept),
            ("reject", .reject(nil)), ("retract", .retract(nil)), ("finish", .finish(nil)),
        ]
        for (name, action) in cases {
            let parsed = try #require(signal(wrap("<\(name) xmlns='urn:xmpp:jingle-message:0' id='s9'/>")), "\(name)")
            #expect(parsed.action == action, "\(name)")
            #expect(parsed.sid == "s9")
        }
    }

    @Test func aMessageWithoutAnIdIsNotUsable() {
        #expect(signal(wrap("<proceed xmlns='urn:xmpp:jingle-message:0'/>")) == nil)
        #expect(signal(wrap("<proceed xmlns='urn:xmpp:jingle-message:0' id=''/>")) == nil)
        let long = String(repeating: "x", count: CallSignal.maxSessionIdLength + 1)
        #expect(signal(wrap("<proceed xmlns='urn:xmpp:jingle-message:0' id='\(long)'/>")) == nil)
    }

    @Test func anOrdinaryMessageIsNotACall() {
        #expect(signal("<message from='alice@example.org/phone' type='chat'><body>hi</body></message>") == nil)
    }

    @Test func conversationsProceedWithADeviceIsRead() throws {
        // Conversations' proceed names the device for DTLS verification (a later stage).
        let device = "<device xmlns='http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification' id='1234'/>"
        let parsed = try #require(signal(wrap("<proceed xmlns='urn:xmpp:jingle-message:0' id='s1'>\(device)</proceed>", from: "alice@example.org/phone")))
        #expect(parsed.action == .proceed)
    }

    @Test func reasonsAreRead() throws {
        let reasons = ["success", "decline", "busy", "cancel", "connectivity-error", "failed-application", "general-error", "timeout", "gone"]
        for name in reasons {
            let xml = wrap("<finish xmlns='urn:xmpp:jingle-message:0' id='s'><reason xmlns='urn:xmpp:jingle:1'><\(name)/><text>why</text></reason></finish>")
            let parsed = try #require(signal(xml))
            #expect(parsed.action == .finish(CallReason(rawValue: name)), "\(name)")
        }
        let retract = try #require(signal(wrap("<retract xmlns='urn:xmpp:jingle-message:0' id='s'><reason xmlns='urn:xmpp:jingle:1'><cancel/><text>Retracted</text></reason></retract>")))
        #expect(retract.action == .retract(.cancel))
        let reject = try #require(signal(wrap("<reject xmlns='urn:xmpp:jingle-message:0' id='s'><reason xmlns='urn:xmpp:jingle:1'><busy/></reason></reject>")))
        #expect(reject.action == .reject(.busy))
        let unknown = try #require(signal(wrap("<finish xmlns='urn:xmpp:jingle-message:0' id='s'><reason xmlns='urn:xmpp:jingle:1'><alternative-session/></reason></finish>")))
        #expect(unknown.action == .finish(nil))
    }

    @Test func aCarbonOfWhatWeSentIsOurs() throws {
        let sent = try #require(signal(
            wrap("<proceed xmlns='urn:xmpp:jingle-message:0' id='s1'/>", from: "me@example.org/tablet", to: "alice@example.org/phone"),
            source: .carbon(sent: true),
        ))
        #expect(sent.isFromAccount)
        #expect(sent.sender == me)
        #expect(sent.peer == alice)
        #expect(sent.impliedDirection == .incoming)
    }

    @Test func anAcceptToOurselvesNamesNoPeer() throws {
        let accept = try #require(signal(wrap("<accept xmlns='urn:xmpp:jingle-message:0' id='s1'/>", from: "me@example.org/tablet", to: "me@example.org")))
        #expect(accept.isFromAccount)
        #expect(accept.peer == nil)
    }

    @Test func aReceivedCarbonIsTheirs() throws {
        let received = try #require(signal(wrap("<ringing xmlns='urn:xmpp:jingle-message:0' id='s1'/>"), source: .carbon(sent: false)))
        #expect(!received.isFromAccount)
        #expect(received.peer == alice)
    }

    @Test func theArchiveGivesTheTime() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = try #require(signal(wrap("<retract xmlns='urn:xmpp:jingle-message:0' id='s1'/>"), source: .archive(serverId: "a1", timestamp: at)))
        #expect(parsed.timestamp == at)
    }

    @Test func aDelayFromOurServerIsTrusted() throws {
        let delay = "<delay xmlns='urn:xmpp:delay' from='example.org' stamp='2024-01-01T10:00:00Z'/>"
        let parsed = try #require(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'>\(audio)</propose>", extra: delay)))
        #expect(parsed.timestamp == Date(timeIntervalSince1970: 1_704_103_200))
        // Anyone else's delay is only a claim.
        let forged = "<delay xmlns='urn:xmpp:delay' from='evil.example' stamp='2024-01-01T10:00:00Z'/>"
        let other = try #require(signal(wrap("<propose xmlns='urn:xmpp:jingle-message:0' id='s1'>\(audio)</propose>", extra: forged)))
        #expect(other.timestamp != parsed.timestamp)
    }

    @Test func aReceiptForAProposeNamesItsCall() {
        let receipt: Martin.Message = parseStanza("<message from='alice@example.org/phone' type='chat'><received xmlns='urn:xmpp:receipts' id='jm-propose-s7'/></message>")
        #expect(CallSignal.proposeReceipt(in: receipt) == "s7")
        let other: Martin.Message = parseStanza("<message from='alice@example.org/phone' type='chat'><received xmlns='urn:xmpp:receipts' id='x'/></message>")
        #expect(CallSignal.proposeReceipt(in: other) == nil)
    }
}

struct CallMessageTests {
    private func xml(_ message: CallMessage) -> Martin.Message {
        OutboundStanza.call(message, sid: "s1")
    }

    @Test func proposeGoesToTheBareAddressAndAsksForAReceipt() throws {
        let message = xml(.propose(to: "alice@example.org", video: false))
        #expect(message.type == .chat)
        #expect(message.to?.stringValue == "alice@example.org")
        #expect(message.id == "jm-propose-s1")
        let propose = try #require(message.firstChild(name: "propose", xmlns: "urn:xmpp:jingle-message:0"))
        #expect(propose.getAttribute("id") == "s1")
        let description = try #require(propose.firstChild(name: "description", xmlns: "urn:xmpp:jingle:apps:rtp:1"))
        #expect(description.getAttribute("media") == "audio")
        #expect(propose.getChildren(name: "description").count == 1)
        #expect(message.firstChild(name: "request", xmlns: "urn:xmpp:receipts") != nil)
        #expect(message.firstChild(name: "store", xmlns: "urn:xmpp:hints") != nil)
    }

    @Test func aVideoProposeHasADescriptionForEachMedium() throws {
        let message = xml(.propose(to: "alice@example.org", video: true))
        let propose = try #require(message.firstChild(name: "propose", xmlns: "urn:xmpp:jingle-message:0"))
        let descriptions = propose.getChildren(name: "description", xmlns: "urn:xmpp:jingle:apps:rtp:1")
        #expect(descriptions.compactMap { $0.getAttribute("media") } == ["audio", "video"])
    }

    @Test func proceedGoesToTheCallersDevice() {
        let message = xml(.proceed(to: "alice@example.org/phone"))
        #expect(message.to?.stringValue == "alice@example.org/phone")
        #expect(message.id == "jm-proceed-s1")
        #expect(message.firstChild(name: "proceed", xmlns: "urn:xmpp:jingle-message:0")?.getAttribute("id") == "s1")
        #expect(message.firstChild(name: "store", xmlns: "urn:xmpp:hints") != nil)
        #expect(message.firstChild(name: "request", xmlns: "urn:xmpp:receipts") == nil)
    }

    @Test func eachOtherActionIsBuiltAsConversationsDoes() throws {
        let ringing = xml(.ringing(to: "alice@example.org/phone"))
        #expect(ringing.firstChild(name: "ringing", xmlns: "urn:xmpp:jingle-message:0")?.getAttribute("id") == "s1")

        let accept = xml(.accept(to: "me@example.org"))
        #expect(accept.to?.stringValue == "me@example.org")
        #expect(accept.firstChild(name: "accept", xmlns: "urn:xmpp:jingle-message:0") != nil)

        let retract = xml(.retract(to: "alice@example.org", reason: .cancel))
        let reason = try #require(retract.firstChild(name: "retract", xmlns: "urn:xmpp:jingle-message:0")?.firstChild(name: "reason", xmlns: "urn:xmpp:jingle:1"))
        #expect(reason.firstChild(name: "cancel") != nil)
        #expect(reason.firstChild(name: "text")?.value == "Retracted")

        let reject = xml(.reject(to: "alice@example.org/phone", reason: .busy))
        #expect(reject.firstChild(name: "reject", xmlns: "urn:xmpp:jingle-message:0")?.firstChild(name: "reason")?.firstChild(name: "busy") != nil)

        let finish = xml(.finish(to: "alice@example.org/phone", reason: .success))
        #expect(finish.firstChild(name: "finish", xmlns: "urn:xmpp:jingle-message:0")?.firstChild(name: "reason")?.firstChild(name: "success") != nil)
        for message in [ringing, accept, retract, reject, finish] {
            #expect(message.type == .chat)
            #expect(message.firstChild(name: "store", xmlns: "urn:xmpp:hints") != nil)
            #expect(message.id?.isEmpty == false)
        }
    }

    @Test func whatWeSendWeReadBack() throws {
        let messages: [(CallMessage, CallSignal.Action)] = [
            (.propose(to: "alice@example.org", video: false), .propose(media: [.audio])),
            (.propose(to: "alice@example.org", video: true), .propose(media: [.audio, .video])),
            (.retract(to: "alice@example.org", reason: .timeout), .retract(.timeout)),
            (.ringing(to: "alice@example.org/phone"), .ringing),
            (.proceed(to: "alice@example.org/phone"), .proceed),
            (.accept(to: "me@example.org"), .accept),
            (.reject(to: "alice@example.org/phone", reason: .decline), .reject(.decline)),
            (.finish(to: "alice@example.org/phone", reason: .connectivityError), .finish(.connectivityError)),
        ]
        for (message, action) in messages {
            let stanza = OutboundStanza.call(message, sid: "s1")
            stanza.from = Martin.JID("alice@example.org/phone")
            let parsed = try #require(CallSignal(stanza, account: me, source: .live))
            #expect(parsed.action == action)
            #expect(parsed.sid == "s1")
        }
    }
}
