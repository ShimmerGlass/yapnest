import Observation
import SwiftUI
import Testing
import UIKit
@testable import Yapnest

/// `BubbleLayout` keeps its measurements between passes. A row whose height
/// came from a stale one would make the list's lazy stack jump, so these
/// check that every change to a part, from outside or from within, measures
/// it again.
@MainActor
struct BubbleLayoutTests {
    @Observable final class Part {
        var height: CGFloat = 20
        var text = "Hi"
    }

    /// A picture that arrives later: it resizes by itself, while the row's
    /// content and the layout's inputs stay the same.
    private struct Picture: View {
        let part: Part
        var body: some View { Color.red.frame(width: 50, height: part.height) }
    }

    private struct Words: View {
        let part: Part
        var body: some View { Text(part.text) }
    }

    private func host(_ part: Part) -> UIHostingController<some View> {
        let host = UIHostingController(rootView: BubbleLayout(fillsWidth: false, offeredWidth: 300) {
            Words(part: part)
            Picture(part: part)
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        return host
    }

    private func size(_ host: UIHostingController<some View>) async -> CGSize {
        // Lets the observation's update reach the graph, as the next frame would.
        await Task.yield()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 300, height: 10_000))
    }

    @Test func aPartThatGrowsByItselfIsMeasuredAgain() async {
        let part = Part()
        let host = host(part)
        let before = await size(host)
        part.height = 120
        let after = await size(host)
        // Within a pixel: heights are rounded to the screen's.
        #expect(abs(after.height - before.height - 100) < 1)
    }

    @Test func aPartThatWidensByItselfIsMeasuredAgain() async {
        let part = Part()
        let host = host(part)
        let before = await size(host)
        part.text = "A much longer line of words than before"
        let after = await size(host)
        #expect(after.width > before.width)
    }

    @Test func askingAgainAtTheSameWidthGivesTheSameSize() async {
        let host = host(Part())
        let first = await size(host)
        #expect(await size(host) == first)
    }

    // MARK: The 78% rule

    /// A part wider than any row, so the bubble takes the most the rule allows.
    private struct Wide: View {
        var body: some View { Color.clear.frame(width: 2_000, height: 10) }
    }

    /// The bubble's drawn width (content and its 12pt of padding each side)
    /// in a list `listWidth` wide, laid out the way the row does: hosted on
    /// iOS, which is offered the width inside the row's margins and told it,
    /// or as plain SwiftUI on the Mac, which proposes what is left of that
    /// after the bubble's padding.
    private func drawnWidth(listWidth: CGFloat, hosted: Bool, fillsWidth: Bool = false) -> CGFloat {
        let host = UIHostingController(rootView: BubbleLayout(fillsWidth: fillsWidth, offeredWidth: hosted ? listWidth - 24 : nil) { Wide() })
        let width = hosted ? listWidth - 24 : listWidth - 48
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000)).width + 24
    }

    @Test(arguments: [375.0, 393.0, 402.0, 430.0]) func aBubbleIsAtMostSeventyEightPercentOfTheList(listWidth: CGFloat) {
        let rule = min(listWidth * 0.78, listWidth - 60)
        let hosted = drawnWidth(listWidth: listWidth, hosted: true)
        let plain = drawnWidth(listWidth: listWidth, hosted: false)
        print("bubble width, list \(listWidth): rule \(rule), hosted (iOS) \(hosted), plain (Mac) \(plain)")
        #expect(abs(plain - rule) < 0.5)
        #expect(abs(hosted - rule) < 0.5)
    }

    @Test(arguments: [375.0, 393.0, 402.0, 430.0]) func aPhotoBubbleFollowsTheSameRule(listWidth: CGFloat) {
        let rule = min(listWidth * 0.78, listWidth - 60, MediaLimits.maxBubbleWidth)
        let hosted = drawnWidth(listWidth: listWidth, hosted: true, fillsWidth: true)
        print("photo bubble width, list \(listWidth): rule \(rule), hosted (iOS) \(hosted)")
        #expect(abs(hosted - rule) < 0.5)
    }
}
