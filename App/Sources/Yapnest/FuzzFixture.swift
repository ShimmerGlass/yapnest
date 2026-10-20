#if DEBUG
import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import YapnestKit

/// Seeded conversations that mix everything the message list draws, for
/// layout and scrolling bugs no hand-made fixture thought of. Set with
/// `YAPNEST_DEV_FIXTURE=fuzz:<seed>`. The same seed always gives the same two
/// chats, a 1:1 chat and a group, so a failure can be replayed.
///
/// What the chats hold is worked out first as a `FuzzPlan`, without touching
/// the database, so it can be checked by unit tests; `fill` then writes it
/// the way the app stores what it receives, files and previews included, as
/// if everything had already been downloaded. Nothing is fetched.
struct FuzzFixture {
    let seed: UInt64

    static let chatPeer = JID("fuzz@fixture.test")!
    static let chatName = "Fuzz"
    static let groupPeer = JID("fuzz-group@conference.fixture.test")!
    static let groupName = "Fuzz Group"
    /// Our nickname in the group, which mentions say.
    static let nickname = "Fixture"
    static let groupNicks = ["Robin", "Wren", "Finch", "Lark", "Swift"]

    /// `fuzz:<seed>`, or `fuzz` alone for seed 1.
    static func seed(from name: String) -> UInt64? {
        if name == "fuzz" { return 1 }
        guard name.hasPrefix("fuzz:") else { return nil }
        return UInt64(name.dropFirst("fuzz:".count))
    }

    static var requested: FuzzFixture? {
        ProcessInfo.processInfo.environment["YAPNEST_DEV_FIXTURE"].flatMap(seed(from:)).map(FuzzFixture.init(seed:))
    }

    /// The words the newest message of each chat ends with, for finding it
    /// from a test.
    static func newestMarker(seed: UInt64) -> String { "Fuzz \(seed) newest." }
    static func groupNewestMarker(seed: UInt64) -> String { "Fuzz \(seed) group newest." }

    var plan: FuzzPlan { FuzzPlan(seed: seed) }

    func fill(_ database: AppDatabase, directory: AccountDirectory = AccountDirectory(account: DevFixture.account)) throws {
        let plan = plan
        let files = FuzzFiles(attachments: directory.attachments.directory, previews: directory.previews, seed: seed)

        try database.updateRosterItem(jid: Self.chatPeer, name: Self.chatName, subscription: .both, isPending: false)
        let chat = try database.conversation(with: Self.chatPeer)
        try database.setHistoryState(peer: Self.chatPeer, isComplete: true, cursor: nil)
        try database.setLinkPreviews(plan.chat.previewsAllowed, peer: Self.chatPeer)
        try write(plan.chat, into: chat, peer: Self.chatPeer, isGroup: false, database: database, files: files)

        let group = try database.joinGroupChat(Self.groupPeer, nickname: Self.nickname, name: Self.groupName)
        try database.setHistoryState(peer: Self.groupPeer, isComplete: true, cursor: nil)
        try database.setLinkPreviews(plan.group.previewsAllowed, peer: Self.groupPeer)
        guard let groupConversation = try database.conversation(id: group.conversationId) else { return }
        try write(plan.group, into: groupConversation, peer: Self.groupPeer, isGroup: true, database: database, files: files)
    }

