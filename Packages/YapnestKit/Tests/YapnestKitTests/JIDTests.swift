import Testing
@testable import YapnestKit

struct JIDTests {
    @Test func normalizesCaseAndStripsResource() {
        let jid = JID("Alice@Example.ORG/phone")
        #expect(jid?.description == "alice@example.org")
        #expect(jid == JID("alice@example.org"))
    }

    @Test func domainOnly() {
        #expect(JID("conference.example.org")?.localPart == nil)
    }

    @Test(arguments: ["", "@example.org", "alice@", "a@b@c", "/res"])
    func rejectsInvalid(_ string: String) {
        #expect(JID(string) == nil)
    }

    @Test(arguments: ["xmpp:a@b.c?join", " xmpp://a@b.c ", "a@b.c", "XMPP:a@b.c", "xmpp:a@b.c?message;body=hi"])
    func aPastedAddressIsReadWhateverItsWrapping(_ text: String) {
        #expect(JID(pastedAddress: text)?.description == "a@b.c")
    }

    @Test(arguments: ["xmpp:", "xmpp:?join", "  ", "b.c", "xmpp:b.c"])
    func aPastedAddressWithoutAnAccountIsRefused(_ text: String) {
        #expect(JID(pastedAddress: text) == nil)
    }

    @Test(arguments: ["whatsapp.xmpp.example.org", " Whatsapp.Xmpp.Example.Org/res ", "xmpp:whatsapp.xmpp.example.org", "xmpp:a.b?message"])
    func aChatAddressMayBeABareDomain(_ text: String) {
        let jid = JID(chatAddress: text)
        #expect(jid?.localPart == nil)
        #expect(jid?.domain.contains(".") == true)
    }

    @Test(arguments: ["alice", "", "  ", ".example.org", "example.org.", "exa mple.org", "a b.c", "xmpp:", "@example.org", "a@b@c"])
    func aChatAddressRefusesWhatIsNoAddress(_ text: String) {
        #expect(JID(chatAddress: text) == nil)
    }

    @Test func aChatAddressStillTakesWhatIsPasted() {
        #expect(JID(chatAddress: "xmpp:Alice@Example.org?join")?.description == "alice@example.org")
    }

    @Test func aPastedAddressStillRefusesABareDomain() {
        #expect(JID(pastedAddress: "whatsapp.xmpp.example.org") == nil)
    }
}
