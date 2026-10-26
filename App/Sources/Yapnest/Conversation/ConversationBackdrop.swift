import SwiftUI

/// Faint low-poly Yapnest birds and leaves of a few kinds in a grey mauve
/// behind a conversation's messages. They stay put while the messages scroll
/// over them, so the list draws nothing more as it moves, and the pattern is
/// one tile laid out again and again.
struct ConversationBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let lines = BackdropTile.shared.lines
            let side = BackdropTile.side
            let ink = Color.backdropInk(colorScheme)
            // Shapes leave their tile, so the row and column before the
            // first are drawn too, for what reaches in from them.
            var y = -side
            while y < size.height {
                var x = -side
                while x < size.width {
                    var placed = context
                    placed.translateBy(x: x, y: y)
                    placed.stroke(lines, with: .color(ink), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    x += side
                }
                y += side
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// The pattern's grey mauve, faint against either background. Stronger in
    /// the dark, where thin lines on black all but vanish.
    static func backdropInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xB8 / 255, green: 0x9C / 255, blue: 0xCC / 255).opacity(0.19)
            : Color(red: 0x7A / 255, green: 0x5A / 255, blue: 0x8E / 255).opacity(0.12)
    }
}

/// One tile of the pattern, laid out once from a fixed seed. Each shape goes
/// in the best of many random spots, the one with the most room around it,
/// with the tile's edges wrapped, so the spacing stays even and nothing
/// touches, here or where one tile meets the next.
struct BackdropTile {
    static let side: CGFloat = 640
    private static let birdSize: CGFloat = 42
    private static let leafSizes: ClosedRange<CGFloat> = 22...34
    private static let birds = 26
    private static let leaves = 80
    /// The least room kept between any two shapes.
    private static let gap: CGFloat = 12
    static let shared = BackdropTile()

    let lines: Path

