import Testing
@testable import Yapnest

@MainActor
struct EditGroupNameTests {
    @Test func anUntouchedNameIsNotSentEvenWhenEmpty() {
        #expect(EditGroupView.nameToSend("", saved: "") == nil)
        #expect(EditGroupView.nameToSend("Cake", saved: "Cake") == nil)
    }

    @Test func aRenameAndAClearedNameAreSent() {
        #expect(EditGroupView.nameToSend("Pie", saved: "Cake") == "Pie")
        #expect(EditGroupView.nameToSend("", saved: "Cake") == "")
        #expect(EditGroupView.nameToSend("Cake", saved: "") == "Cake")
    }
}