    /// A fixed time, so day headers are the same on every run.
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func write(_ chat: FuzzPlan.Chat, into conversation: Conversation, peer: JID, isGroup: Bool, database: AppDatabase, files: FuzzFiles) throws {
        let prefix = isGroup ? "fz-g" : "fz-c"
        let account = DevFixture.account
        func remoteId(_ index: Int) -> String { "\(prefix)-\(index)" }
        func sender(of planned: FuzzMessage) -> JID { planned.outgoing ? account : peer }

        for (index, planned) in chat.messages.enumerated() {
            var message = Message(
                conversationId: conversation.id!,
                direction: planned.outgoing ? .outgoing : .incoming,
                sender: sender(of: planned),
                nick: isGroup ? planned.nick : nil,
                occupantId: isGroup ? planned.nick.map { "occupant-\($0)" } : nil,
                body: planned.body,
                timestamp: Self.start.addingTimeInterval(planned.time),
                status: planned.outgoing ? planned.status : nil,
                isRead: true,
                encryption: planned.undecryptable ? .omemoUndecryptable : .none,
                remoteId: remoteId(index),
                serverId: isGroup ? remoteId(index) : nil,
            )
            switch planned.reply {
            case .to(let target)?:
                let original = chat.messages[target]
                message.replyToId = remoteId(target)
                message.replyToSender = sender(of: original)
                message.replyFallback = "> " + String(original.body.prefix(60))
            case .missing(let quoted)?:
                message.replyToId = "\(prefix)-missing-\(index)"
                message.replyToSender = peer
                message.replyFallback = "> " + quoted
            case nil:
                break
            }
            if planned.edited { message.editedAt = message.timestamp.addingTimeInterval(90) }
            message.isRetracted = planned.retracted
            message.mentionsMe = planned.mentionsMe
            // A file message's body is the file's URL, which isn't previewed.
            if planned.media != nil { message.link = nil }
            let stored = try database.insert(message)
            guard let id = stored.id else { continue }

            try database.writer.write { db in
                if let media = planned.media {
                    try files.attachment(for: media, messageId: id, index: index, url: planned.body).insert(db)
                }
                // Every link gets a stored preview, an empty one if the plan
                // has none, so nothing is ever fetched from the network.
                if let link = stored.link {
                    try files.preview(planned.preview, url: link, index: index).save(db)
                }
                for reaction in planned.reactions {
                    let isMine = reaction.reactor == nil
                    try Reaction(
                        messageId: id,
                        sender: isMine ? account : peer,
                        nick: isGroup ? (reaction.reactor ?? Self.nickname) : "",
                        emoji: reaction.emoji,
                        occupantId: isGroup ? "occupant-\(reaction.reactor ?? Self.nickname)" : nil,
                        pendingId: isMine && reaction.isPending ? "fz-pending-\(prefix)-\(index)" : nil,
                    ).insert(db)
                }
            }
        }
    }
}

// MARK: The plan

/// Everything the two chats of one seed hold, before it's written anywhere.
struct FuzzPlan: Equatable {
    struct Chat: Equatable {
        /// The chat's link preview setting: nil asks before showing others' links.
        var previewsAllowed: Bool?
        var messages: [FuzzMessage]
    }

    var seed: UInt64
    var chat: Chat
    var group: Chat

    /// The 1:1 chat is usually 20 to 300 messages; one seed in six is past
    /// the 500 the conversation opens with, so scrolling up loads older ones.
    static let longChatRange = 520...680
    static let chatRange = 20...300
    static let groupRange = 15...150

    init(seed: UInt64) {
        self.seed = seed
        var random = FuzzRandom(seed: seed)
        let chatCount = random.chance(1, in: 6) ? random.int(in: Self.longChatRange) : random.int(in: Self.chatRange)
        let chatPreviews: Bool? = random.chance(1, in: 3) ? true : nil
        chat = Chat(previewsAllowed: chatPreviews, messages: FuzzPlanner(isGroup: false, count: chatCount, seed: seed, random: random.split()).messages)
        let groupCount = random.int(in: Self.groupRange)
        let groupPreviews: Bool? = random.chance(2, in: 3) ? true : nil
        group = Chat(previewsAllowed: groupPreviews, messages: FuzzPlanner(isGroup: true, count: groupCount, seed: seed, random: random.split()).messages)
    }
}

struct FuzzMessage: Equatable {
    enum Kind: String, CaseIterable {
        case short, medium, tallEmail, styled, emojiOnly, action, location
        case linkPage, linkPageImage, linkImage, linkNone
        case photo, video, gif, file, contact
    }

    enum Reply: Equatable {
        /// A reply to the message at that index.
        case to(Int)
        /// A reply to a message that isn't stored, with the words it quoted.
        case missing(String)
    }

