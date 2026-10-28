#if DEBUG
import CryptoKit
import Foundation
import GRDB
import UIKit
import YapnestKit

/// The account the App Store screenshots are taken from:
/// `YAPNEST_DEV_FIXTURE=screenshots`, driven by `dev/screenshots.sh`. Times
/// are relative to the launch, so the chats read as current.
enum ScreenshotsFixture {
    static let lea = JID("lea@fixture.test")!
    static let sam = JID("sam@fixture.test")!
    static let priya = JID("priya@fixture.test")!
    static let jonas = JID("jonas@fixture.test")!
    static let mei = JID("mei@fixture.test")!
    static let climbing = JID("climbing@groups.fixture.test")!
    static let bookClub = JID("bookclub@groups.fixture.test")!

    /// Our nickname in both groups.
    private static let nickname = "Jules"

    private static var directory: AccountDirectory { AccountDirectory(account: DevFixture.account) }

    static func fill(_ database: AppDatabase) throws {
        let files = directory.attachments.directory
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try sunset().write(to: files.appending(path: "screenshots-sunset.jpg"), options: .atomic)

        for (jid, name, hue, motif) in [
            (lea, "Léa Martin", 0.02, Motif.sun), (sam, "Sam Okafor", 0.58, .mountain), (priya, "Priya", 0.80, .leaf),
            (jonas, "Jonas", 0.38, .mountain), (mei, "Mei", 0.10, .sun),
        ] as [(JID, String, Double, Motif)] {
            try database.updateRosterItem(jid: jid, name: name, subscription: .both, isPending: false)
            try database.setAvatarHash(try saveAvatar(hue: hue, motif: motif), for: jid)
        }

        try database.setAvatarHash(try saveAvatar(hue: 0.5, motif: .leaf), for: DevFixture.account)
        try fillLea(database)
        try fillClimbing(database)
        try fillSam(database)
        try fillBookClub(database)
        try fillPriya(database)
        try fillMei(database)
        try fillJonas(database)
    }

    /// What a server would tell the session: who is online, and the rooms.
    static func configure(_ session: XMPPSession) {
        for (jid, presence) in [(lea, ContactPresence.online), (sam, .online), (jonas, .away), (mei, .online)] {
            session.receivePresenceForFixture(jid, presence)
        }
        for room in [climbing, bookClub] {
            session.joinForFixture(room, occupants: [
                RoomOccupant(nick: nickname, jid: DevFixture.account, affiliation: .member),
                RoomOccupant(nick: "Sam", jid: sam, affiliation: .owner, role: "moderator"),
                RoomOccupant(nick: "Priya", jid: priya, affiliation: .member),
                RoomOccupant(nick: "Jonas", jid: jonas, affiliation: .member),
                RoomOccupant(nick: "Mei", jid: mei, affiliation: .member),
            ])
        }
    }

    // MARK: Chats

    private typealias Line = DevFixture.Line

    private static func chat(_ database: AppDatabase, _ peer: JID) throws -> Conversation {
        try DevFixture.completeChat(database, peer)
    }

    private static func room(_ database: AppDatabase, _ jid: JID, name: String, hue: Double, motif: Motif) throws -> Conversation {
        _ = try database.joinGroupChat(jid, nickname: nickname, name: name, isBookmarked: true)
        try database.updateGroupChat(jid) { $0.isMembersOnly = true; $0.isNonAnonymous = true }
        try database.setAvatarHash(try saveAvatar(hue: hue, motif: motif), for: jid)
        try database.setEncrypted(true, with: jid)
        return try DevFixture.completeChat(database, jid)
    }

    /// Writes into a chat of this fixture, whose group members are `crew`.
    private static func write(_ database: AppDatabase, _ conversation: Conversation, _ lines: [Line]) throws {
        try DevFixture.write(database, conversation, nickname: nickname, nicks: crew, lines)
    }

