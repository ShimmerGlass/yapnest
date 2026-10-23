import Foundation
import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

/// What the list does when messages come in.
@MainActor
struct ConversationScrollTests {
    private func opened(distance: CGFloat, flipped: Bool) async throws -> ConversationFixture {
        let f = try ConversationFixture(isFlipped: flipped)
        try f.addMany(30)
        await f.start()
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: distance))
        f.scrollRequestsAtOpen = f.model.scrollRevision
        return f
    }

    /// The list was told to go to its newest message: its start flipped, else the row.
    private func scrolledToNewest(_ f: ConversationFixture, row: Int64? = nil) -> Bool {
        f.model.isFlipped
            ? f.model.scrollRevision > f.scrollRequestsAtOpen && f.model.scroll.edge == .top
            : f.model.scroll.messageID == (row ?? f.rowIDs.last)
    }

    /// The model hasn't aimed the list anywhere since it was opened.
    private func notScrolled(_ f: ConversationFixture) -> Bool {
        f.model.scrollRevision == f.scrollRequestsAtOpen
    }

    /// The user is looking at rows 5 and 6, which the list has measured.
    private func scrolledUp(_ f: ConversationFixture) {
        let ids = f.rowIDs
        f.model.visibleChanged([ids[6], ids[5]])
        f.model.anchorMeasured(id: ids[5], frame: CGRect(x: 0, y: 100, width: 400, height: 60))
    }

    @Test(arguments: [false, true]) func ownSendTakesTheListToTheNewMessageEvenWhenScrolledUp(flipped: Bool) async throws {
        let f = try await opened(distance: 3_000, flipped: flipped)
        scrolledUp(f)

        f.model.send("hello")
        await eventually("the message never showed") { f.model.rows.last?.message.body == "hello" }
        let sent = f.model.rows.last!
        #expect(sent.message.direction == .outgoing)
        #expect(scrolledToNewest(f, row: sent.id))
    }

    /// Unflipped the list is taken to the new row by its id. Sent before the
    /// row was in the list, in an animation of its own, the scroll aimed at a
    /// guess while the row slid in on another curve, and the Mac stuttered.
    @Test func theListFollowsToANewRowOnlyOnceItIsInTheList() async throws {
        let f = try await opened(distance: 3_000, flipped: false)
        scrolledUp(f)
        f.model.send("hello")
        await eventually("the message never showed") { f.model.rows.last?.message.body == "hello" }
        #expect(scrolledToNewest(f))

        let near = try await opened(distance: 50, flipped: false)
        let incoming = try near.add("hello")
        await eventually("the list never followed") { scrolledToNewest(near, row: incoming.id) }

        #expect(f.model.scrollsToMissingRows == 0)
        #expect(near.model.scrollsToMissingRows == 0)
    }

    /// Flipped, the list holds the newest messages below instead: see
    /// `messagesArrivingWhileScrolledUpWaitBelowTheFlippedList`.
    @Test func aMessageFromElsewhereDoesNotPullAReaderAwayFromWhatTheyAreReading() async throws {
        let f = try await opened(distance: 3_000, flipped: false)
        scrolledUp(f)
        let anchor = f.rowIDs[5]

        let incoming = try f.add("hello from them")
        await eventually("the message never showed") { f.rowIDs.last == incoming.id }
        #expect(f.model.scroll.messageID == anchor)

        // Our own message made on another device doesn't either.
        let mine = try f.add("from my other device", .outgoing)
        await eventually("the message never showed") { f.rowIDs.last == mine.id }
        #expect(f.model.scroll.messageID == anchor)
    }

    /// A row added at the flipped list's newest end moves everything on
    /// screen by its height, which the scroll view can't be held against on
    /// iOS 27. So it waits below, counted, until the user is back down.
    @Test func messagesArrivingWhileScrolledUpWaitBelowTheFlippedList() async throws {
        let f = try await opened(distance: 3_000, flipped: true)
        scrolledUp(f)
        let shown = f.rowIDs
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)
        await eventually("the newest messages were never held") { f.model.isBounded }
        #expect(f.rowIDs == shown)

        let incoming = try f.add("hello from them")
        await eventually("the waiting message was never counted") { f.model.unreadCount == 1 }
        #expect(f.rowIDs == shown)

        f.model.geometryChanged(geometry(flipped: true, distanceFromBottom: 40))
        f.model.awayFromBottomChanged(false)
        await eventually("the waiting message never came in") { f.rowIDs.last == incoming.id }
        #expect(!f.model.isBounded)
        #expect(scrolledToNewest(f))
    }

    /// The bounded window would otherwise make the last row no longer the
    /// newest, and the quick responses under it would go, moving the list by
    /// their height just as the hold is meant to prevent.
    @Test func theNewestMessageKeepsItsResponsesWhileTheNewestMessagesAreHeld() async throws {
        let f = try await opened(distance: 3_000, flipped: true)
        #expect(f.model.rows.last?.content.showsResponses == true)
        scrolledUp(f)
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)
        await eventually("the newest messages were never held") { f.model.isBounded }

        #expect(f.model.rows.last?.content.showsResponses == true)
    }

    /// The hold's new observation would throw away the page's widening, which
    /// is then looked for again once the hold has taken effect.
    @Test func aHoldWaitsForAnOlderPageInFlightAndThePageStillLands() async throws {
        let f = try ConversationFixture(isFlipped: true)
        try f.addMany(1700)
        await f.start()
        f.model.geometryChanged(geometry(flipped: true, distanceFromBottom: 3_000))
        scrolledUp(f)
        let before = f.model.rows.count

        let gate = Gate()
        f.model.olderLoadHook = { await gate.pass() }
        f.model.nearTopChanged(true)
        await eventually("the older load never started") { gate.entered }
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)

        #expect(await stays(for: .milliseconds(500)) { !f.model.isBounded })
        gate.open()
        await eventually("the older page never landed") { f.model.rows.count > before }
        await eventually("the newest messages were never held") { f.model.isBounded }
        #expect(f.model.rows.count > before)
    }

    /// Back at the bottom the held end is let go, which replaces the window
    /// while a page for the old one is still being read. The page is dropped,
    /// and the list near the top looks for it again rather than waiting for
    /// the next scroll.
    @Test func anOlderPageDroppedByLettingInWhatWaitedBelowIsLoadedAgain() async throws {
        let f = try ConversationFixture(isFlipped: true)
        try f.addMany(1700)
        await f.start()
        f.model.geometryChanged(geometry(flipped: true, distanceFromBottom: 3_000))
        scrolledUp(f)
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)
        await eventually("the newest messages were never held") { f.model.isBounded }
        let before = f.model.rows.count

        let gate = Gate()
        f.model.olderLoadHook = { await gate.pass() }
        f.model.nearTopChanged(true)
        await eventually("the older load never started") { gate.entered }
        f.model.geometryChanged(geometry(flipped: true, distanceFromBottom: 40))
        f.model.awayFromBottomChanged(false)
        await eventually("the newest messages were never let in") { !f.model.isBounded }
        // The new window's update comes while the page is still being read.
        try await Task.sleep(for: .milliseconds(400))
        gate.open()

        await eventually("the older page was never loaded again") { f.model.rows.count > before }
    }

    @Test func sendingLetsInWhatWaitedBelow() async throws {
        let f = try await opened(distance: 3_000, flipped: true)
        scrolledUp(f)
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)
        await eventually("the newest messages were never held") { f.model.isBounded }
        let incoming = try f.add("hello from them")
        await eventually("the waiting message was never counted") { f.model.unreadCount == 1 }

        f.model.send("hello")
        await eventually("the message never showed") { f.model.rows.last?.message.body == "hello" }
        #expect(f.rowIDs.contains(incoming.id!))
        #expect(!f.model.isBounded)
        #expect(scrolledToNewest(f))
    }

    /// Not a window replaced and a jump, as after a quote: the list scrolls
    /// down to what waited there.
    @Test func scrollToLatestLetsInWhatWaitedBelowAndScrollsThere() async throws {
        let f = try await opened(distance: 3_000, flipped: true)
        scrolledUp(f)
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)
        await eventually("the newest messages were never held") { f.model.isBounded }
        let incoming = try f.add("hello from them")
        await eventually("the waiting message was never counted") { f.model.unreadCount == 1 }

        f.model.scrollToLatest()
        #expect(scrolledToNewest(f))
        await eventually("the waiting message never came in") { f.rowIDs.last == incoming.id }
        #expect(!f.model.isBounded)
        #expect(f.model.scroll.edge == .top)
    }

    /// The Mac's list keeps its place as rows come in below.
    @Test func theUnflippedListTakesInMessagesWhileScrolledUp() async throws {
        let f = try await opened(distance: 3_000, flipped: false)
        scrolledUp(f)
        f.model.userStartedScrolling()
        f.model.awayFromBottomChanged(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!f.model.isBounded)
        let incoming = try f.add("hello from them")
        await eventually("the message never showed") { f.rowIDs.last == incoming.id }
    }

    @Test(arguments: [false, true]) func aMessageArrivingNearTheBottomTakesTheListToIt(flipped: Bool) async throws {
        let f = try await opened(distance: 50, flipped: flipped)
        let incoming = try f.add("hello")
        await eventually("the list never followed") { scrolledToNewest(f, row: incoming.id) }
    }

    @Test(arguments: [false, true]) func aMessageWeSentStopsPullingOnceItHasArrived(flipped: Bool) async throws {
        let f = try await opened(distance: 3_000, flipped: flipped)
        scrolledUp(f)
        f.model.send("hello")
        await eventually("the message never showed") { f.model.rows.last?.message.body == "hello" }
        let followed = f.model.scrollRevision

        // The send has been followed; the next message from elsewhere is not.
        // Flipped, the send's scroll to the start is still the last asked for.
        let incoming = try f.add("reply", at: Date().addingTimeInterval(60))
        await eventually("the reply never showed") { f.rowIDs.last == incoming.id }
        if flipped {
            #expect(f.model.scrollRevision == followed || f.model.scroll.edge != .top)
        } else {
            #expect(!scrolledToNewest(f, row: incoming.id))
        }
    }

    @Test(arguments: [false, true]) func onlyAMessageThatJustArrivedAtTheBottomSlidesIn(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        let loaded = f.rowIDs
        #expect(f.model.arrivingIDs.isEmpty)

        let incoming = try f.add("hello")
        await eventually("the message never showed") { f.rowIDs.last == incoming.id }
        #expect(f.model.arrivingIDs == [incoming.id!])
        #expect(loaded.allSatisfy { !f.model.arrivingIDs.contains($0) })

        // Later updates don't make an earlier row arrive again, and the
        // slide is over a moment later.
        let next = try f.add("another")
        await eventually("the message never showed") { f.rowIDs.last == next.id }
        #expect(f.model.arrivingIDs == [next.id!])
        await eventually("the arriving mark stayed") { f.model.arrivingIDs.isEmpty }
    }

    @Test(arguments: [false, true]) func aResizeIsCorrectedOnceTheListIsStill(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.visibleChanged([])
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 0, container: 500))
        await eventually("the newest row was never brought back") { scrolledToNewest(f) }
    }

    /// The list at its end, then given a top margin of 300 that leaves it off the end.
    private func marginStep(_ f: ConversationFixture) {
        f.model.geometryChanged(geometry(flipped: f.isFlipped, distanceFromBottom: 300, container: 500, insetTop: 300))
    }

    @Test(arguments: [false, true]) func aMarginStepWaitsForTheListToBeStill(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        marginStep(f)
        #expect(notScrolled(f))
        await eventually("the newest row was never brought back") { scrolledToNewest(f) }
    }

    @Test(arguments: [false, true]) func aResizeThatLeavesTheNewestRowOutOfTheReportedOnesIsCorrectedOnceStill(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.visibleChanged([f.rowIDs[3], f.rowIDs[2]])
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 0, container: 500))
        await eventually("the newest row was never brought back") { scrolledToNewest(f) }
    }

    @Test(arguments: [false, true]) func aListWithNoRowLeftIsGivenAMarginNudgeEachTimeItIsFoundEmpty(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.visibleChanged([])
        await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
        f.model.visibleChanged([f.rowIDs[0]])
        f.model.visibleChanged([])
        await eventually("the margin was never nudged back") { f.model.layoutNudge == 0 }
    }

    @Test(arguments: [false, true]) func aListThatNeverComesBackIsNudgedAFewTimesAndThenLeftAlone(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        var changes = 0
        var seen = f.model.layoutNudge
        for _ in 0..<9 {
            f.model.visibleChanged([])
            try await Task.sleep(for: .milliseconds(120))
            if f.model.layoutNudge != seen { changes += 1; seen = f.model.layoutNudge }
        }
        #expect(changes == 6)

        // A row reporting gives the allowance back.
        f.model.visibleChanged([f.rowIDs[0]])
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 0, container: 500))
        try await Task.sleep(for: .milliseconds(120))
        f.model.visibleChanged([])
        await eventually("the margin was never nudged again") { f.model.layoutNudge != seen }
    }

    @Test(arguments: [false, true]) func aListWithTheNewestRowVisibleIsNotNudged(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.visibleChanged([f.rowIDs.last!])
        #expect(await stays(for: .milliseconds(200)) { f.model.layoutNudge == 0 })
    }

    @Test(arguments: [false, true]) func aNewestRowFillingTheViewCountsAsVisibleWithoutBeingReported(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        let last = f.rowIDs.last!
        f.model.visibleChanged([])
        f.model.rowFillsViewChanged(last, true)
        #expect(f.model.visibleIDs == [last])
        #expect(f.model.anchorID == last)
        #expect(await stays(for: .milliseconds(200)) { f.model.layoutNudge == 0 })
    }

    @Test(arguments: [false, true]) func reportedRowsStillCountAsBeforeAndFillingOnesJoinThemInListOrder(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        let ids = f.rowIDs
        f.model.visibleChanged([ids[6], ids[5]])
        #expect(f.model.visibleIDs == [ids[6], ids[5]])
        #expect(f.model.anchorID == ids[5])

        f.model.rowFillsViewChanged(ids[2], true)
        f.model.rowFillsViewChanged(ids[29], true)
        #expect(f.model.visibleIDs == [ids[2], ids[6], ids[5], ids[29]].sorted { ids.firstIndex(of: $0)! < ids.firstIndex(of: $1)! })
        #expect(f.model.anchorID == ids[2])

        f.model.rowFillsViewChanged(ids[2], false)
        #expect(f.model.anchorID == ids[5])
    }

    @Test(arguments: [false, true]) func aFillThatWasClearedLetsAnEmptyListBeNudgedAgain(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.visibleChanged([])
        f.model.rowFillsViewChanged(f.rowIDs.last!, true)
        #expect(await stays(for: .milliseconds(200)) { f.model.layoutNudge == 0 })

        // The row was released.
        f.model.rowFillsViewChanged(f.rowIDs.last!, false)
        await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
    }

    @Test(arguments: [false, true]) func aBuiltNewestRowAtTheEndOfTheFlippedListIsNotNudgedWhenNothingReportsIt(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        let last = f.rowIDs.last!
        f.model.rowBuiltChanged(last, true)
        f.model.visibleChanged([])
        if flipped {
            #expect(await stays(for: .milliseconds(200)) { f.model.layoutNudge == 0 })
        } else {
            // The unflipped list can be blank with its rows built, so a built
            // row doesn't hide it.
            await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
            return
        }

        // Released by the lazy stack, it no longer vouches for itself.
        f.model.rowBuiltChanged(last, false)
        f.model.visibleChanged([])
        await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
    }

    @Test(arguments: [false, true]) func aBuiltNewestRowNotAtTheEndDoesNotHideAListOffItsEnd(flipped: Bool) async throws {
        let f = try await opened(distance: 3000, flipped: flipped)
        f.model.rowBuiltChanged(f.rowIDs.last!, true)
        f.model.visibleChanged([])
        await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
    }

    @Test(arguments: [false, true]) func anEmptyReportInTheMiddleOfAnAnimatedScrollIsLookedAtOnceItSettles(flipped: Bool) async throws {
        let f = try await opened(distance: 3000, flipped: flipped)
        f.model.scrollToLatest()
        f.model.scrollPhase = .animating
        f.model.visibleChanged([])
        // The list keeps moving while the recovery waits.
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 2500))
        #expect(await stays(for: .milliseconds(200)) { f.model.layoutNudge == 0 })

        f.model.scrollPhase = .idle
        f.model.scrollSettled()
        await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
    }

    @Test(arguments: [false, true]) func aStaleFillDoesNotHideANewestRowThatIsNotAtTheEnd(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.visibleChanged([])
        f.model.rowFillsViewChanged(f.rowIDs.last!, true)
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 300, container: 500))
        await eventually("the list was never taken back to the newest row") { scrolledToNewest(f) }
        await eventually("the margin was never nudged") { f.model.layoutNudge == 1 }
    }

    @Test(arguments: [false, true]) func aKeyboardDraggedAwayUnderAListAtItsBottomTakesTheListBackToIt(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.userStartedScrolling()
        f.model.scrollPhase = .interacting
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 100, container: 500))
        f.model.scrollPhase = .idle
        f.model.scrollSettled()
        #expect(scrolledToNewest(f))
        #expect(f.model.followsBottom)
    }

    @Test(arguments: [false, true]) func aSwipeThatLeftTheListsRoomAloneLeavesItWhereItStopped(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.userStartedScrolling()
        f.model.scrollPhase = .interacting
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 100))
        f.model.scrollPhase = .idle
        f.model.scrollSettled()
        #expect(notScrolled(f))
        #expect(!f.model.followsBottom)
    }

    @Test(arguments: [false, true]) func aListTheUserScrolledAwayIsLeftAloneWhenTheMarginSteps(flipped: Bool) async throws {
        let f = try await opened(distance: 0, flipped: flipped)
        f.model.userStartedScrolling()
        marginStep(f)
        #expect(await stays { notScrolled(f) })
    }

    @Test(arguments: [false, true]) func theListOpensAtItsNewestEnd(flipped: Bool) async throws {
        let f = try ConversationFixture(isFlipped: flipped)
        try f.addMany(5)
        await f.start()
        #expect(f.model.scroll.edge == (flipped ? .top : .bottom))
    }

    @Test(arguments: [false, true]) func olderMessagesComingInHoldTheReaderOnlyWhereTheListWouldMoveThem(flipped: Bool) async throws {
        let f = try await opened(distance: 3_000, flipped: flipped)
        scrolledUp(f)
        let anchor = f.rowIDs[5]

        let older = try f.add("long ago", at: Date(timeIntervalSince1970: 1_000_000))
        await eventually("the older message never showed") { f.rowIDs.first == older.id }
        // Flipped, they are appended past the far end of the scroll view,
        // which leaves every offset where it is: nothing to hold.
        if flipped {
            #expect(notScrolled(f))
        } else {
            #expect(f.model.scroll.messageID == anchor)
        }
    }

    @Test(arguments: [false, true]) func distancesAreTheUsersWhicheverWayUpTheListIs(flipped: Bool) {
        func g(_ distance: CGFloat) -> ScrollGeometry {
            geometry(flipped: flipped, distanceFromBottom: distance, container: 500, content: 3_000)
        }
        #expect(ConversationModel.distanceFromBottom(g(0), flipped: flipped) == 0)
        #expect(ConversationModel.distanceFromTop(g(0), flipped: flipped) == 2_500)
        #expect(ConversationModel.distanceFromBottom(g(300), flipped: flipped) == 300)
        #expect(ConversationModel.distanceFromTop(g(300), flipped: flipped) == 2_200)
        #expect(ConversationModel.distanceFromBottom(g(-20), flipped: flipped) == -20)

        #expect(!ConversationModel.isAway(g(100), flipped: flipped))
        #expect(ConversationModel.isAway(g(130), flipped: flipped))
        // Near the oldest message: within a screen and a half.
        #expect(ConversationModel.isNearTop(g(1_800), flipped: flipped))
        #expect(!ConversationModel.isNearTop(g(1_700), flipped: flipped))
    }

    @Test(arguments: [false, true]) func theBarsInsetIsTheOneAtTheTopOfTheScreen(flipped: Bool) {
        let withBars = geometry(flipped: flipped, distanceFromBottom: 0, container: 500, content: 3_000, insetTop: 120)
        #expect(ConversationModel.topInset(withBars, flipped: flipped) == 120)
        #expect(ConversationModel.distanceFromBottom(withBars, flipped: flipped) == 0)
    }

    @Test(arguments: [false, true], [ScrollPhase.idle, .decelerating, .animating]) func theScrollToLatestButtonTakesTheListToTheNewestWhateverItIsDoing(flipped: Bool, phase: ScrollPhase) async throws {
        let f = try await opened(distance: 3_000, flipped: flipped)
        scrolledUp(f)
        f.model.userStartedScrolling()
        f.model.scrollPhase = phase

        f.model.scrollToLatest()
        // By the row's id even when flipped: the list's start, which is also
        // the newest row's bottom, is out of reach for the lazy stack from a
        // long way off on iOS 27.
        #expect(f.model.scrollRevision > f.scrollRequestsAtOpen)
        #expect(f.model.scroll.messageID == f.rowIDs.last)
        #expect(f.model.followsBottom)
    }

    // MARK: A blank list far up the history

    @Test(arguments: [true, false]) func aListPastItsFarEndGoesBackToTheRowBeingRead(flipped: Bool) async throws {
        let f = try await opened(distance: 3_000, flipped: flipped)
        scrolledUp(f)
        f.model.userStartedScrolling()
        let reading = f.rowIDs[5]
        let before = f.model.scrollRevision

        // The lazy stack shrank its guess of the content under the offset.
        let pastEnd = flipped
            ? geometry(flipped: true, distanceFromBottom: 30_000, content: 12_000)
            : geometry(flipped: false, distanceFromBottom: 30_000, content: 12_000)
        f.model.visibleChanged([])
        f.model.anyVisibleChanged(count: 0)
        f.model.geometryChanged(pastEnd)

        await eventually("the list was left past its end") { f.model.scroll.messageID == reading }
        #expect(f.model.scrollRevision > before)
        #expect(!f.model.followsBottom)
    }

    @Test func aBlankListInTheMiddleIsNudgedNotTakenToTheNewest() async throws {
        let f = try await opened(distance: 3_000, flipped: true)
        scrolledUp(f)
        f.model.userStartedScrolling()
        let before = f.model.scrollRevision

        f.model.visibleChanged([])
        f.model.anyVisibleChanged(count: 0)
        f.model.geometryChanged(geometry(flipped: true, distanceFromBottom: 3_000))

        await eventually("the lazy stack was never prodded") { f.model.layoutNudge != 0 }
        #expect(f.model.scrollRevision == before)
    }

    @Test(arguments: [true, false]) func twoTallRowsEachLessThanHalfInViewAreNotABlankList(flipped: Bool) async throws {
        let f = try await opened(distance: 3_000, flipped: flipped)
        scrolledUp(f)
        f.model.userStartedScrolling()
        let before = f.model.scrollRevision

        // Nothing is half in view, but two rows are partly on screen. The
        // list is past its far end here, which would be recovered if empty.
        f.model.visibleChanged([])
        f.model.anyVisibleChanged(count: 2)
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 30_000, content: 12_000))
        f.model.geometryChanged(geometry(flipped: flipped, distanceFromBottom: 3_000))
        try await Task.sleep(for: .milliseconds(400))

        #expect(f.model.scrollRevision == before)
        #expect(f.model.layoutNudge == 0)
    }

    @Test func blankRecoveryOnlyActsOnAListWithNoRows() {
        let past = geometry(flipped: true, distanceFromBottom: 30_000, content: 12_000)
        let middle = geometry(flipped: true, distanceFromBottom: 3_000)
        let short = geometry(flipped: true, distanceFromBottom: 0, container: 800, content: 500)
        #expect(ConversationModel.blankRecovery(past, flipped: true, reportsRows: false, nudges: 0) == .scrollToAnchor)
        #expect(ConversationModel.blankRecovery(middle, flipped: true, reportsRows: false, nudges: 0) == .nudge)
        #expect(ConversationModel.blankRecovery(middle, flipped: true, reportsRows: false, nudges: 6) == nil)
        #expect(ConversationModel.blankRecovery(past, flipped: true, reportsRows: true, nudges: 0) == nil)
        #expect(ConversationModel.blankRecovery(short, flipped: true, reportsRows: false, nudges: 0) == nil)
    }
}