    struct Reaction: Equatable {
        var emoji: String
        /// Who reacted: nil for us, else the peer (1:1) or an occupant's nickname.
        var reactor: String?
        /// Ours, not acknowledged by the server yet.
        var isPending = false
    }

    var kind: Kind
    var outgoing: Bool
    /// In the group, who sent it; ours carry our nickname.
    var nick: String?
    var body: String
    var media: FuzzMedia?
    var preview: FuzzPreview?
    var reply: Reply?
    var reactions: [Reaction] = []
    var status: Message.Status?
    var edited = false
    var retracted = false
    var undecryptable = false
    var mentionsMe = false
    /// Seconds after the fixture's start.
    var time: TimeInterval
}

struct FuzzMedia: Equatable {
    enum Kind: String { case photo, video, gif, file, contact }
    var kind: Kind
    var name: String
    var mimeType: String
    /// The picture's pixel size, for photos, videos and GIFs.
    var width: Int?
    var height: Int?
    var state: Attachment.State
    /// Distinguishes the pictures drawn for different messages.
    var hue: Double
}

struct FuzzPreview: Equatable {
    var kind: LinkPreview.Kind
    var title: String?
    var summary: String?
    var siteName: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var hue: Double
}

/// Picks one chat's messages. Runs of the same sender, gaps that start new
/// groups and days, and every kind of content, each at its own rate.
private struct FuzzPlanner {
    let isGroup: Bool
    let count: Int
    let seed: UInt64
    var random: FuzzRandom
    private(set) var messages: [FuzzMessage] = []

    init(isGroup: Bool, count: Int, seed: UInt64, random: FuzzRandom) {
        self.isGroup = isGroup
        self.count = count
        self.seed = seed
        self.random = random
        build()
    }

