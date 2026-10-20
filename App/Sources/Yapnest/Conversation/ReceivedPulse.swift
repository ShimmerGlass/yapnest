import SwiftUI

/// A soft glow in the app icon's mauve that rises from the bottom of the
/// screen when a message comes in, behind the messages and the composer. It
/// takes no touches and no room, so it can't move the list.
struct ReceivedPulse: View {
    /// Changes once for each pulse.
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The icon's bird, lighter on dark so it still reads as a tint there.
    private var mauve: Color {
        colorScheme == .dark ? Color(red: 0xB8 / 255, green: 0x8F / 255, blue: 0xD0 / 255) : Color(red: 0x94 / 255, green: 0x68 / 255, blue: 0xAE / 255)
    }

    private var peak: Double { colorScheme == .dark ? 0.45 : 0.26 }

    var body: some View {
        Rectangle()
            .fill(LinearGradient(stops: [
                .init(color: mauve, location: 0),
                .init(color: mauve.opacity(0.35), location: 0.45),
                .init(color: mauve.opacity(0), location: 1),
            ], startPoint: .bottom, endPoint: .top))
            .frame(height: 260)
            // The glow's base carries on below the layout's bottom edge, out
            // of the layout: with the keyboard up, the list and composer end
            // at the keyboard, and the glow would stop in a hard line behind
            // its translucent rounded corners. The keyboard covers the rest.
            .overlay(alignment: .bottom) {
                Rectangle().fill(mauve).frame(height: 500).offset(y: 500)
            }
            .keyframeAnimator(initialValue: Frame(), trigger: reduceMotion ? 0 : trigger) { content, frame in
                content
                    .opacity(frame.opacity * peak)
                    .scaleEffect(y: frame.rise, anchor: .bottom)
            } keyframes: { _ in
                // In fast, out slow: a flash would be a banner.
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(1, duration: 0.2)
                    CubicKeyframe(0, duration: 1.0)
                }
                KeyframeTrack(\.rise) {
                    CubicKeyframe(1, duration: 0.9)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct Frame {
        var opacity = 0.0
        var rise = 0.6
    }
}
