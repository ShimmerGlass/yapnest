import Foundation
import Testing
@testable import YapnestKit

struct XMPPURITests {
    private func parse(_ string: String) -> XMPPURI? { XMPPURI(string) }
    private func jid(_ string: String) -> JID { JID(string)! }

    @Test func bareAddressOpensAChat() {
        #expect(parse("xmpp:juliet@example.com") == XMPPURI(jid: jid("juliet@example.com"), action: .chat(body: nil)))
    }

    @Test func schemeAndAddressAreCaseInsensitive() {
        #expect(parse("XMPP:Juliet@Example.COM?Message")?.jid == jid("juliet@example.com"))
        #expect(parse("XMPP:Juliet@Example.COM?JOIN")?.action == .join)
    }

    @Test func resourcesAreDropped() {
        #expect(parse("xmpp:a@b.example/res")?.jid == jid("a@b.example"))
        #expect(parse("xmpp:a@b.example/res%20with%20space?message")?.jid == jid("a@b.example"))
    }

    @Test func percentEscapesAreDecoded() {
        #expect(parse("xmpp:juliet%40example.com")?.jid == jid("juliet@example.com"))
        #expect(parse("xmpp:juliet@example.com?message;body=Hello%20there%21%0Anext")?.action == .chat(body: "Hello there!\nnext"))
        // "+" is a plus in a query here, not a space.
        #expect(parse("xmpp:a@b.example?message;body=1+1")?.action == .chat(body: "1+1"))
    }

    @Test func internationalizedAddresses() {
        let escaped = parse("xmpp:%C3%A9l%C3%A9a@exampl%C3%A9.org")
        let raw = parse("xmpp:éléa@examplé.org")
        #expect(escaped?.jid == jid("éléa@examplé.org"))
        #expect(raw == escaped)
        #expect(parse("xmpp:a@xn--bcher-kva.example")?.jid.domain == "xn--bcher-kva.example")
    }

    @Test func messageBodyFillsTheChat() {
        #expect(parse("xmpp:a@b.example?message;body=Hi")?.action == .chat(body: "Hi"))
        #expect(parse("xmpp:a@b.example?message&body=Hi")?.action == .chat(body: "Hi"))
        #expect(parse("xmpp:a@b.example?message")?.action == .chat(body: nil))
        #expect(parse("xmpp:a@b.example?message;body=")?.action == .chat(body: nil))
        // Only a message link has a body.
        #expect(parse("xmpp:a@b.example?body=Hi")?.action == .chat(body: nil))
    }

    @Test(arguments: ["roster", "subscribe"])
    func addingAContact(_ action: String) {
        #expect(parse("xmpp:a@b.example?\(action)")?.action == .addContact(name: nil, preauth: nil))
        #expect(parse("xmpp:a@b.example?\(action);name=Juliet%20C.")?.action == .addContact(name: "Juliet C.", preauth: nil))
    }

    @Test func preauthTokenIsExtracted() {
        #expect(parse("xmpp:a@b.example?roster;preauth=AbC-123_x")?.action == .addContact(name: nil, preauth: "AbC-123_x"))
        // Snikket's invitations carry it after the registration offer.
        #expect(parse("xmpp:a@b.example?roster;ibr=y;preauth=tok123")?.action == .addContact(name: nil, preauth: "tok123"))
        #expect(parse("xmpp:a@b.example?roster;preauth=tok123;ibr=y;name=Al")?.action == .addContact(name: "Al", preauth: "tok123"))
        #expect(parse("xmpp:a@b.example?roster;preauth=")?.action == .addContact(name: nil, preauth: nil))
        // The first one counts.
        #expect(parse("xmpp:a@b.example?roster;preauth=one;preauth=two")?.action == .addContact(name: nil, preauth: "one"))
    }

    @Test func joiningAGroup() {
        #expect(parse("xmpp:room@conference.example?join")?.action == .join)
        #expect(parse("xmpp:room@conference.example?join;password=s%3Bcret")?.action == .join)
    }

    @Test func unknownActionsOpenTheChat() {
        #expect(parse("xmpp:a@b.example?invite;jid=c@d.example")?.action == .chat(body: nil))
        #expect(parse("xmpp:a@b.example?")?.action == .chat(body: nil))
    }