    private static let weights: [(FuzzMessage.Kind, Int)] = [
        (.short, 22), (.medium, 12), (.tallEmail, 6), (.styled, 5), (.emojiOnly, 5), (.action, 2), (.location, 3),
        (.linkPage, 6), (.linkPageImage, 6), (.linkImage, 3), (.linkNone, 2),
        (.photo, 10), (.video, 5), (.gif, 3), (.file, 3), (.contact, 1),
    ]
    private static let textKinds: Set<FuzzMessage.Kind> = [.short, .medium, .tallEmail, .styled, .emojiOnly, .action]
    /// What the newest message can be: text, so a test can find it by its words.
    private static let newestKinds: [FuzzMessage.Kind] = [.short, .medium, .tallEmail, .styled, .linkPage, .linkPageImage]
    private static let emoji = ["👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "🎉", "🐦", "🪺"]
    /// Picture shapes: portrait, landscape, square, very tall, very wide, and phone video.
    private static let shapes: [(Int, Int)] = [(240, 320), (320, 240), (280, 280), (96, 288), (288, 96), (144, 256), (256, 144), (320, 64)]
    private static let videoShapes: [(Int, Int)] = [(128, 160), (160, 128), (160, 160), (96, 288), (288, 96), (144, 256), (256, 144)]

    private mutating func build() {
        var time: TimeInterval = 0
        var outgoing = random.chance(1, in: 2)
        var nick = Self.pickNick(&random)
        for index in 0..<count {
            let isNewest = index == count - 1
            // Runs: the same sender again more often than not.
            if !random.chance(55, in: 100) {
                if isGroup {
                    // Ours a quarter of the time, else someone else's.
                    outgoing = random.chance(1, in: 4)
                    if !outgoing { nick = Self.pickNick(&random) }
                } else {
                    outgoing.toggle()
                }
            }
            time += gap()
            let kind = isNewest ? random.pick(Self.newestKinds) : random.weighted(Self.weights)
            var message = make(kind, outgoing: outgoing, index: index)
            message.time = time
            if isGroup { message.nick = outgoing ? FuzzFixture.nickname : nick }
            if message.outgoing { message.status = outgoingStatus() }
            decorate(&message, index: index, isNewest: isNewest)
            if isNewest {
                let marker = isGroup ? FuzzFixture.groupNewestMarker(seed: seed) : FuzzFixture.newestMarker(seed: seed)
                // A long body is shown cut short, so the marker of those that can
                // be long comes first, where a test finds it.
                if message.kind == .tallEmail || message.kind == .styled {
                    message.body = marker + "\n" + message.body
                } else {
                    message.body += " " + marker
                }
            }
            messages.append(message)
        }
    }

    private static func pickNick(_ random: inout FuzzRandom) -> String {
        random.pick(FuzzFixture.groupNicks)
    }

    /// Mostly minutes, so messages group; sometimes hours; now and then days,
    /// for day headers.
    private mutating func gap() -> TimeInterval {
        switch random.int(in: 0...99) {
        case 0..<70: TimeInterval(random.int(in: 20...240))
        case 70..<95: TimeInterval(random.int(in: 5...90) * 60)
        default: TimeInterval(random.int(in: 1...3) * 86_400 + random.int(in: 0...3600))
        }
    }

    private mutating func outgoingStatus() -> Message.Status {
        switch random.int(in: 0...99) {
        case 0..<80: .displayed
        case 80..<86: .delivered
        case 86..<92: .sent
        case 92..<96: .pending
        default: .failed
        }
    }

    private mutating func make(_ kind: FuzzMessage.Kind, outgoing: Bool, index: Int) -> FuzzMessage {
        var message = FuzzMessage(kind: kind, outgoing: outgoing, body: "", time: 0)
        switch kind {
        case .short:
            message.body = words(random.int(in: 1...8)).capitalizedFirst
        case .medium:
            message.body = words(random.int(in: 15...60)).capitalizedFirst + "."
        case .tallEmail:
            message.body = tallEmail(index: index)
        case .styled:
            var lines = ["> " + words(random.int(in: 4...14))]
            if random.chance(1, in: 2) { lines.append(">> " + words(random.int(in: 3...10))) }
            if random.chance(1, in: 3) { lines.append("> " + words(random.int(in: 3...8))) }
            lines.append("\(words(random.int(in: 2...6))) *\(words(1))* _\(words(2))_ `\(token(random.int(in: 4...12)))` \(words(random.int(in: 1...5)))")
            message.body = lines.joined(separator: "\n")
        case .emojiOnly:
            message.body = (0..<random.int(in: 1...6)).map { _ in random.pick(Self.emoji) }.joined()
        case .action:
            message.body = "/me " + words(random.int(in: 2...8))
        case .location:
            let latitude = Double(random.int(in: -60_000...60_000)) / 1000
            let longitude = Double(random.int(in: -170_000...170_000)) / 1000
            message.body = String(format: "geo:%.4f,%.4f", latitude, longitude)
        case .linkPage, .linkPageImage, .linkNone:
            let url = link()
            message.body = random.chance(1, in: 3) ? url : "\(words(random.int(in: 1...12)).capitalizedFirst) \(url) \(words(random.int(in: 0...10)))"
            message.body = message.body.trimmingCharacters(in: .whitespaces)
            message.preview = preview(kind == .linkNone ? .none : .page, image: kind == .linkPageImage)
        case .linkImage:
            message.body = "https://images.example.org/\(token(random.int(in: 8...30))).png"
            message.preview = preview(.image, image: true)
        case .photo, .video, .gif, .file, .contact:
            let media = self.media(kind, index: index)
            message.media = media
            message.body = "https://upload.example.com/\(token(16))/\(media.name)"
        }
        return message
    }

    /// Replies, reactions, edits and the rest, each at its own rate.
    private mutating func decorate(_ message: inout FuzzMessage, index: Int, isNewest: Bool) {
        let isText = Self.textKinds.contains(message.kind)
        if isText, index > 0, random.chance(1, in: 9) {
            if random.chance(1, in: 6) {
                message.reply = .missing(words(random.int(in: 3...12)))
            } else {
                message.reply = .to(random.int(in: max(0, index - 40)...(index - 1)))
            }
        }
        if random.chance(3, in: 20) {
            message.reactions = reactions()
        }
        if isText, random.chance(1, in: 20) { message.edited = true }
        if isGroup, !message.outgoing, isText, random.chance(1, in: 10) {
            message.mentionsMe = true
            message.body = "@\(FuzzFixture.nickname) " + message.body
        }
        guard !isNewest else { return }
        if random.chance(1, in: 33) {
            message.retracted = true
            message.reactions = []
        } else if !message.outgoing, isText, message.reply == nil, random.chance(1, in: 33) {
            message.undecryptable = true
            message.body = "I sent you an OMEMO encrypted message but your client doesn't seem to support that."
        }
    }

    private mutating func reactions() -> [FuzzMessage.Reaction] {
        var emoji = Self.emoji
        // Us, then the peer in a 1:1 chat, or the group's other occupants.
        let reactors: [String?] = [nil] + (isGroup ? FuzzFixture.groupNicks : ["peer"])
        var result: [FuzzMessage.Reaction] = []
        for _ in 0..<random.int(in: 1...4) {
            let chosen = emoji.remove(at: random.int(in: 0...(emoji.count - 1)))
            var picked: [String?] = []
            for _ in 0..<random.int(in: 1...(isGroup ? 3 : 2)) {
                let reactor = random.pick(reactors)
                if !picked.contains(reactor) { picked.append(reactor) }
            }
            for reactor in picked {
                result.append(.init(emoji: chosen, reactor: reactor, isPending: reactor == nil && random.chance(1, in: 3)))
            }
        }
        return result
    }

    private mutating func media(_ kind: FuzzMessage.Kind, index: Int) -> FuzzMedia {
        let state: Attachment.State = switch random.int(in: 0...99) {
        case 0..<80: .ready
        case 80..<95: .remote
        default: .downloadFailed
        }
        let hue = Double(random.int(in: 0...359)) / 360
        switch kind {
        case .photo:
            let (width, height) = random.pick(Self.shapes)
            return FuzzMedia(kind: .photo, name: "IMG_\(1000 + index).png", mimeType: "image/png", width: width, height: height, state: state, hue: hue)
        case .video:
            let (width, height) = random.pick(Self.videoShapes)
            return FuzzMedia(kind: .video, name: "MOV_\(1000 + index).mov", mimeType: "video/quicktime", width: width, height: height, state: state, hue: hue)
        case .gif:
            let (width, height) = random.pick(Self.shapes)
            return FuzzMedia(kind: .gif, name: "GIF_\(1000 + index).gif", mimeType: "image/gif", width: width / 2, height: height / 2, state: state, hue: hue)
        case .contact:
            let name = random.pick(FuzzFixture.groupNicks) + " " + random.pick(["Nest", "Branch", "Feather", "Twig"])
            return FuzzMedia(kind: .contact, name: "\(name).vcf", mimeType: "text/vcard", state: state, hue: hue)
        default:
            let ext = random.pick(["pdf", "zip", "txt", "key"])
            let base = random.chance(1, in: 4) ? "a-very-long-file-name-\(token(40))" : words(random.int(in: 1...3)).replacingOccurrences(of: " ", with: "-")
            let mime = ["pdf": "application/pdf", "zip": "application/zip", "txt": "text/plain", "key": "application/octet-stream"][ext]!
            return FuzzMedia(kind: .file, name: "\(base).\(ext)", mimeType: mime, state: state, hue: hue)
        }
    }

    private mutating func preview(_ kind: LinkPreview.Kind, image: Bool) -> FuzzPreview {
        let shape = random.pick(Self.shapes)
        let hue = Double(random.int(in: 0...359)) / 360
        if kind == .none { return FuzzPreview(kind: .none, hue: hue) }
        return FuzzPreview(
            kind: kind,
            title: kind == .page ? words(random.int(in: 2...14)).capitalizedFirst : nil,
            summary: kind == .page && random.chance(3, in: 4) ? words(random.int(in: 6...45)).capitalizedFirst + "." : nil,
            siteName: kind == .page && random.chance(2, in: 3) ? random.pick(["Example", "The Nest Times", "Birdwatch", "example.org"]) : nil,
            imageWidth: image ? shape.0 : nil,
            imageHeight: image ? shape.1 : nil,
            hue: hue,
        )
    }

    private mutating func link() -> String {
        let host = random.pick(["example.com", "www.example.org", "news.example.net", "a.very.long.subdomain.example.com"])
        // Some links are long and unbroken, which wraps by character.
        let path = random.chance(1, in: 4) ? token(random.int(in: 80...400)) : (0..<random.int(in: 1...4)).map { _ in token(random.int(in: 3...12)) }.joined(separator: "/")
        return "https://\(host)/\(path)"
    }

    private mutating func tallEmail(index: Int) -> String {
        let lines = random.int(in: 20...80)
        var parts = ["Subject: [Nestauth] Notice \(token(6))", ""]
        for line in 0..<lines {
            if random.chance(1, in: 10) {
                parts.append("https://auth.example.com/\(token(8))?token=\(token(random.int(in: 100...600)))")
            } else {
                parts.append(words(random.int(in: 6...20)))
            }
            if line % 4 == 3 { parts.append("") }
        }
        parts.append("End of notice \(index).")
        return parts.joined(separator: "\n")
    }

    private static let vocabulary = "the quick brown fox jumps over a lazy dog while we talk about nests twigs birds songs morning coffee trains and long afternoons by the river".split(separator: " ").map(String.init)

    private mutating func words(_ count: Int) -> String {
        (0..<count).map { _ in random.pick(Self.vocabulary) }.joined(separator: " ")
    }

    private mutating func token(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in random.pick(alphabet) })
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The same numbers on every run, on every device (SplitMix64).
struct FuzzRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A generator of its own, so one chat's length doesn't shift the next.
    mutating func split() -> FuzzRandom { FuzzRandom(seed: next()) }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ count: Int, in total: Int) -> Bool { int(in: 0...(total - 1)) < count }

    mutating func pick<T>(_ items: [T]) -> T { items[int(in: 0...(items.count - 1))] }

    mutating func weighted<T>(_ items: [(T, Int)]) -> T {
        var roll = int(in: 0...(items.reduce(0) { $0 + $1.1 } - 1))
        for (item, weight) in items {
            if roll < weight { return item }
            roll -= weight
        }
        return items[items.count - 1].0
    }
}

