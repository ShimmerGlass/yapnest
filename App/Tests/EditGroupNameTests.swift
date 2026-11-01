import Testing
import YapnestKit
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

@MainActor
struct EditGroupFailureTests {
    private struct Refused: Error {}

    @Test func aFailureFromTheServerOffersRetry() {
        var failures = EditGroupView.SaveFailures()
        failures.add("Subject", ServerError(condition: "remote-server-timeout"))
        #expect(failures.canRetry)
        #expect(failures.message?.hasPrefix("Subject: ") == true)
    }

    @Test func aFailureOfOurOwnDoesNot() {
        var failures = EditGroupView.SaveFailures()
        failures.add("Picture", Refused())
        #expect(!failures.canRetry)
    }

    @Test func failuresShareOneAlertAndClearTogether() {
        var failures = EditGroupView.SaveFailures()
        failures.add("Picture", Refused())
        failures.add("Subject", ServerError(condition: "remote-server-timeout"))
        #expect(failures.message?.contains("\n") == true)
        #expect(failures.canRetry)
        failures.message = nil
        #expect(failures.isEmpty)
        #expect(!failures.canRetry)
    }
}
