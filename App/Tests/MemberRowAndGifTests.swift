import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
import YapnestKit
@testable import Yapnest

struct MemberRowTests {
    @Test func presentOccupantsWithTheSameAddressButDifferentNicksGetDistinctRows() {
        let jid = JID("someone@example.com")!
        let phone = MemberRow.Model(jid: jid, nick: "phone", affiliation: .member, isPresent: true, isMe: false)
        let laptop = MemberRow.Model(jid: jid, nick: "laptop", affiliation: .member, isPresent: true, isMe: false)
        let away = MemberRow.Model(jid: jid, nick: nil, affiliation: .member, isPresent: false, isMe: false)

        #expect(Set([phone.id, laptop.id, away.id]).count == 3)
    }
}

@MainActor
struct AnimatedImageViewTests {
    /// A one-frame GIF of a solid color, `side` pixels square.
    private func gif(canvas side: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil))
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // ImageIO rejects a GIF that compresses too well as malformed, so the
        // canvas gets some noise to make the file believable.
        if side > 1000, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            for index in 0..<(side * 200 * 4) { pixels[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761 >> 13) }
        }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Whether it plays once the header is read, which happens off the main
    /// thread.
    private func animating(_ data: Data) async -> Bool {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedUIImageView(frame: window.bounds)
        window.addSubview(view)
        view.source = .data(data)
        for _ in 0..<50 {
            if !view.isAnimating { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return view.isAnimating
    }

    @Test func aGifTooBigToPlayIsNotAnimated() async throws {
        let huge = try gif(canvas: 6000)
        #expect(AnimatedImages.header(of: huge)?.plan == .tooLarge)
        #expect(await !animating(huge))
    }

    /// A file that declares a canvas and holds no frames, which ImageIO
    /// refuses, as it does a GIF that compresses too well.
    private func unreadableGif(width: Int, height: Int) -> Data {
        Data("GIF89a".utf8) + [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8), 0, 0, 0, 0x3B]
    }

    @Test func aHugeGifThatImageIORefusesIsStillTooLargeToPlay() async throws {
        let huge = unreadableGif(width: 20_000, height: 20_000)
        #expect(CGImageSourceCreateWithData(huge as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } == nil)
        #expect(AnimatedImages.header(of: huge)?.plan == .tooLarge)
        #expect(await !animating(huge))

        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        try huge.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AnimatedImages.header(of: file)?.plan == .tooLarge)
    }

    @Test func aGifThatImageIORefusesAndDeclaresASmallCanvasStaysUnreadable() {
        #expect(AnimatedImages.header(of: unreadableGif(width: 64, height: 64)) == nil)
    }

    @Test func aSmallGifIsAnimated() async throws {
        let small = try gif(canvas: 64)
        #expect(AnimatedImages.header(of: small)?.plan == .play)
        #expect(await animating(small))
    }

    /// Three noisy frames, since ImageIO rejects a GIF that compresses too well.
    private func animatedGif() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil))
        for frame in 0..<3 {
            let context = try #require(CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(red: CGFloat(frame) / 2, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
                for index in 0..<(64 * 8 * 4) { pixels[index] = UInt8(truncatingIfNeeded: (index &+ frame) &* 2_654_435_761 >> 13) }
            }
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aGifShowsAFrameOnceDecodedAndStopsWhenRemovedFromTheWindow() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedUIImageView(frame: window.bounds)
        window.addSubview(view)
        view.source = .data(try animatedGif())
        #expect(view.isAnimating)
        await eventually("no frame shown", timeout: .seconds(1)) { view.image != nil }
        #expect(view.isAnimating)

        view.removeFromSuperview()
        #expect(!view.isAnimating)
    }

    @Test func aGifPausesWhenTheAppCantBeSeenAndResumesWhenItCan() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedUIImageView(frame: window.bounds)
        window.addSubview(view)
        view.source = .data(try animatedGif())
        #expect(view.isAnimating)

        view.setOccluded(true)
        #expect(!view.isAnimating)
        view.setOccluded(true)
        #expect(!view.isAnimating)

        view.setOccluded(false)
        #expect(view.isAnimating)
    }

    @Test func theOcclusionNotificationLeavesAVisibleGifPlaying() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = AnimatedUIImageView(frame: window.bounds)
        window.addSubview(view)
        view.source = .data(try animatedGif())

        // The simulator and a test host in front are always visible.
        NotificationCenter.default.post(name: Platform.windowVisibilityDidChange, object: nil)
        #expect(view.gate.occluded == !Platform.isWindowVisible)
        #expect(view.isAnimating == Platform.isWindowVisible)
    }
}

struct AnimatedPlaybackGateTests {
    @Test func aVisibleActiveWindowPlays() {
        #expect(AnimatedPlaybackGate(inWindow: true).animates)
    }

    @Test func anOccludedWindowPausesAndResumesWhenVisibleAgain() {
        var gate = AnimatedPlaybackGate(inWindow: true)
        gate.occluded = true
        #expect(!gate.showsFrames && !gate.animates)
        gate.occluded = false
        #expect(gate.animates)
    }

    @Test func aSceneInTheBackgroundPauses() {
        #expect(!AnimatedPlaybackGate(inWindow: true, sceneInBackground: true).showsFrames)
    }

    /// A chat of GIFs made its slide jitter: they show their first frame
    /// while the screen slides, and play once it's done.
    @Test func aSlidingScreenShowsAFrameAndPlaysOnceItHasArrived() {
        var gate = AnimatedPlaybackGate(inWindow: true, inTransition: true)
        #expect(gate.showsFrames && !gate.animates)
        gate.inTransition = false
        #expect(gate.animates)
    }

    @Test func aViewOutsideAWindowDoesNotPlay() {
        #expect(!AnimatedPlaybackGate(inWindow: false).showsFrames)
    }

    @Test func reduceMotionShowsAFrameButDoesNotAnimate() {
        let gate = AnimatedPlaybackGate(inWindow: true, reducesMotion: true)
        #expect(gate.showsFrames && !gate.animates)
    }
}