    private static func fillLea(_ database: AppDatabase) throws {
        let conversation = try chat(database, lea)
        try database.setPinned(true, conversationId: conversation.id!)
        try write(database, conversation, [
            Line(minutesAgo: 54, from: lea, body: "Sunrise hike on Saturday? I'll bring the thermos!", id: "lea-snacks"),
            Line(minutesAgo: 47, from: lea, body: "You're the best. Remember this view?"),
            Line(minutesAgo: 46, from: lea, body: "", photo: true, reactions: [(DevFixture.account, "😍"), (sam, "🔥")]),
            Line(minutesAgo: 41, from: lea, body: "Trailhead at 5:30? Dress warm!"),
            Line(minutesAgo: 38, body: "Also, I'm bringing the little stove. Hot chocolate at the summit?",
                 replyTo: (id: "lea-snacks", sender: lea, text: "Sunrise hike on Saturday? I'll bring the thermos!"),
                 reactions: [(lea, "❤️")]),
            Line(minutesAgo: 12, body: "Packed and ready. See you at 5:30! 🏔️"),
        ])
    }

    private static let crew = [sam: "Sam", priya: "Priya", jonas: "Jonas", mei: "Mei"]

    private static func fillClimbing(_ database: AppDatabase) throws {
        let conversation = try room(database, climbing, name: "Climbing crew", hue: 0.07, motif: .mountain)
        try write(database, conversation, [
            Line(minutesAgo: 50, from: sam, body: "Gym is open late tonight, anyone in?", id: "c-open"),
            Line(minutesAgo: 48, from: jonas, body: "I'm in. Trying that new overhang route 😅", reactions: [(sam, "🔥"), (mei, "🔥"), (DevFixture.account, "💪")]),
            Line(minutesAgo: 47, from: mei, body: "Count me in, 7pm?", id: "c-mei"),
            Line(minutesAgo: 45, from: sam, body: "7 works. @\(nickname) are you coming?", mention: true),
            Line(minutesAgo: 44, body: "Yes! Just finishing work, I'll be there by 7"),
            Line(minutesAgo: 41, from: priya, body: "Same, I'll bring snacks for after 🍪", replyTo: (id: "c-mei", sender: mei, text: "Count me in, 7pm?")),
            Line(minutesAgo: 39, from: jonas, body: "Someone please remind me to chalk up this time"),
            Line(minutesAgo: 6, from: sam, body: "Parking is full, use the side street!", reactions: [(priya, "👍")]),
        ])
    }

    private static func fillSam(_ database: AppDatabase) throws {
        let conversation = try chat(database, sam)
        try write(database, conversation, [
            Line(minutesAgo: 30, body: "Table's booked for 8, see you there"),
            Line(minutesAgo: 11, from: sam, body: "Running ten minutes late", read: false),
            Line(minutesAgo: 9, from: sam, body: "Save me a seat? I'll buy the first round 🍻", read: false),
        ])
    }

    private static func fillBookClub(_ database: AppDatabase) throws {
        let conversation = try room(database, bookClub, name: "Book club", hue: 0.78, motif: .leaf)
        try write(database, conversation, [
            Line(minutesAgo: 80, body: "Finished the last chapter on the train"),
            Line(minutesAgo: 24, from: priya, body: "Chapter 12 changed everything for me 📖", read: false),
            Line(minutesAgo: 23, from: mei, body: "Don't spoil it!", read: false),
            Line(minutesAgo: 22, from: priya, body: "I would never. Thursday?", read: false),
        ])
    }

    private static func fillPriya(_ database: AppDatabase) throws {
        let conversation = try chat(database, priya)
        try write(database, conversation, [
            Line(minutesAgo: 125, body: "How was the market?"),
            Line(minutesAgo: 100, from: priya, body: "", photo: true),
        ])
    }

    private static func fillMei(_ database: AppDatabase) throws {
        let conversation = try chat(database, mei)
        try write(database, conversation, [
            Line(minutesAgo: 190, from: mei, body: "/me raises a glass to the new job 🥂"),
        ])
    }

    private static func fillJonas(_ database: AppDatabase) throws {
        let conversation = try chat(database, jonas)
        try write(database, conversation, [
            Line(minutesAgo: 1600, body: "Thanks for the lift! ☕"),
        ])
    }

    // MARK: Pictures

    private enum Motif { case sun, mountain, leaf }

    /// A picture in the avatar store, named by its hash as the store expects.
    private static func saveAvatar(hue: Double, motif: Motif) throws -> String {
        let data = avatar(hue: hue, motif: motif)
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let store = directory.avatars
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try data.write(to: store.url(for: hash), options: .atomic)
        return hash
    }

