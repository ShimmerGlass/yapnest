import Foundation
import Testing
import YapnestKit

@testable import Yapnest

/// What the share sheet tells the user once the messages are written.
struct ShareEndingTests {
    @Test func aQueuedShareKeepsItsReason() {
        #expect(ShareEnding(.queued("The server didn't respond.")) == .queued("The server didn't respond."))
    }

    @Test func aShareThatWroteNothingIsRetriedNotEnded() {
        #expect(ShareEnding(.failed("There's nothing to send.")) == nil)
    }

    @Test func aShareHandedToTheAppIsNotSaidToBeSent() {
        #expect(ShareEnding(.handedToApp) == .handedToApp)
        #expect(ShareEnding(.sent) == .sent)
    }

    @Test func aMessageThatFailedInTheAppWaitsForTheUserToReadWhy() {
        #expect(ShareEnding(.failedInApp("Too big")) == .failed("Too big"))
        #expect(ShareEnding.failed("Too big").linger == nil)
        #expect(ShareEnding.queued("Offline").linger == nil)
        #expect(ShareEnding.sent.linger != nil)
        #expect(ShareEnding.handedToApp.linger != nil)
    }
}
