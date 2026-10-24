import SwiftUI

/// Faint low-poly branches in a grey mauve behind a conversation's messages,
/// with wireframe birds perched on them. They stay put while the messages
/// scroll over them, so the list draws nothing more as it moves, and the
/// pattern is one tile laid out again and again.
struct ConversationBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let lines = BranchTile.shared.lines
            let side = BranchTile.side
            let ink = Color.backdropInk(colorScheme)
            // Branches leave their tile, so the row and column before the
            // first are drawn too, for what reaches in from them.
            var y = -side
            while y < size.height {
                var x = -side
                while x < size.width {
                    var placed = context
                    placed.translateBy(x: x, y: y)
                    placed.stroke(lines, with: .color(ink), style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
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
    /// The branches' grey mauve, faint against either background.
    static func backdropInk(_ scheme: ColorScheme, strength: Double = 1) -> Color {
        scheme == .dark
            ? Color(red: 0xB8 / 255, green: 0x9C / 255, blue: 0xCC / 255).opacity(0.12 * strength)
            : Color(red: 0x7A / 255, green: 0x5A / 255, blue: 0x8E / 255).opacity(0.12 * strength)
    }
}

/// A few faint branches reaching in out of the chat list's mauve wash, with a
/// couple of birds perched on them, fading with the wash.
struct ChatListBranches: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Laid out for a phone 393 points wide: one bough in from each side,
    /// below the title and search field, and a thinner one hanging from the
    /// top.
    private static let tree = LowPolyTree([
        .init(at: CGPoint(x: -12, y: 150), heading: 0.42, length: 300, width: 16, curl: -0.0016, seed: 3),
        .init(at: CGPoint(x: 405, y: 215), heading: .pi - 0.38, length: 250, width: 13, curl: 0.0018, seed: 8),
        .init(at: CGPoint(x: 300, y: -10), heading: 1.9, length: 150, width: 8, curl: -0.002, seed: 5),
    ])

    /// Which of the level spots the birds take, and which way each faces:
    /// apart from each other and clear of the twigs.
    private static let birds: [(perch: Int, faces: CGFloat)] = [(2, 1), (10, -1)]

    var body: some View {
        Canvas { context, size in
            var lines = Self.tree.lines
            for bird in Self.birds {
                lines.addPath(LowPolyTree.bird(on: Self.tree.perches[bird.perch], faces: bird.faces))
            }
            let scale = size.width / 393
            // Stronger than a chat's, as the fade takes most of it away.
            context.stroke(lines.applying(CGAffineTransform(scaleX: scale, y: scale)), with: .color(.backdropInk(colorScheme, strength: 1.8)), style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.3),
                .init(color: .clear, location: 0.7),
            ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One tile of the conversation's pattern, laid out once from a fixed seed:
/// boughs set down wherever nothing they grow comes near what's already
/// there, with the tile's edges wrapped, so none cross, here or where one
/// tile meets the next. Birds then take the level spots with room above them.
struct BranchTile {
    /// A Mac's window is wide enough for longer boughs, set further apart,
    /// where a phone's would read as a thicket.
    static let side: CGFloat = Platform.isMac ? 1080 : 720
    private static let lengths: ClosedRange<CGFloat> = Platform.isMac ? 320...720 : 160...440
    private static let spacing = Platform.isMac ? 3 : 1
    private static let birds = Platform.isMac ? 8 : 7
    static let shared = BranchTile()

    let lines: Path

    private init() {
        let side = Self.side
        // What's drawn, on a grid of cells a few points wide, wrapped at the
        // tile's edges.
        let pitch: CGFloat = 6
        let cells = Int(side / pitch)
        var taken = [Bool](repeating: false, count: cells * cells)
        func cell(_ point: CGPoint) -> (Int, Int) {
            (Int((point.x / pitch).rounded(.down)), Int((point.y / pitch).rounded(.down)))
        }
        func key(_ x: Int, _ y: Int) -> Int { ((x % cells + cells) % cells) * cells + (y % cells + cells) % cells }
        func clear(_ point: CGPoint, by reach: Int) -> Bool {
            let (x, y) = cell(point)
            for dx in -reach...reach { for dy in -reach...reach where taken[key(x + dx, y + dy)] { return false } }
            return true
        }

        var random = LowPolyTree.Random(state: 0x5EED_B0B0)
        var lines = Path()
        var perched: [CGPoint] = []
        // The birds' boughs first, level and bare on top, while there's
        // room for them; then the rest wherever they fit.
        let birds = Self.birds
        let attempts = 4000
        func length(forBird: Bool, attempt: Int, random: inout LowPolyTree.Random) -> CGFloat {
            let lengths = Self.lengths
            guard Platform.isMac else { return lengths.lowerBound + random.unit() * (lengths.upperBound - lengths.lowerBound) }
            // A bird's bough stays short, as all its twigs hang one way. The
            // rest are tried longest first, as long ones stop fitting once
            // the tile fills.
            if forBird { return 160 + random.unit() * 200 }
            let progress = CGFloat(attempt) / CGFloat(attempts)
            return lengths.upperBound - (lengths.upperBound - lengths.lowerBound) * progress * (0.8 + random.unit() * 0.2)
        }
        for attempt in 0..<attempts {
            let forBird = perched.count < birds && attempt < 2000
            let level = forBird || random.unit() < 0.6
            let tilt = forBird ? (random.unit() - 0.5) * 0.5 : level ? (random.unit() - 0.5) * 0.9 : 0.6 + random.unit() * 0.5
            let bough = LowPolyTree.Bough(
                at: CGPoint(x: random.unit() * side, y: random.unit() * side),
                heading: (random.unit() < 0.5 ? 0 : .pi) + (random.unit() < 0.5 ? tilt : -tilt),
                length: length(forBird: forBird, attempt: attempt, random: &random),
                width: 8 + random.unit() * 8,
                curl: (random.unit() - 0.5) * 0.005,
                seed: UInt64(attempt) + 1,
                sprouts: true,
                bare: forBird
            )
            let grown = LowPolyTree([bough])
            // Cells clear all round, so branches keep apart rather than
            // touching.
            guard grown.marks.allSatisfy({ clear($0, by: Self.spacing) }) else { continue }
            let before = taken
            for mark in grown.marks {
                let (x, y) = cell(mark)
                taken[key(x, y)] = true
            }
            if forBird {
                // A level spot with nothing in the bird's way, far from the
                // other birds, wrapped. Its room is kept clear of the boughs
                // still to come.
                let seat = grown.perches.lazy.compactMap { perch -> (LowPolyTree.Perch, CGFloat, [CGPoint])? in
                    guard abs(perch.slope) < 0.35 else { return nil }
                    let apart = perched.allSatisfy { other in
                        var dx = abs(other.x - perch.at.x).truncatingRemainder(dividingBy: side)
                        var dy = abs(other.y - perch.at.y).truncatingRemainder(dividingBy: side)
                        dx = min(dx, side - dx)
                        dy = min(dy, side - dy)
                        return dx * dx + dy * dy > 170 * 170
                    }
                    guard apart else { return nil }
                    let faces: CGFloat = attempt % 2 == 0 ? 1 : -1
                    let room = LowPolyTree.birdRoom.map {
                        let turned = CGPoint(x: $0.x * faces, y: $0.y).applying(CGAffineTransform(rotationAngle: perch.slope))
                        return CGPoint(x: perch.at.x + turned.x, y: perch.at.y + turned.y)
                    }
                    return room.allSatisfy { clear($0, by: 0) } ? (perch, faces, room) : nil
                }.first
                guard let (perch, faces, room) = seat else {
                    taken = before
                    continue
                }
                for point in room {
                    let (x, y) = cell(point)
                    taken[key(x, y)] = true
                }
                lines.addPath(LowPolyTree.bird(on: perch, faces: faces))
                perched.append(perch.at)
            }
            lines.addPath(grown.lines)
        }
        self.lines = lines
    }
}

/// Branches drawn low poly: each a run of straight segments, a strip of
/// wireframe triangles where it's wide, a single line where it's thin, with
/// twigs off it and diamond leaves at their tips.
struct LowPolyTree {
    /// Where a bough starts, its heading in radians (down is positive), its
    /// length and width at the base, how much it curves per point, and the
    /// seed its twigs grow from.
    struct Bough {
        var at: CGPoint
        var heading: CGFloat
        var length: CGFloat
        var width: CGFloat
        var curl: CGFloat
        var seed: UInt64
        /// Whether it narrows to its start too, as if growing out of the
        /// bark, for a bough that starts in plain view.
        var sprouts = false
        /// Whether its twigs all hang below it, leaving its top bare for a
        /// bird.
        var bare = false
    }

    /// A near-level point on top of a bough or one of its first twigs, and
    /// the slope there.
    struct Perch {
        var at: CGPoint
        var slope: CGFloat
    }

    private(set) var lines = Path()
    private(set) var perches: [Perch] = []
    /// Points a few apart along everything drawn, to keep other things off.
    private(set) var marks: [CGPoint] = []

    init(_ boughs: [Bough]) {
        for bough in boughs {
            var random = Random(state: bough.seed &* 0x9E37_79B9_7F4A_7C15)
            grow(from: bough.at, heading: bough.heading, length: bough.length, width: bough.width, curl: bough.curl, depth: 0, sprouts: bough.sprouts, bare: bough.bare, random: &random)
        }
    }

    /// A bird sitting on a perch, leaning with it, facing right or left.
    static func bird(on perch: Perch, faces: CGFloat) -> Path {
        bird.applying(CGAffineTransform(scaleX: faces, y: 1)
            .concatenating(CGAffineTransform(rotationAngle: perch.slope))
            .concatenating(CGAffineTransform(translationX: perch.at.x, y: perch.at.y)))
    }

    /// Points over the space a bird facing right takes above its perch.
    static let birdRoom: [CGPoint] = {
        let bounds = bird.boundingRect
        var points: [CGPoint] = []
        for x in stride(from: bounds.minX, through: bounds.maxX, by: 3) {
            for y in stride(from: bounds.minY, through: -9, by: 3) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }()

    /// Walks a branch in short steps, its heading curling steadily and
    /// wandering a little, and draws it tapering to its tip. Twigs leave it
    /// on alternate sides, shorter the further out they start, and each tip
    /// ends in a leaf.
    private mutating func grow(from start: CGPoint, heading: CGFloat, length: CGFloat, width: CGFloat, curl: CGFloat, depth: Int, sprouts: Bool = false, bare: Bool = false, random: inout Random) {
        let step: CGFloat = 4
        let count = max(2, Int(length / step))
        var points = [start], headings = [heading]
        var heading = heading, wander: CGFloat = 0
        for _ in 0..<count {
            wander = (wander + (random.unit() - 0.5) * 0.02) * 0.9
            heading += curl * step + wander
            let last = points[points.count - 1]
            points.append(CGPoint(x: last.x + cos(heading) * step, y: last.y + sin(heading) * step))
            headings.append(heading)
        }
        func thickness(at index: Int) -> CGFloat {
            let t = CGFloat(index) / CGFloat(count)
            let tapered = width * (1 - t) + 0.5 * t
            return sprouts ? tapered * min(1, 0.25 + t * 4) : tapered
        }
        // Corners only every few steps, joined straight, so the branch comes
        // out faceted like the bird.
        let corner = depth == 0 ? 8 : 5
        let corners = Array(stride(from: 0, to: count, by: corner)) + [count]
        var left: [CGPoint] = [], right: [CGPoint] = [], middle: [CGPoint] = []
        for index in corners {
            let half = thickness(at: index) / 2
            let normal = CGPoint(x: -sin(headings[index]) * half, y: cos(headings[index]) * half)
            left.append(CGPoint(x: points[index].x + normal.x, y: points[index].y + normal.y))
            right.append(CGPoint(x: points[index].x - normal.x, y: points[index].y - normal.y))
            middle.append(points[index])
        }
        // Wide enough to show two edges: drawn as a strip of triangles.
        // Thinner: a single line.
        let facets = left.indices.dropLast().filter { thickness(at: corners[$0]) > 2.5 }
        for index in facets {
            lines.addLines([right[index], left[index], left[index + 1], right[index + 1], right[index]])
            lines.addLines([left[index], right[index + 1]])
        }
        let thin = facets.last.map { $0 + 1 } ?? 0
        if thin < middle.count - 1 {
            lines.addLines(Array(middle[thin...]))
        }
        for index in stride(from: 0, through: count, by: 2) {
            let half = thickness(at: index) / 2
            let normal = CGPoint(x: -sin(headings[index]) * half, y: cos(headings[index]) * half)
            marks += [points[index], CGPoint(x: points[index].x + normal.x, y: points[index].y + normal.y), CGPoint(x: points[index].x - normal.x, y: points[index].y - normal.y)]
        }
        if depth <= 1 {
            for index in corners where index >= count / 4 && index < count * 3 / 4 {
                var slope = headings[index].truncatingRemainder(dividingBy: 2 * .pi)
                if slope > .pi / 2 { slope -= .pi } else if slope < -.pi / 2 { slope += .pi }
                if abs(slope) < 0.5 {
                    perches.append(Perch(at: CGPoint(x: points[index].x, y: points[index].y - thickness(at: index) / 2), slope: slope))
                }
            }
        }
        if depth < 3 {
            var side: CGFloat = random.unit() < 0.5 ? 1 : -1
            // Twigs leave from corners, where the branch already bends.
            var index = max(1, Int(CGFloat(count) * (0.18 + random.unit() * 0.12)) / corner) * corner
            while index < count - corner {
                if bare {
                    // Down the screen is a positive y.
                    side = sin(headings[index] + 0.6) > sin(headings[index] - 0.6) ? 1 : -1
                }
                let reach = length * (1 - CGFloat(index) / CGFloat(count)) * (0.35 + random.unit() * 0.3)
                let turn = side * (0.45 + random.unit() * 0.35)
                if reach > 14 {
                    grow(from: points[index], heading: headings[index] + turn, length: reach, width: max(1, thickness(at: index) * 0.5), curl: curl * (random.unit() < 0.5 ? 1.5 : -1.5), depth: depth + 1, random: &random)
                } else {
                    leaf(at: points[index], heading: headings[index] + side * 0.8, size: 8, random: &random)
                }
                side = -side
                index += max(1, Int(CGFloat(count) * (0.16 + random.unit() * 0.14)) / corner) * corner
            }
        }
        leaf(at: points[count], heading: headings[count], size: 9, random: &random)
    }

    /// A leaf as a diamond split down its vein, drawn like the birds.
    private mutating func leaf(at point: CGPoint, heading: CGFloat, size: CGFloat, random: inout Random) {
        let size = size * (0.8 + random.unit() * 0.4)
        let place = CGAffineTransform(rotationAngle: heading).concatenating(CGAffineTransform(translationX: point.x, y: point.y))
        let shape = [CGPoint.zero, CGPoint(x: size * 0.4, y: -size * 0.3), CGPoint(x: size, y: 0), CGPoint(x: size * 0.4, y: size * 0.3), .zero, CGPoint(x: size, y: 0)]
            .map { $0.applying(place) }
        lines.addLines(shape)
        marks += shape
    }

    /// The app icon's bird, sitting at the origin, drawn in straight lines:
    /// a faceted outline with its belly, face, wing and tail.
    private static let bird: Path = {
        // In the icon's own coordinates, where the bird sits at (512, 640).
        func points(_ xy: [(CGFloat, CGFloat)]) -> [CGPoint] { xy.map { CGPoint(x: $0.0, y: $0.1) } }
        var path = Path()
        func line(_ xy: [(CGFloat, CGFloat)], closed: Bool = false) {
            path.addLines(points(xy))
            if closed { path.closeSubpath() }
        }
        // Body and belly.
        line([(305, 640), (318, 540), (360, 450), (430, 390), (512, 370), (595, 390), (665, 450), (707, 540), (720, 640)])
        line([(400, 640), (410, 560), (450, 515), (512, 500), (575, 515), (615, 560), (626, 640)])
        // Facets on the forehead and down the near side.
        line([(430, 390), (470, 425), (512, 370), (555, 425), (595, 390)])
        line([(470, 425), (555, 425)])
        line([(360, 450), (470, 425)])
        line([(305, 640), (360, 560), (318, 540)])
        line([(360, 450), (360, 560), (400, 640)])
        line([(360, 560), (410, 560)])
        // Head feathers.
        line([(500, 372), (472, 326), (480, 290), (506, 334)], closed: true)
        line([(516, 372), (538, 322), (565, 308), (554, 346)], closed: true)
        // Closed eyes, and the beak open in a chirp.
        line([(425, 468), (446, 450), (468, 468)])
        line([(556, 468), (577, 450), (599, 468)])
        line([(478, 490), (512, 474), (546, 490), (512, 512)], closed: true)
        line([(478, 490), (546, 490)])
        // Wing and tail.
        line([(655, 535), (704, 556), (712, 640), (664, 602)], closed: true)
        line([(655, 535), (712, 640)])
        line([(712, 560), (820, 470), (796, 562), (718, 612)], closed: true)
        line([(712, 560), (796, 562)])
        return path.applying(CGAffineTransform(scaleX: 0.16, y: 0.16).translatedBy(x: -512, y: -640))
    }()

    struct Random {
        var state: UInt64

        mutating func unit() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
    }
}
