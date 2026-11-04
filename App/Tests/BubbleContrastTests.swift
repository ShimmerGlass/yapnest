import SwiftUI
import Testing
import UIKit
@testable import Yapnest

/// The text drawn in the accent, or on it, reads at WCAG AA (4.5:1 for normal
/// text) against the bubble it sits on, in every appearance a phone can have.
@MainActor
struct BubbleContrastTests {
    /// Light and dark, each with Increase Contrast off and on.
    nonisolated private static let appearances = [(false, false), (false, true), (true, false), (true, true)]

    private static func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: high ? .high : .normal),
        ])
    }

    @Test(arguments: appearances)
    func linksInAReceivedBubbleReadAtAA(dark: Bool, high: Bool) {
        let traits = Self.traits(dark: dark, high: high)
        let link = SelectableTextStyle.receivedAccent.resolvedColor(with: traits)
        let bubble = UIColor.secondarySystemBackground.resolvedColor(with: traits)
        #expect(Self.contrast(link, bubble) >= 4.5)
    }

    @Test(arguments: appearances)
    func theFooterOnOurOwnBubbleReadsAtAA(dark: Bool, high: Bool) {
        let traits = Self.traits(dark: dark, high: high)
        let footer = SelectableTextStyle.footerOnAccent.resolvedColor(with: traits)
        let bubble = UIColor(named: "AccentColor")!.resolvedColor(with: traits)
        #expect(Self.contrast(footer, bubble) >= 4.5)
    }

    /// WCAG 2's contrast ratio, of colours made opaque over each other: a
    /// translucent footer is blended onto the bubble first.
    static func contrast(_ foreground: UIColor, _ background: UIColor) -> Double {
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (fr, fg, fb, fa): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        background.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        foreground.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        let blended = (fr * fa + br * (1 - fa), fg * fa + bg * (1 - fa), fb * fa + bb * (1 - fa))
        let lighter = luminance(blended), darker = luminance((br, bg, bb))
        let (high, low) = lighter > darker ? (lighter, darker) : (darker, lighter)
        return (high + 0.05) / (low + 0.05)
    }

    private static func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Double {
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }
}
