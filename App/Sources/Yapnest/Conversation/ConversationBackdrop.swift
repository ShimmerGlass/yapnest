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

/// A few circuit lines running down out of the chat list's mauve wash, and
/// fading with it.
struct ChatListTraces: View {
    @Environment(\.colorScheme) private var colorScheme

    /// A line's start across the top, and each leg's run across and down:
    /// straight, flat or at 45 degrees. The last runs on out of sight. Lanes
    /// are drawn beside it, this far apart.
    private struct Trace {
        var x: CGFloat
        var legs: [(dx: CGFloat, dy: CGFloat)]
        var lanes = 1
        var gap: CGFloat = 9
    }

    /// Two fans closing in on the middle, either side of a line with a ledge,
    /// laid out for a phone 393 points wide. Every bend comes below the title
    /// and search field.
    private static let traces: [Trace] = {
        let left = [
            Trace(x: 18, legs: [(0, 290), (84, 84), (0, 60), (-60, 60), (0, 1000)]),
            Trace(x: 48, legs: [(0, 220), (66, 66), (0, 1000)], lanes: 2, gap: -9),
        ]
        let mirrored = left.map { trace in
            var trace = trace
            trace.x = 393 - trace.x
            trace.legs = trace.legs.map { (-$0.dx, $0.dy) }
            trace.gap = -trace.gap
            return trace
        }
        let middle = Trace(x: 196, legs: [(0, 370), (-30, 30), (70, 0), (0, 1000)])
        return left + mirrored + [middle]
    }()

    /// Where the birds sit, how they lean with the line under them, and
    /// which way they face: two on the outer lines' way in, and one on the
    /// middle line's ledge, below the first chats.
    private static let birds: [(at: CGPoint, lean: CGFloat, faces: CGFloat)] = [
        (CGPoint(x: 60, y: 332), .pi / 4, 1),
        (CGPoint(x: 333, y: 332), -.pi / 4, -1),
        (CGPoint(x: 201, y: 400), 0, 1),
    ]

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for trace in Self.traces {
                var point = CGPoint(x: trace.x, y: 0)
                var line = [point]
                for leg in trace.legs {
                    point = CGPoint(x: point.x + leg.dx, y: point.y + leg.dy)
                    line.append(point)
                }
                for lane in 0..<trace.lanes {
                    path.addLines(CircuitTile.offset(line, by: CGFloat(lane) * trace.gap))
                }
            }
            for bird in Self.birds {
                path.addPath(CircuitTile.bird, transform: CGAffineTransform(scaleX: bird.faces, y: 1)
                    .concatenating(CGAffineTransform(rotationAngle: bird.lean))
                    .concatenating(CGAffineTransform(translationX: bird.at.x, y: bird.at.y)))
            }
            let scale = size.width / 393
            path = path.applying(CGAffineTransform(scaleX: scale, y: scale))
            // Stronger than a chat's, as the fade takes most of it away.
            context.stroke(path, with: .color(.circuitInk(colorScheme, strength: 1.8)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
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
