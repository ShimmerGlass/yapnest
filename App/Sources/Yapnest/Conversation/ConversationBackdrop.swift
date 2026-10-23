import SwiftUI

/// Faint circuit traces in a grey mauve behind a conversation's messages. They
/// stay put while the messages scroll over them, so the list draws nothing
/// more as it moves, and the pattern is one tile laid out again and again.
struct ConversationBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { .circuitInk(colorScheme) }

    var body: some View {
        Canvas { context, size in
            let tile = CircuitTile.shared
            let side = CircuitTile.side
            // Traces leave their tile, so the row and column before the first
            // are drawn too, for what reaches in from them.
            var y = -side
            while y < size.height {
                var x = -side
                while x < size.width {
                    var placed = context
                    placed.translateBy(x: x, y: y)
                    placed.stroke(tile.traces, with: .color(ink), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
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
    /// The circuit lines' grey mauve, faint against either background.
    static func circuitInk(_ scheme: ColorScheme, strength: Double = 1) -> Color {
        scheme == .dark
            ? Color(red: 0xB8 / 255, green: 0x9C / 255, blue: 0xCC / 255).opacity(0.12 * strength)
            : Color(red: 0x7A / 255, green: 0x5A / 255, blue: 0x8E / 255).opacity(0.12 * strength)
    }
}

/// A few faint branches reaching in out of the chat list's mauve wash, with a
/// couple of wireframe birds perched on them, fading with the wash.
struct ChatListBranches: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Where a bough comes in, its heading in radians (down is positive), its
    /// length and width at the base, how much it curves per point, and the
    /// seed its twigs grow from.
    private struct Bough {
        var at: CGPoint
        var heading: CGFloat
        var length: CGFloat
        var width: CGFloat
        var curl: CGFloat
        var seed: UInt64
    }

    /// Laid out for a phone 393 points wide: one bough in from each side,
    /// below the title and search field, and a thinner one hanging from the
    /// top.
    private static let boughs = [
        Bough(at: CGPoint(x: -12, y: 150), heading: 0.42, length: 300, width: 16, curl: -0.0016, seed: 3),
        Bough(at: CGPoint(x: 405, y: 215), heading: .pi - 0.38, length: 250, width: 13, curl: 0.0018, seed: 8),
        Bough(at: CGPoint(x: 300, y: -10), heading: 1.9, length: 150, width: 8, curl: -0.002, seed: 5),
    ]

    /// Which of the level spots the birds take, and which way each faces:
    /// apart from each other and clear of the twigs.
    private static let birds: [(perch: Int, faces: CGFloat)] = [(2, 1), (10, -1)]

    private struct Tree {
        var wood = Path()
        var leaves = Path()
        /// Points along the boughs and their first twigs that are near level,
        /// with their slope.
        var perches: [(at: CGPoint, slope: CGFloat)] = []
    }

    private static let tree: Tree = {
        var tree = Tree()
        for bough in boughs {
            var random = Random(state: bough.seed &* 0x9E37_79B9_7F4A_7C15)
            grow(&tree, from: bough.at, heading: bough.heading, length: bough.length, width: bough.width, curl: bough.curl, depth: 0, random: &random)
        }
        return tree
    }()

    /// Walks a branch in short steps, its heading curling steadily and
    /// wandering a little, and draws it tapering to its tip. Twigs
    /// leave it on alternate sides, shorter the further out they start, and
    /// each tip ends in a leaf.
    private static func grow(_ tree: inout Tree, from start: CGPoint, heading: CGFloat, length: CGFloat, width: CGFloat, curl: CGFloat, depth: Int, random: inout Random) {
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
            return width * (1 - t) + 0.5 * t
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
            tree.wood.addLines([right[index], left[index], left[index + 1], right[index + 1], right[index]])
            tree.wood.addLines([left[index], right[index + 1]])
        }
        let thin = (facets.last.map { $0 + 1 } ?? 0)
        if thin < middle.count - 1 {
            tree.wood.addLines(Array(middle[thin...]))
        }
        if depth <= 1 {
            for index in corners where index >= count / 4 && index < count * 3 / 4 {
                var slope = headings[index].truncatingRemainder(dividingBy: 2 * .pi)
                if slope > .pi / 2 { slope -= .pi } else if slope < -.pi / 2 { slope += .pi }
                if abs(slope) < 0.5 {
                    tree.perches.append((CGPoint(x: points[index].x, y: points[index].y - thickness(at: index) / 2), slope))
                }
            }
        }
        if depth < 3 {
            var side: CGFloat = random.unit() < 0.5 ? 1 : -1
            // Twigs leave from corners, where the branch already bends.
            var index = max(1, Int(CGFloat(count) * (0.18 + random.unit() * 0.12)) / corner) * corner
            while index < count - corner {
                let reach = length * (1 - CGFloat(index) / CGFloat(count)) * (0.35 + random.unit() * 0.3)
                let turn = side * (0.45 + random.unit() * 0.35)
                if reach > 14 {
                    grow(&tree, from: points[index], heading: headings[index] + turn, length: reach, width: max(1, thickness(at: index) * 0.5), curl: curl * (random.unit() < 0.5 ? 1.5 : -1.5), depth: depth + 1, random: &random)
                } else {
                    leaf(&tree, at: points[index], heading: headings[index] + side * 0.8, size: 8, random: &random)
                }
                side = -side
                index += max(1, Int(CGFloat(count) * (0.16 + random.unit() * 0.14)) / corner) * corner
            }
        }
        leaf(&tree, at: points[count], heading: headings[count], size: 9, random: &random)
    }

    /// A leaf as a diamond split down its vein, drawn like the birds.
    private static func leaf(_ tree: inout Tree, at point: CGPoint, heading: CGFloat, size: CGFloat, random: inout Random) {
        let size = size * (0.8 + random.unit() * 0.4)
        var leaf = Path()
        leaf.addLines([.zero, CGPoint(x: size * 0.4, y: -size * 0.3), CGPoint(x: size, y: 0), CGPoint(x: size * 0.4, y: size * 0.3), .zero, CGPoint(x: size, y: 0)])
        tree.leaves.addPath(leaf, transform: CGAffineTransform(rotationAngle: heading)
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
    }

    private struct Random {
        var state: UInt64

        mutating func unit() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
    }

    var body: some View {
        Canvas { context, size in
            let scale = CGAffineTransform(scaleX: size.width / 393, y: size.width / 393)
            var lines = Self.tree.wood
            lines.addPath(Self.tree.leaves)
            for bird in Self.birds {
                let perch = Self.tree.perches[bird.perch]
                lines.addPath(CircuitTile.bird, transform: CGAffineTransform(scaleX: bird.faces, y: 1)
                    .concatenating(CGAffineTransform(rotationAngle: perch.slope))
                    .concatenating(CGAffineTransform(translationX: perch.at.x, y: perch.at.y)))
            }
            // Stronger than a chat's, as the fade takes most of it away.
            let ink = Color.circuitInk(colorScheme, strength: 1.8)
            context.stroke(lines.applying(scale), with: .color(ink), style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
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

/// One tile of the pattern, laid out once from a fixed seed: long traces that
/// run straight, bend by 45 degrees and run on, some in parallel buses, and a
/// few birds perched on them. Each claims the grid points it covers, with the
/// tile's edges wrapped, so none cross, here or where one tile meets the next;
/// some run on to join another.
struct CircuitTile {
    static let side: CGFloat = 720
    static let shared = CircuitTile()

    private static let pitch: CGFloat = 6
    private static var cells: Int { Int(side / pitch) }

    let traces: Path

    private init() {
        var random = Random(state: 0x5EED_CAFE)
        var taken = [Bool](repeating: false, count: Self.cells * Self.cells)
        // The points single traces run through, which others may join.
        var wire = taken
        var traces = Path()
        let n = Self.cells

        func key(_ x: Int, _ y: Int) -> Int { ((x % n + n) % n) * n + (y % n + n) % n }

        /// Whether a point is clear of everything taken by more than the
        /// given number of cells.
        func clear(_ p: (Int, Int), by reach: Int) -> Bool {
            for dx in -reach...reach { for dy in -reach...reach where taken[key(p.0 + dx, p.1 + dy)] { return false } }
            return true
        }

        func take(_ points: [(Int, Int)], width: Int) {
            for p in points {
                for dx in -width...width { for dy in -width...width { taken[key(p.0 + dx, p.1 + dy)] = true } }
            }
        }

        // Eight directions, a step of one grid cell each.
        let directions = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]

        func walk(from start: (Int, Int), _ legs: [(Int, Int)]) -> [(Int, Int)] {
            var p = start
            var points = [p]
            for leg in legs {
                for _ in 0..<leg.1 {
                    p = (p.0 + directions[leg.0].0, p.1 + directions[leg.0].1)
                    points.append(p)
                }
            }
            return points
        }

        // The birds first, each perched in the middle of a straight run,
        // flat or at 45 degrees, with the trace bending into it and away.
        var perched = 0
        while perched < 7 {
            let heading = perched < 3 ? (random.next(2) == 0 ? 1 : 7) : 0
            let run = heading == 0 ? 26 + random.next(10) : 19 + random.next(8)
            let approach = 6 + random.next(14)
            let points = walk(from: (random.next(n), random.next(n)), [
                ((heading + (random.next(2) == 0 ? 1 : 7)) % 8, approach),
                (heading, run),
                ((heading + (random.next(2) == 0 ? 1 : 7)) % 8, 6 + random.next(14)),
            ])
            let seat = points[approach + run / 2]
            // The bird leans with the line, its feet along it.
            let lean = heading == 0 ? 0 : heading == 1 ? CGFloat.pi / 4 : -CGFloat.pi / 4
            var room: [(Int, Int)] = []
            for x in stride(from: -9.0, through: 9.0, by: 0.5) {
                for y in stride(from: -10.0, through: 0.0, by: 0.5) {
                    let turned = CGPoint(x: x, y: y).applying(CGAffineTransform(rotationAngle: lean))
                    room.append((seat.0 + Int(turned.x.rounded()), seat.1 + Int(turned.y.rounded())))
                }
            }
            guard (points + room).allSatisfy({ clear($0, by: 2) }) else { continue }
            take(points + room, width: 0)
            for p in points { wire[key(p.0, p.1)] = true }
            traces.addLines(Self.corners(points).map(Self.point))
            let at = Self.point(seat)
            traces.addPath(Self.bird, transform: CGAffineTransform(scaleX: random.next(2) == 0 ? 1 : -1, y: 1)
                .concatenating(CGAffineTransform(rotationAngle: lean))
                .concatenating(CGAffineTransform(translationX: at.x, y: at.y)))
            perched += 1
        }

        // Long traces, each cut short where it would come near another, and
        // kept if what's left is still long and still bends.
        // Fewer start flat, which left the screen's edges striped.
        let headings = [2, 6, 2, 6, 1, 3, 5, 7, 0, 4]
        for _ in 0..<20000 {
            let heading = headings[random.next(headings.count)]
            let turn = random.next(2) == 0 ? 1 : 7
            let planned = walk(from: (random.next(n), random.next(n)), [
                (heading, 10 + random.next(30)),
                ((heading + turn) % 8, 4 + random.next(16)),
                (random.next(3) == 0 ? (heading + turn * 2) % 8 : heading, 10 + random.next(40)),
            ])
            let lanes = random.next(3) == 0 ? 2 + random.next(3) : 1
            // A bus's lanes lie to one side of the first, within the width
            // it takes.
            let width = (lanes - 1) * 3 / 2
            var points = Array(planned.prefix { clear($0, by: width + 1) })
            // Some run on into the line they were nearing and join it,
            // where they meet one of its points head on.
            var joins = false
            if lanes == 1, points.count < planned.count, random.next(2) == 0 {
                var run = points
                for p in planned[points.count...].prefix(4) {
                    run.append(p)
                    if taken[key(p.0, p.1)] {
                        joins = wire[key(p.0, p.1)]
                        break
                    }
                }
                if joins { points = run }
            }
            let corners = points.count >= 12 ? Self.corners(points).map(Self.point) : []
            guard corners.count >= (joins ? 2 : 3) else { continue }
            take(points, width: width)
            if lanes == 1 { for p in points { wire[key(p.0, p.1)] = true } }

            let gap = Self.pitch * 1.5
            for lane in 0..<lanes {
                traces.addLines(Self.offset(corners, by: CGFloat(lane) * gap))
            }
        }
        self.traces = traces
    }

    /// The app icon's bird, sitting at the origin, drawn in straight lines:
    /// a faceted outline with its belly, face, wing and tail.
    static let bird: Path = {
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

    /// The points where a run of grid steps changes direction, with its ends.
    private static func corners(_ points: [(Int, Int)]) -> [(Int, Int)] {
        var result = [points[0]]
        for i in 1..<points.count - 1 {
            let before = (points[i].0 - points[i - 1].0, points[i].1 - points[i - 1].1)
            let after = (points[i + 1].0 - points[i].0, points[i + 1].1 - points[i].1)
            if before != after { result.append(points[i]) }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// The line run parallel to the given one at a distance to its right,
    /// mitred at the corners so the lanes of a bus keep their spacing through
    /// the bends.
    static func offset(_ line: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        guard distance != 0 else { return line }
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGVector {
            let dx = b.x - a.x, dy = b.y - a.y, length = (dx * dx + dy * dy).squareRoot()
            return CGVector(dx: -dy / length, dy: dx / length)
        }
        return line.indices.map { i in
            let before = i > 0 ? normal(line[i - 1], line[i]) : nil
            let after = i < line.count - 1 ? normal(line[i], line[i + 1]) : nil
            let a = before ?? after!, b = after ?? before!
            let sum = CGVector(dx: a.dx + b.dx, dy: a.dy + b.dy)
            let scale = distance * 2 / (sum.dx * sum.dx + sum.dy * sum.dy)
            return CGPoint(x: line[i].x + sum.dx * scale, y: line[i].y + sum.dy * scale)
        }
    }

    private static func point(_ p: (Int, Int)) -> CGPoint {
        CGPoint(x: CGFloat(p.0) * pitch, y: CGFloat(p.1) * pitch)
    }

    /// A small fixed-seed generator, so every chat and every launch draws the
    /// same pattern.
    private struct Random {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }
}