    private init() {
        let side = Self.side
        var random = Random(state: 0x5EED_B1ED)
        var placed: [(center: CGPoint, radius: CGFloat)] = []
        var lines = Path()
        func room(_ center: CGPoint, _ radius: CGFloat) -> CGFloat {
            placed.map { other in
                var dx = abs(other.center.x - center.x).truncatingRemainder(dividingBy: side)
                var dy = abs(other.center.y - center.y).truncatingRemainder(dividingBy: side)
                dx = min(dx, side - dx)
                dy = min(dy, side - dy)
                return (dx * dx + dy * dy).squareRoot() - other.radius - radius
            }.min() ?? .infinity
        }
        // Birds spread through the leaves rather than all first.
        let total = Self.birds + Self.leaves
        for index in 0..<total {
            let isBird = index * Self.birds / total != (index + 1) * Self.birds / total
            let size = isBird ? Self.birdSize : Self.leafSizes.lowerBound + random.unit() * (Self.leafSizes.upperBound - Self.leafSizes.lowerBound)
            let shape = isBird ? Self.bird : Self.leafShapes[Int(random.unit() * CGFloat(Self.leafShapes.count)) % Self.leafShapes.count]
            // Birds sit near upright; leaves fall any way.
            let angle = isBird ? (random.unit() - 0.5) * 0.3 : random.unit() * 2 * .pi
            let flip: CGFloat = random.unit() < 0.5 ? -1 : 1
            var laid = shape.applying(CGAffineTransform(scaleX: flip * size, y: size).concatenating(CGAffineTransform(rotationAngle: angle)))
            let bounds = laid.boundingRect
            laid = laid.applying(CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
            // The circle around the shape's corners: a long leaf keeps its
            // distance along its length too.
            let radius = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() / 2
            var best = CGPoint.zero, bestRoom = -CGFloat.infinity
            for _ in 0..<80 {
                let candidate = CGPoint(x: random.unit() * side, y: random.unit() * side)
                let candidateRoom = room(candidate, radius)
                if candidateRoom > bestRoom {
                    best = candidate
                    bestRoom = candidateRoom
                }
            }
            guard bestRoom > Self.gap else { continue }
            lines.addPath(laid.applying(CGAffineTransform(translationX: best.x, y: best.y)))
            placed.append((best, radius))
        }
        self.lines = lines
    }

    private static func lines(_ points: [[(CGFloat, CGFloat)]]) -> Path {
        var path = Path()
        for line in points { path.addLines(line.map { CGPoint(x: $0.0, y: $0.1) }) }
        return path
    }

    /// The app icon's bird, about 1 wide, centred on its middle, drawn in
    /// straight lines: a faceted outline with a rounded belly, its face,
    /// wing and tail.
    private static let bird: Path = {
        // In the icon's own coordinates, where the bird sits at (512, 640).
        let path = lines([
            // Body, belly and the rounded underside, a few facets deep.
            [(305, 640), (318, 540), (360, 450), (430, 390), (512, 370), (595, 390), (665, 450), (707, 540), (720, 640)],
            [(400, 672), (410, 560), (450, 515), (512, 500), (575, 515), (615, 560), (626, 672)],
            [(305, 640), (360, 661), (400, 672), (456, 682), (512, 685), (570, 682), (626, 672), (670, 659), (720, 640)],
            // Facets on the forehead and down the near side.
            [(430, 390), (470, 425), (512, 370), (555, 425), (595, 390)],
            [(470, 425), (555, 425)],
            [(360, 450), (470, 425)],
            [(305, 640), (360, 560), (318, 540)],
            [(360, 450), (360, 560), (400, 672)],
            [(360, 560), (410, 560)],
            // Head feathers.
            [(500, 372), (472, 326), (480, 290), (506, 334), (500, 372)],
            [(516, 372), (538, 322), (565, 308), (554, 346), (516, 372)],
            // Closed eyes, and the beak open in a chirp.
            [(425, 468), (446, 450), (468, 468)],
            [(556, 468), (577, 450), (599, 468)],
            [(478, 490), (512, 474), (546, 490), (512, 512), (478, 490)],
            [(478, 490), (546, 490)],
            // Wing and tail.
            [(655, 535), (704, 556), (712, 640), (664, 602), (655, 535)],
            [(655, 535), (712, 640)],
            [(712, 560), (820, 470), (796, 562), (718, 612), (712, 560)],
            [(712, 560), (796, 562)],
        ])
        return path.applying(CGAffineTransform(scaleX: 1 / 515, y: 1 / 515).translatedBy(x: -560, y: -465))
    }()

    /// Leaves, stem at the origin pointing right, about 1 long, drawn like the
    /// bird.
    private static let leafShapes: [Path] = [
        // A diamond split down its vein.
        lines([[(0, 0), (0.4, -0.3), (1, 0), (0.4, 0.3), (0, 0), (1, 0)]]),
        // Willow: long and thin, with two side veins.
        lines([[(0, 0), (0.35, -0.13), (1, 0), (0.35, 0.13), (0, 0)], [(0, 0), (1, 0)], [(0.3, 0), (0.5, -0.09)], [(0.55, 0), (0.75, 0.06)]]),
        // A faceted oval, each corner joined to the vein.
        lines([
            [(0.12, 0), (0.3, -0.26), (0.72, -0.26), (1, 0), (0.72, 0.26), (0.3, 0.26), (0.12, 0)],
            [(0, 0), (1, 0)], [(0.3, -0.26), (0.48, 0), (0.3, 0.26)], [(0.72, -0.26), (0.84, 0), (0.72, 0.26)],
        ]),
        // Maple: three pointed lobes.
        lines([
            [(0.2, 0), (0.3, -0.18), (0.42, -0.5), (0.52, -0.22), (0.62, -0.24), (1, 0), (0.62, 0.24), (0.52, 0.22), (0.42, 0.5), (0.3, 0.18), (0.2, 0)],
            [(0, 0), (1, 0)], [(0.25, 0), (0.42, -0.5)], [(0.25, 0), (0.42, 0.5)],
        ]),
        // Ginkgo: a fan on a stem, notched in the middle.
        lines([
            [(0, 0), (0.35, 0)],
            [(0.35, 0), (0.8, -0.42), (0.98, -0.18), (0.86, 0), (0.98, 0.18), (0.8, 0.42), (0.35, 0)],
            [(0.35, 0), (0.98, -0.18)], [(0.35, 0), (0.98, 0.18)],
        ]),
        // Birch: broad, with a toothed edge.
        lines([
            [(0.1, 0), (0.24, -0.3), (0.42, -0.28), (0.5, -0.24), (0.66, -0.18), (0.74, -0.14), (1, 0),
             (0.74, 0.14), (0.66, 0.18), (0.5, 0.24), (0.42, 0.28), (0.24, 0.3), (0.1, 0)],
            [(0, 0), (1, 0)], [(0.45, 0), (0.24, -0.3)], [(0.45, 0), (0.24, 0.3)],
            [(0.7, 0), (0.5, -0.24)], [(0.7, 0), (0.5, 0.24)],
        ]),
        // A sprig: small diamonds off a stalk.
        lines([
            [(0, 0), (1, 0)],
            [(0.3, 0), (0.42, -0.2), (0.58, -0.34), (0.48, -0.14), (0.3, 0)],
            [(0.55, 0), (0.67, 0.2), (0.83, 0.34), (0.73, 0.14), (0.55, 0)],
            [(1, 0), (1.1, -0.06), (1.3, 0), (1.1, 0.06), (1, 0)],
        ]),
    ]

    struct Random {
        var state: UInt64

        mutating func unit() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
    }
}