// MARK: Files

/// Writes the files a plan's attachments and previews point to: small real
/// pictures, a real video for each shape, a real GIF, and filler for other
/// files. Videos and GIFs of the same shape share a file, as making them is
/// the slow part.
private final class FuzzFiles {
    let attachments: URL
    let previews: URL
    let seed: UInt64
    private var shared: [String: String] = [:]

    init(attachments: URL, previews: URL, seed: UInt64) {
        self.attachments = attachments
        self.previews = previews
        self.seed = seed
        try? FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    }

    func attachment(for media: FuzzMedia, messageId: Int64, index: Int, url: String) throws -> Attachment {
        var localFile: String?
        var size: Int64 = 0
        if media.state == .ready {
            let file = try write(media, index: index)
            localFile = file
            size = (try? FileManager.default.attributesOfItem(atPath: attachments.appending(path: file).path)[.size] as? Int64) ?? 0
        } else {
            size = Int64(20_000 + index * 37)
        }
        return Attachment(
            messageId: messageId, url: url, name: media.name, mimeType: media.mimeType, size: size,
            width: media.width.map(Double.init), height: media.height.map(Double.init),
            localFile: localFile, state: media.state,
        )
    }

    func preview(_ planned: FuzzPreview?, url: String, index: Int) throws -> LinkPreview {
        guard let planned, planned.kind != .none else {
            return LinkPreview(url: url, kind: .none, fetchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        }
        var imageFile: String?
        if let width = planned.imageWidth, let height = planned.imageHeight {
            let name = "fz-\(seed)-p\(index).png"
            try FuzzFixture.png(width: width, height: height, hue: planned.hue).write(to: previews.appending(path: name), options: .atomic)
            imageFile = name
        }
        return LinkPreview(
            url: url, kind: planned.kind, title: planned.title, summary: planned.summary, siteName: planned.siteName,
            imageFile: imageFile, imageWidth: planned.imageWidth.map(Double.init), imageHeight: planned.imageHeight.map(Double.init),
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
        )
    }

    private func write(_ media: FuzzMedia, index: Int) throws -> String {
        switch media.kind {
        case .photo:
            let name = "fz-\(seed)-\(index).png"
            try FuzzFixture.png(width: media.width ?? 100, height: media.height ?? 100, hue: media.hue).write(to: attachments.appending(path: name), options: .atomic)
            return name
        case .video:
            let (width, height) = (media.width ?? 160, media.height ?? 120)
            return try sharedFile("video-\(width)x\(height)", ext: "mov") { try Self.writeVideo(to: $0, width: width, height: height, hue: media.hue) }
        case .gif:
            let (width, height) = (media.width ?? 100, media.height ?? 100)
            return try sharedFile("gif-\(width)x\(height)", ext: "gif") { try Self.writeGif(to: $0, width: width, height: height, hue: media.hue) }
        case .contact:
            let name = "fz-\(seed)-\(index).vcf"
            let card = "BEGIN:VCARD\nVERSION:3.0\nFN:\((media.name as NSString).deletingPathExtension)\nEND:VCARD\n"
            try Data(card.utf8).write(to: attachments.appending(path: name), options: .atomic)
            return name
        case .file:
            let name = "fz-\(seed)-\(index).\((media.name as NSString).pathExtension)"
            try Data(repeating: UInt8(index % 251), count: 2048 + index * 13).write(to: attachments.appending(path: name), options: .atomic)
            return name
        }
    }

    private func sharedFile(_ key: String, ext: String, make: (URL) throws -> Void) throws -> String {
        if let file = shared[key] { return file }
        let name = "fz-\(seed)-\(key).\(ext)"
        try make(attachments.appending(path: name))
        shared[key] = name
        return name
    }

    /// A GIF of one frame: it goes through the same GIF handling and takes
    /// the same room, but doesn't play. A playing GIF keeps the app from ever
    /// going idle, and XCTest then waits a minute before every action.
    static func writeGif(to url: URL, width: Int, height: Int, hue: Double) throws {
        let frames = 1
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else { throw FuzzFileError.gif }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            let data = FuzzFixture.png(width: width, height: height, hue: (hue + Double(frame) * 0.2).truncatingRemainder(dividingBy: 1))
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FuzzFileError.gif }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FuzzFileError.gif }
    }

    /// A second of one colour, so the bubble has a real first frame to show.
    /// Blocks until written; `fill` runs off the main thread.
    static func writeVideo(to url: URL, width: Int, height: Int, hue: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FuzzFileError.video }
        writer.startSession(atSourceTime: .zero)
        let color = UIColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1)
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { throw FuzzFileError.video }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw FuzzFileError.video }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for row in 0..<height {
                    for column in 0..<width {
                        let offset = row * bytesPerRow + column * 4
                        pixels[offset] = UInt8(blue * 255)
                        pixels[offset + 1] = UInt8(green * 255)
                        pixels[offset + 2] = UInt8(red * 255)
                        pixels[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? FuzzFileError.video }
    }

    enum FuzzFileError: Error { case gif, video }
}

extension FuzzFixture {
    /// A plain picture: a tint with a darker disc, which shows its shape and
    /// orientation. The previews fixture draws its pictures with it too.
    static func png(width: Int, height: Int, hue: Double) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.2, y: size.height * 0.2, width: size.width * 0.6, height: size.height * 0.6))
        }
    }
}

#endif