    @Test func aFragmentAndAnAuthorityAreIgnored() {
        #expect(parse("xmpp:a@b.example?join#top")?.action == .join)
        #expect(parse("xmpp://me@home.example/a@b.example?message;body=Hi") == XMPPURI(jid: jid("a@b.example"), action: .chat(body: "Hi")))
        #expect(parse("xmpp://me@home.example") == nil)
    }

    @Test func urlsAreParsedAsTheirText() throws {
        #expect(XMPPURI(try #require(URL(string: "xmpp:a@b.example?roster;preauth=t"))) == parse("xmpp:a@b.example?roster;preauth=t"))
    }

    @Test(arguments: [
        "", "xmpp:", "https://example.com", "a@b.example", "xmpp:?join", "xmpp:example.com", "xmpp:@b.example", "xmpp:a@",
        "xmpp:a@b@c.example", "xmpp:a%20b@c.example", "xmpp:a%2Fb@c.example", "xmpp:a%3Cb@c.example", "xmpp:a'b@c.example",
        "xmpp:a@b.example.", "xmpp:a@.example", "xmpp:a%00@b.example", "xmpp:a%0A@b.example", "xmpp:a\nb@c.example",
        "xmpp:%E2%80%AEa@b.example", "xmpp:a@b.example%E2%80%AE", "xmpp:a@%FF.example", "xmpp:a@b.example?message;body=%FF",
    ])
    func malformedLinksAreRefused(_ string: String) {
        #expect(parse(string) == nil)
    }

    @Test(arguments: [
        "\u{1F469}\u{200D}\u{1F4BB}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}", "co\u{00AD}op",
    ])
    func emojiAndPersianTextIsAccepted(_ text: String) {
        let escaped = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(parse("xmpp:a@b.example?message;body=\(escaped)")?.action == .chat(body: text))
        #expect(parse("xmpp:a@b.example?roster;name=\(escaped)")?.action == .addContact(name: text, preauth: nil))
    }

    @Test(arguments: [
        "202A", "202B", "202C", "202D", "202E", "2066", "2067", "2068", "2069",
        "200E", "200F", "061C", "FFF9", "FFFA", "FFFB",
    ])
    func bidiControlsInTextAreRefused(_ hex: String) {
        #expect(parse("xmpp:a@b.example?message;body=a\(percent(hex))b") == nil)
        #expect(parse("xmpp:a@b.example?roster;name=a\(percent(hex))b") == nil)
    }

    @Test func unassignedCharactersInTextAreAcceptedButNotInAddresses() {
        // A noncharacter stands in for an emoji newer than the system's tables.
        let raw = String(Unicode.Scalar(0xFDD0 as UInt32)!)
        let unassigned = percent("FDD0")
        #expect(parse("xmpp:a@b.example?message;body=hi\(unassigned)")?.action == .chat(body: "hi" + raw))
        #expect(parse("xmpp:a@b.example?roster;name=a\(unassigned)b")?.action == .addContact(name: "a" + raw + "b", preauth: nil))
        #expect(parse("xmpp:a\(unassigned)@b.example") == nil)
        #expect(parse("xmpp:a@b\(unassigned).example") == nil)
    }

    private func percent(_ hex: String) -> String {
        let scalar = Unicode.Scalar(UInt32(hex, radix: 16)!)!
        return String(scalar).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    @Test func injectionIsRefused() {
        #expect(parse("xmpp:a@b.example?message;body=\(String(repeating: "x", count: 2001))") == nil)
        #expect(parse("xmpp:a@b.example?message;body=\(String(repeating: "x", count: 2000))") != nil)
        #expect(parse("xmpp:a@b.example?message;body=hi%00") == nil)
        #expect(parse("xmpp:a@b.example?message;body=hi%1B%5B31m") == nil)
        #expect(parse("xmpp:a@b.example?message;body=%E2%80%AEhi") == nil)
        #expect(parse("xmpp:a@b.example?roster;name=ev%0Ail") == nil)
        #expect(parse("xmpp:a@b.example?roster;name=\(String(repeating: "n", count: 101))") == nil)
        #expect(parse("xmpp:a@b.example?roster;preauth=a%22%20b") == nil)
        #expect(parse("xmpp:a@b.example?roster;preauth=%3C/preauth%3E") == nil)
        #expect(parse("xmpp:a@b.example?roster;preauth=\(String(repeating: "t", count: 257))") == nil)
        #expect(parse("xmpp:a@b.example?" + String(repeating: "x", count: 3000)) == nil)
    }
}
