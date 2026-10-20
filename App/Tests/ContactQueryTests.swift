import Testing
import YapnestKit
@testable import Yapnest

struct ContactQueryTests {
    private let me = JID("me@example.com")!
    private let ann = Contact(jid: JID("ann@example.com")!, name: "Ann Lee")
    private let bob = Contact(jid: JID("bob@work.example")!, name: "Robert")

    private func addable(_ text: String, excluding: Set<JID> = [], selected: Set<JID> = []) -> JID? {
        ContactQuery.addable(text, contacts: [ann, bob], excluding: excluding, account: me, selected: selected)
    }

    @Test func filtersByNameOrAddressIgnoringCase() {
        #expect(ContactQuery.filter([ann, bob], by: "LEE").map(\.jid) == [ann.jid])
        #expect(ContactQuery.filter([ann, bob], by: "WORK.").map(\.jid) == [bob.jid])
        #expect(ContactQuery.filter([ann, bob], by: "  ").count == 2)
        #expect(ContactQuery.filter([ann, bob], by: "zed").isEmpty)
    }

    @Test func offersAnAddressAndAnXMPPLink() {
        #expect(addable("new@example.org") == JID("new@example.org"))
        #expect(addable("xmpp:new@example.org?roster") == JID("new@example.org"))
    }

    @Test func doesNotOfferAddressesThatHaveARowOrAreUnusable() {
        #expect(addable("me@example.com") == nil)
        #expect(addable("ann@example.com") == nil)
        #expect(addable("gone@example.org", excluding: [JID("gone@example.org")!]) == nil)
        #expect(addable("pick@example.org", selected: [JID("pick@example.org")!]) == nil)
        #expect(addable("example.org") == nil)
        #expect(addable("ann") == nil)
    }
}
