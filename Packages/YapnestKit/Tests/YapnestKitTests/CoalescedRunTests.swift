import Testing
@testable import YapnestKit

struct CoalescedRunTests {
    @Test func aRequestWhileIdleStartsARunner() {
        var run = XMPPSession.CoalescedRun()
        let starts = run.request()
        #expect(starts)
    }

    @Test func requestsWhileARunnerGoesAskForOneMoreRound() {
        var run = XMPPSession.CoalescedRun()
        _ = run.request()
        run.beginRound()
        let second = run.request()
        let third = run.request()
        #expect(!second && !third)
        let again = run.endRound()
        #expect(again)
        run.beginRound()
        let afterwards = run.endRound()
        #expect(!afterwards)
        let restarts = run.request()
        #expect(restarts)
    }

    @Test func requestsBeforeARoundBeginsAreAbsorbedByIt() {
        var run = XMPPSession.CoalescedRun()
        _ = run.request()
        let early = run.request()
        #expect(!early)
        run.beginRound()
        let again = run.endRound()
        #expect(!again)
    }

    @Test func aRequestDuringTheRoundSurvivesToItsEnd() {
        var run = XMPPSession.CoalescedRun()
        _ = run.request()
        run.beginRound()
        _ = run.request()
        let again = run.endRound()
        #expect(again)
    }
}
