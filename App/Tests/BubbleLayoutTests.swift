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
}
