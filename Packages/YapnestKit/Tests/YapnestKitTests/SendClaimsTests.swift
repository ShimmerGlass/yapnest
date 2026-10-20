import Testing
@testable import YapnestKit

/// Editing or retracting a message the send queue hasn't taken up yet changes
/// what goes out; one it has taken up needs a correction or retraction.
struct SendClaimsTests {
    @Test func anUntouchedMessageIsSentAsWritten() {
        var claims = SendClaims()
        #expect(claims.claim("m1") == .send(text: nil))
    }

    @Test func anEditBeforeTheClaimChangesTheText() {
        var claims = SendClaims()
        let onWire1 = claims.apply(.edited("new"), to: "m1", alreadySent: false)
        #expect(!onWire1)
        #expect(claims.claim("m1") == .send(text: "new"))
    }

    @Test func theLastEditBeforeTheClaimWins() {
        var claims = SendClaims()
        _ = claims.apply(.edited("one"), to: "m1", alreadySent: false)
        _ = claims.apply(.edited("two"), to: "m1", alreadySent: false)
        #expect(claims.claim("m1") == .send(text: "two"))
    }

    @Test func aRetractionBeforeTheClaimSendsNothing() {
        var claims = SendClaims()
        let onWire2 = claims.apply(.retracted, to: "m1", alreadySent: false)
        #expect(!onWire2)
        #expect(claims.claim("m1") == .skip)
        // The change is used up; a later claim of the id is a fresh one.
        #expect(claims.claim("m1") == .send(text: nil))
    }

    @Test func anEditAfterTheClaimGoesOverTheNetwork() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        let onWire3 = claims.apply(.edited("new"), to: "m1", alreadySent: false)
        #expect(onWire3)
    }

    @Test func aClaimOutlastsTheMessageBeingAcknowledged() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        // Nothing releases it on an acknowledgement or a dropped connection.
        let onWire4 = claims.apply(.edited("new"), to: "m1", alreadySent: false)
        #expect(onWire4)
        let onWire5 = claims.apply(.retracted, to: "m1", alreadySent: false)
        #expect(onWire5)
    }

    @Test func aMessageTheStatusSaysWasSentGoesOverTheNetwork() {
        var claims = SendClaims()
        let onWire6 = claims.apply(.retracted, to: "m1", alreadySent: true)
        #expect(onWire6)
        #expect(claims.claim("m1") == .send(text: nil))
    }

    @Test func aFailedMessageTakesLaterEditsOnItsNextAttempt() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        claims.release("m1")
        let onWire7 = claims.apply(.edited("new"), to: "m1", alreadySent: false)
        #expect(!onWire7)
        #expect(claims.claim("m1") == .send(text: "new"))
    }

    @Test func aNewSessionForgetsClaimsAndChanges() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        _ = claims.apply(.retracted, to: "m2", alreadySent: false)
        claims.reset()
        let onWire8 = claims.apply(.edited("x"), to: "m1", alreadySent: false)
        #expect(!onWire8)
        #expect(claims.claim("m2") == .send(text: nil))
    }

    @Test func aClaimIsHeldUntilReleasedOrReset() {
        var claims = SendClaims()
        #expect(!claims.isClaimed("m1"))
        _ = claims.claim("m1")
        #expect(claims.isClaimed("m1"))
        claims.release("m1")
        #expect(!claims.isClaimed("m1"))
        _ = claims.claim("m1")
        claims.reset()
        #expect(!claims.isClaimed("m1"))
    }

    @Test func aReleasedMessageTakesEditsAsPlainChangesAgain() {
        // Nothing was written when delivery found us offline, so an edit made
        // meanwhile still just changes what the next attempt sends.
        var claims = SendClaims()
        _ = claims.claim("m1")
        claims.release("m1")
        let onWire = claims.apply(.edited("new"), to: "m1", alreadySent: false)
        #expect(!onWire)
        #expect(claims.claim("m1") == .send(text: "new"))
    }
}

/// A message put on a send queue twice, before the first copy was claimed,
/// went out twice.
struct SendQueueingTests {
    @Test func aSecondCopyOfAQueuedMessageIsRefused() {
        var claims = SendClaims()
        let q1 = claims.enqueue("m1")
        #expect(q1)
        let q2 = claims.enqueue("m1")
        #expect(!q2)
        let q3 = claims.enqueue("m1", resend: true)
        #expect(!q3)
    }

    @Test func aClaimedMessageIsNotQueuedAgain() {
        var claims = SendClaims()
        let q4 = claims.enqueue("m1")
        #expect(q4)
        _ = claims.claim("m1")
        let q5 = claims.enqueue("m1")
        #expect(!q5)
    }

    @Test func aReleasedMessageCanBeQueuedAgain() {
        var claims = SendClaims()
        let q6 = claims.enqueue("m1")
        #expect(q6)
        _ = claims.claim("m1")
        claims.release("m1")
        let q7 = claims.enqueue("m1")
        #expect(q7)
    }

    @Test func aMessageReleasedBeforeItsClaimCanBeQueuedAgain() {
        var claims = SendClaims()
        let q8 = claims.enqueue("m1")
        #expect(q8)
        claims.release("m1")
        let q9 = claims.enqueue("m1")
        #expect(q9)
    }

    @Test func aRoomMayResendAClaimedMessageThatNeverCameBack() {
        var claims = SendClaims()
        let q10 = claims.enqueue("m1")
        #expect(q10)
        _ = claims.claim("m1")
        let q11 = claims.enqueue("m1", resend: true)
        #expect(q11)
        // Not two copies at once, though.
        let q12 = claims.enqueue("m1", resend: true)
        #expect(!q12)
    }

    @Test func aRetractedMessageLeavesTheQueue() {
        var claims = SendClaims()
        let q13 = claims.enqueue("m1")
        #expect(q13)
        _ = claims.apply(.retracted, to: "m1", alreadySent: false)
        let c = claims.claim("m1")
        #expect(c == .skip)
        let q14 = claims.enqueue("m1")
        #expect(q14)
    }

    @Test func aNewSessionForgetsWhatWasQueued() {
        var claims = SendClaims()
        let q15 = claims.enqueue("m1")
        #expect(q15)
        claims.reset()
        let q16 = claims.enqueue("m1")
        #expect(q16)
    }
}

/// A write the session dropped gives up its claim, but not a newer one's.
struct DroppedWriteTests {
    @Test func aDroppedWriteReleasesItsClaim() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        let token = claims.token(of: "m1")!
        claims.releaseDropped("m1", token: token)
        #expect(!claims.isClaimed("m1"))
    }

    @Test func aLateFailureLeavesANewerClaim() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        let old = claims.token(of: "m1")!
        claims.release("m1")
        _ = claims.claim("m1")
        claims.releaseDropped("m1", token: old)
        #expect(claims.isClaimed("m1"))
    }

    @Test func aResendClaimIsNotReleasedByTheEarlierCopy() {
        var claims = SendClaims()
        _ = claims.claim("m1")
        let first = claims.token(of: "m1")!
        _ = claims.claim("m1")
        claims.releaseDropped("m1", token: first)
        #expect(claims.isClaimed("m1"))
    }
}
