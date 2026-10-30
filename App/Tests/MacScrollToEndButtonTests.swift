import Testing
import UIKit
@testable import Yapnest

/// On the Mac the scroll-to-end button took a click only near its arrow: the
/// hosting view picks where a press goes from the area around the pointer, and
/// near the edge it picked the message below. The button's view reaches past
/// its circle so it's picked, then takes presses on the circle alone.
@MainActor
struct MacScrollToEndButtonTests {
    private func target() -> PressTarget {
        PressTarget(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
    }

    @Test func aPressNearTheCirclesEdgeIsTheButtons() {
        let view = target()
        #expect(view.point(inside: CGPoint(x: 36 - 21, y: 36), with: nil))
        #expect(view.point(inside: CGPoint(x: 36 - 15, y: 36 - 15), with: nil))
        #expect(view.point(inside: CGPoint(x: 36, y: 36 + 23), with: nil))
    }

    @Test func aPressPastTheCircleIsLeftToTheList() {
        let view = target()
        #expect(!view.point(inside: CGPoint(x: 36 - 26, y: 36), with: nil))
        #expect(!view.point(inside: CGPoint(x: 2, y: 2), with: nil))
    }

    @Test func theHostingViewsRecognizersWaitForTheClick() {
        let host = UIView()
        let button = PressTarget()
        host.addSubview(button)
        let click = ClaimingClick()
        button.addGestureRecognizer(click)
        let hosts = UITapGestureRecognizer()
        host.addGestureRecognizer(hosts)
        let elsewhere = UITapGestureRecognizer()
        UIView().addGestureRecognizer(elsewhere)

        #expect(click.shouldBeRequiredToFail(by: hosts))
        #expect(!click.shouldBeRequiredToFail(by: elsewhere))
        #expect(!click.canBePrevented(by: hosts))
    }
}