    private static func gradient(_ colors: [UIColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: locations)!
    }

    private static func avatar(hue: Double, motif: Motif) -> Data {
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let cg = context.cgContext
            let top = UIColor(hue: hue, saturation: 0.45, brightness: 0.98, alpha: 1)
            let bottom = UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.78, alpha: 1)
            cg.drawLinearGradient(gradient([top, bottom]), start: .zero, end: CGPoint(x: 0, y: 256), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            switch motif {
            case .sun:
                cg.fillEllipse(in: CGRect(x: 78, y: 62, width: 100, height: 100))
                UIColor.white.withAlphaComponent(0.4).setFill()
                cg.fill(CGRect(x: 0, y: 190, width: 256, height: 66))
            case .mountain:
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: 230)); path.addLine(to: CGPoint(x: 90, y: 90)); path.addLine(to: CGPoint(x: 150, y: 170))
                path.addLine(to: CGPoint(x: 190, y: 120)); path.addLine(to: CGPoint(x: 256, y: 230)); path.close()
                path.fill()
                cg.fillEllipse(in: CGRect(x: 170, y: 40, width: 44, height: 44))
            case .leaf:
                let leaf = UIBezierPath()
                leaf.move(to: CGPoint(x: 70, y: 190))
                leaf.addQuadCurve(to: CGPoint(x: 190, y: 66), controlPoint: CGPoint(x: 60, y: 70))
                leaf.addQuadCurve(to: CGPoint(x: 70, y: 190), controlPoint: CGPoint(x: 200, y: 200))
                leaf.fill()
            }
        }
    }

    /// A mountain sunset, from gradients and shapes.
    private static func sunset() -> Data {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.9) { context in
            let cg = context.cgContext
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
            cg.drawLinearGradient(
                gradient([color(40, 40, 110), color(150, 80, 140), color(244, 130, 100), color(255, 205, 130)], [0, 0.35, 0.65, 0.85]),
                start: .zero, end: CGPoint(x: 0, y: 700), options: [.drawsAfterEndLocation])
            // The sun with a glow around it.
            let sun = CGPoint(x: 780, y: 560)
            cg.drawRadialGradient(
                gradient([UIColor(white: 1, alpha: 0.9), UIColor(red: 1, green: 0.8, blue: 0.5, alpha: 0.35), UIColor(red: 1, green: 0.6, blue: 0.4, alpha: 0)], [0, 0.25, 1]),
                startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 420, options: [])
            color(255, 244, 214).setFill()
            cg.fillEllipse(in: CGRect(x: sun.x - 60, y: sun.y - 60, width: 120, height: 120))
            // Ranges from far to near, each darker.
            let ranges: [(UIColor, [CGPoint])] = [
                (color(176, 110, 140), [(0, 640), (150, 520), (300, 600), (470, 470), (640, 610), (820, 500), (1000, 600), (1200, 530)].map { CGPoint(x: $0.0, y: $0.1) }),
                (color(112, 70, 120), [(0, 700), (200, 590), (380, 680), (560, 560), (760, 690), (960, 600), (1200, 700)].map { CGPoint(x: $0.0, y: $0.1) }),
                (color(52, 38, 84), [(0, 780), (170, 660), (330, 760), (520, 640), (700, 790), (920, 700), (1200, 800)].map { CGPoint(x: $0.0, y: $0.1) }),
            ]
            for (fill, points) in ranges {
                fill.setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: 900))
                for point in points { path.addLine(to: point) }
                path.addLine(to: CGPoint(x: 1200, y: 900)); path.close()
                path.fill()
            }
            // Pines on the nearest ridge.
            color(26, 22, 52).setFill()
            for (x, y, h) in [(80, 800, 130), (140, 810, 100), (1010, 770, 140), (1080, 790, 110), (1140, 800, 90)] as [(CGFloat, CGFloat, CGFloat)] {
                let tree = UIBezierPath()
                tree.move(to: CGPoint(x: x, y: y - h)); tree.addLine(to: CGPoint(x: x + h * 0.22, y: y)); tree.addLine(to: CGPoint(x: x - h * 0.22, y: y)); tree.close()
                tree.fill()
            }
            cg.fill(CGRect(x: 0, y: 800, width: 1200, height: 100))
        }
    }
}
#endif
