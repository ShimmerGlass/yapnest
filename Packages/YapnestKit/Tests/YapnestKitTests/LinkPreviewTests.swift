import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

struct OpenGraphTests {
    let base = URL(string: "https://news.example.com/articles/42")!

    @Test func readsOpenGraphTags() {
        let html = """
        <html><head>
        <title>Fallback title</title>
        <meta property="og:title" content="Rocket &amp; booster land &#8212; again">
        <meta content='Second landing this month.' property='og:description' />
        <META PROPERTY="og:site_name" CONTENT="Example News">
        <meta property="og:image" content="/img/rocket.jpg">
        <meta property="og:image" content="/img/second.jpg">
        </head><body></body></html>
        """
        let graph = OpenGraph(html: html, base: base)
        #expect(graph.title == "Rocket & booster land — again")
        #expect(graph.description == "Second landing this month.")
        #expect(graph.siteName == "Example News")
        #expect(graph.image == URL(string: "https://news.example.com/img/rocket.jpg"))
    }

    @Test func fallsBackToTitleAndDescription() {
        let html = """
        <head><title>
          Plain   page &lt;3
        </title><meta name="description" content="Just a page"></head>
        """
        let graph = OpenGraph(html: html, base: base)
        #expect(graph.title == "Plain page <3")
        #expect(graph.description == "Just a page")
        #expect(graph.image == nil)
    }

    @Test func emptyWithoutMetadata() {
        #expect(OpenGraph(html: "<html><body>hi</body></html>", base: base).isEmpty)
    }

    @Test func attributeQuotingAndTagBoundaries() {
        let html = """
        <metadata name="og:title" content="not a meta tag">
        <meta name=og:title content=bare>
        <meta name = "og:description"
              content = "spaced &amp; split">
        <meta property="og:site_name" content="">
        <title data-x="1">First</title><title>Second</title>
        """
        let graph = OpenGraph(html: html, base: base)
        #expect(graph.title == "bare")
        #expect(graph.description == "spaced & split")
        #expect(graph.siteName == nil)
        #expect(OpenGraph(html: "<TITLE>Loud</TITLE>", base: base).title == "Loud")
    }

    @Test func onlyTheStartOfAPageIsRead() {
        let late = String(repeating: " ", count: OpenGraph.maxScanned) + "<meta property=\"og:title\" content=\"Late\">"
        #expect(OpenGraph(html: late, base: base).isEmpty)
    }

    // A page can be a megabyte with no `</head>`. The old regexes took minutes
    // to hours on these, so a loose bound is enough to tell them apart.
    @Test(arguments: ["longName", "unclosedMeta", "unclosedTitle", "unclosedQuote", "bareValues"])
    func craftedPagesAreParsedInLinearTime(kind: String) {
        let size = 1 << 20
        let html = switch kind {
        case "longName": "<meta " + String(repeating: "a", count: size)
        case "unclosedMeta": String(repeating: "<meta ", count: size / 6)
        case "unclosedTitle": String(repeating: "<title>", count: size / 7)
        case "unclosedQuote": String(repeating: "<meta a=\"", count: size / 9)
        default: String(repeating: "<meta a=b ", count: size / 10)
        }
        let started = ContinuousClock.now
        _ = OpenGraph(html: html, base: base)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

struct LinkDetectorTests {
    @Test func previewsFirstWebLinkOnlyOverHTTPS() {
        #expect(LinkDetector.previewLink(in: "mail bob@example.org or see https://a.example/x and https://b.example") == URL(string: "https://a.example/x"))
        // The first web link is plain HTTP: no preview rather than a later one.
        #expect(LinkDetector.previewLink(in: "http://a.example then https://b.example") == nil)
        #expect(LinkDetector.previewLink(in: "no links here") == nil)
    }

    @Test func findsTappableLinks() {
        let links = LinkDetector.links(in: "www.apple.com, bob@example.org, ftp://files.example")
        #expect(links.map(\.url.scheme) == ["http", "mailto"])
    }

    @Test func xmppLinksAreTappable() {
        let text = "join xmpp:room@conference.example.org?join or xmpp:bob@example.org?roster;preauth=abc now"
        let links = LinkDetector.links(in: text)
        #expect(links.map(\.url.scheme) == ["xmpp", "xmpp"])
        #expect(links.compactMap { XMPPURI($0.url)?.action } == [.join, .addContact(name: nil, preauth: "abc")])
    }

    @Test func geoLinksAmongTextOpenTheMap() {
        let text = "meet me at geo:12.5,-3.25 later"
        let links = LinkDetector.links(in: text)
        #expect(links.count == 1)
        #expect((text as NSString).substring(with: links[0].range) == "geo:12.5,-3.25")
        #expect(links[0].url == GeoLocation(latitude: 12.5, longitude: -3.25).mapsURL)
    }

    @Test func geoLinksLeaveOutTrailingPunctuationAndSkipInvalidOnes() {
        let text = "see https://a.example/geo:1,2 or geo:91,0 or GEO:1,2;u=30, then geo:3,4."
        let links = LinkDetector.links(in: text)
        #expect(links.map { (text as NSString).substring(with: $0.range) } == ["https://a.example/geo:1,2", "GEO:1,2;u=30", "geo:3,4"])
        #expect(links.map(\.url.host) == ["a.example", "maps.apple.com", "maps.apple.com"])
    }
}

/// Serves canned responses by URL, as the fetcher would after its checks.
final class StubFetcher: LinkFetching, @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String]
        var body: Data
    }

    private let lock = NSLock()
    private var responses: [URL: Response] = [:]
    private var refused: Set<URL> = []
    private var log: [URL] = []
    var requested: [URL] { lock.withLock { log } }

    func serve(_ url: String, _ response: Response) {
        lock.withLock { responses[URL(string: url)!] = response }
    }

    /// Makes the fetcher refuse `url`, as it does for addresses it won't connect to.
    func refuse(_ url: String) {
        lock.withLock { _ = refused.insert(URL(string: url)!) }
    }

    func fetch(_ url: URL, limits: FetchLimits) async throws -> FetchedResource {
        let (stub, isRefused) = lock.withLock { () -> (Response?, Bool) in
            log.append(url)
            return (responses[url], refused.contains(url))
        }
        if isRefused { throw FetchError.refused("test") }
        guard let stub else { throw FetchError.unreachable("no stub") }
        if url.scheme != "https" { throw FetchError.refused("not https") }
        let type = HTTP1.parseContentType(stub.headers["Content-Type"])
        return FetchedResource(status: stub.status, headers: [:], mimeType: type.mimeType, charset: type.charset, url: url, body: stub.body)
    }
}

struct LinkPreviewerTests {
    let db: AppDatabase
    let previewer: LinkPreviewer
    let stub = StubFetcher()

    init() throws {
        db = try AppDatabase.inMemory()
        previewer = LinkPreviewer(
            database: db,
            directory: FileManager.default.temporaryDirectory.appending(path: "yapnest-previews-\(UUID().uuidString)"),
            fetcher: stub,
        )
    }

    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func pageWithImage() async throws {
        stub.serve("https://page.test/post", .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("""
        <html><head><meta property="og:title" content="A post"><meta property="og:image" content="https://page.test/cover.jpg"></head>
        <body>\(String(repeating: "x", count: 10_000))</body></html>
        """.utf8)))
        stub.serve("https://page.test/cover.jpg", .init(headers: ["Content-Type": "image/jpeg"], body: Self.jpeg(width: 1200, height: 630)))

        let preview = try await previewer.fetch(URL(string: "https://page.test/post")!)
        #expect(preview.kind == .page)
        #expect(preview.title == "A post")
        #expect(preview.siteName == "page.test")
        #expect(preview.imageSize == CGSize(width: 1200, height: 630))
        let file = try #require(previewer.imageURL(for: preview))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func imageLinkIsScaledDown() async throws {
        stub.serve("https://img.test/big.jpg", .init(headers: ["Content-Type": "image/jpeg"], body: Self.jpeg(width: 3200, height: 1600)))
        let preview = try await previewer.fetch(URL(string: "https://img.test/big.jpg")!)
        #expect(preview.kind == .image)
        #expect(preview.imageSize == CGSize(width: 1600, height: 800))
    }

    @Test func nothingToShow() async throws {
        stub.serve("https://none.test/missing", .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("<title>Not found</title>".utf8)))
        stub.serve("https://none.test/file.zip", .init(headers: ["Content-Type": "application/zip"], body: Data([1, 2, 3])))
        stub.serve("https://none.test/broken.png", .init(headers: ["Content-Type": "image/png"], body: Data("not a png".utf8)))
        for url in ["https://none.test/missing", "https://none.test/file.zip", "https://none.test/broken.png", "http://none.test/plain"] {
            #expect(try await previewer.fetch(URL(string: url)!).kind == .none, "\(url)")
        }
    }

    @Test func offlineIsRetried() async throws {
        await #expect(throws: FetchError.self) { try await previewer.fetch(URL(string: "https://unreachable.test/")!) }
    }

    @Test func refusedLinkHasNothingToShow() async throws {
        let refusing = LinkPreviewer(database: db, directory: previewer.directory, fetcher: RefusingFetcher())
        #expect(try await refusing.fetch(URL(string: "https://192.168.1.1/")!).kind == .none)
    }

    @Test func refusedImageKeepsThePage() async throws {
        stub.serve("https://page.test/post", .init(headers: ["Content-Type": "text/html"], body: Data("""
        <head><meta property="og:title" content="A post"><meta property="og:image" content="https://10.0.0.1/x.jpg"></head>
        """.utf8)))
        stub.refuse("https://10.0.0.1/x.jpg")
        let preview = try await previewer.fetch(URL(string: "https://page.test/post")!)
        #expect(preview.kind == .page)
        #expect(preview.imageFile == nil)
    }

    @Test func storedPreviewJoinsConversationItems() async throws {
        let me = JID("me@example.org")!, alice = JID("alice@example.org")!
        let conversation = try db.conversation(with: alice)
        let message = try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "look https://page.test/post!"))
        #expect(message.link == "https://page.test/post")

        try await db.writer.write { db in try LinkPreview(url: "https://page.test/post", kind: .page, title: "A post").save(db) }
        let items = try await db.reader.read { db in try AppDatabase.conversationItems(db, peer: alice, me: me) }
        #expect(items.first?.preview?.title == "A post")
    }

    @Test func migrationFindsLinksInExistingMessages() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4-message-trust")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('a@example.org', 'chat', 0)")
            for body in ["see https://old.example/page", "no link", "http://plain.example"] {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption)
                    VALUES (1, 'incoming', 'a@example.org', ?, 0, 'received', 0, 'omemo')
                    """, arguments: [body])
            }
        }
        try AppDatabase.migrator.migrate(queue)
        let links = try queue.read { db in try String?.fetchAll(db, sql: "SELECT link FROM message ORDER BY id") }
        #expect(links == ["https://old.example/page", nil, nil])
    }

    @Test func linkPreviewChoiceIsPerConversation() throws {
        let alice = JID("alice@example.org")!, bob = JID("bob@example.org")!
        try db.setLinkPreviews(true, peer: alice)
        let choices = try db.reader.read { db in
            try [alice, bob].map { peer in try Conversation.filter(sql: "peer = ?", arguments: [peer]).fetchOne(db)?.linkPreviews }
        }
        #expect(choices == [true, nil])
    }
}

struct RefusingFetcher: LinkFetching {
    func fetch(_ url: URL, limits: FetchLimits) async throws -> FetchedResource { throw FetchError.refused("test") }
}

/// Holds every fetch until `release()`, to look at what happens while one is in flight.
final class GatedFetcher: LinkFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var count = 0
    var fetches: Int { lock.withLock { count } }

    func release() { lock.withLock { open = true } }

    func fetch(_ url: URL, limits: FetchLimits) async throws -> FetchedResource {
        lock.withLock { count += 1 }
        while !lock.withLock({ open }) { try await Task.sleep(for: .milliseconds(5)) }
        let body = Data("<head><meta property=\"og:title\" content=\"Gated\"></head>".utf8)
        return FetchedResource(status: 200, headers: [:], mimeType: "text/html", charset: nil, url: url, body: body)
    }
}

/// Polls `condition` for up to two seconds.
func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
    for _ in 0..<400 {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

struct LinkPreviewerDecodingTests {
    @Test func declaredCharsetIsHonoured() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(LinkPreviewer.decode(latin1, encodingName: "iso-8859-1") == "café")
        #expect(LinkPreviewer.decode(Data("café".utf8), encodingName: "utf-8") == "café")
    }

    @Test func unknownCharsetFallsBackToUTF8() {
        #expect(LinkPreviewer.decode(Data("café".utf8), encodingName: "no-such-charset") == "café")
        #expect(LinkPreviewer.decode(Data("café".utf8), encodingName: nil) == "café")
    }

    @Test(arguments: [[0xC3], [0xE2, 0x82], [0xF0, 0x9F, 0x98]] as [[UInt8]])
    func pageCutMidCharacterKeepsItsText(tail: [UInt8]) {
        let cut = Data("<title>caf".utf8) + Data(tail)
        #expect(LinkPreviewer.decode(cut, encodingName: nil) == "<title>caf")
        #expect(LinkPreviewer.decode(cut, encodingName: "utf-8") == "<title>caf")
    }

    @Test func shortInvalidBodiesAreReplacedNotEmptied() {
        #expect(LinkPreviewer.decode(Data([0xFF, 0xFF, 0xFF]), encodingName: nil) == "\u{FFFD}\u{FFFD}\u{FFFD}")
        #expect(LinkPreviewer.decode(Data([0xFF]), encodingName: nil) == "\u{FFFD}")
        // Only a genuinely cut-off character is dropped, so a lone invalid byte at the end stays visible.
        #expect(LinkPreviewer.decode(Data("ab".utf8) + Data([0xFF, 0xFF]), encodingName: nil) == "ab\u{FFFD}\u{FFFD}")
        #expect(LinkPreviewer.decode(Data("é".utf8).prefix(1), encodingName: nil) == "")
        #expect(LinkPreviewer.decode(Data(), encodingName: nil) == "")
    }

    @Test func invalidBytesInTheMiddleAreReplacedNotLost() {
        let text = LinkPreviewer.decode(Data("start".utf8) + Data([0xFF]) + Data("end".utf8), encodingName: nil)
        #expect(text.hasPrefix("start") && text.hasSuffix("end"))
    }
}

struct LinkPreviewerImageTests {
    let db: AppDatabase
    let previewer: LinkPreviewer
    let stub = StubFetcher()

    init() throws {
        db = try AppDatabase.inMemory()
        previewer = LinkPreviewer(
            database: db,
            directory: FileManager.default.temporaryDirectory.appending(path: "yapnest-previews-\(UUID().uuidString)"),
            fetcher: stub,
        )
    }

    /// A PNG whose header claims `width` by `height`, with no pixel data:
    /// enough for the size checks that run before anything is decoded.
    static func pngHeader(width: UInt32, height: UInt32) -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let name = Array(type.utf8)
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in name + body {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * UInt32($0))) & 0xFF) } }
            return be(UInt32(body.count)) + name + body + be(~crc)
        }
        func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * UInt32($0))) & 0xFF) } }
        let header = be(width) + be(height) + [8, 2, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IEND", []))
    }

    static func png(width: Int, height: Int, alpha: Bool) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func preview(of body: Data, type: String = "image/png") async throws -> LinkPreview {
        stub.serve("https://img.test/a", .init(headers: ["Content-Type": type], body: body))
        return try await previewer.fetch(URL(string: "https://img.test/a")!)
    }

    @Test func imageOverThePixelLimitIsRefusedBeforeDecoding() async throws {
        // 10000 x 10000 is 100 million pixels, twice the limit.
        #expect(try await preview(of: Self.pngHeader(width: 10_000, height: 10_000)).kind == .none)
    }

    @Test func imageWithNoPixelsIsRefused() async throws {
        #expect(try await preview(of: Self.pngHeader(width: 0, height: 0)).kind == .none)
    }

    @Test func imageAtTheLimitIsAccepted() async throws {
        let result = try await preview(of: Self.png(width: 400, height: 300, alpha: false), type: "image/png")
        #expect(result.kind == .image)
    }

    @Test func transparentImageStaysPNG() async throws {
        let result = try await preview(of: Self.png(width: 40, height: 30, alpha: true))
        #expect(result.imageFile?.hasSuffix(".png") == true)
        let file = try #require(previewer.imageURL(for: result))
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }

    @Test func opaqueImageBecomesJPEG() async throws {
        let result = try await preview(of: Self.png(width: 40, height: 30, alpha: false))
        #expect(result.imageFile?.hasSuffix(".jpg") == true)
    }

    @Test func imageNamesDependOnTheLinkAlone() {
        #expect(LinkPreviewer.fileName(for: "https://a.test/x") == LinkPreviewer.fileName(for: "https://a.test/x"))
        #expect(LinkPreviewer.fileName(for: "https://a.test/x") != LinkPreviewer.fileName(for: "https://a.test/y"))
    }
}

struct LinkPreviewerFetchTests {
    let db: AppDatabase
    let directory = FileManager.default.temporaryDirectory.appending(path: "yapnest-previews-\(UUID().uuidString)")

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func stored(_ url: String) async throws -> LinkPreview? {
        try await db.reader.read { db in try LinkPreview.fetchOne(db, key: url) }
    }

    @Test(arguments: [500, 502, 503, 408, 429])
    func transientPageFailureThrowsSoItIsRetried(status: Int) async throws {
        let stub = StubFetcher()
        stub.serve("https://page.test/", .init(status: status, headers: ["Content-Type": "text/html"], body: Data("<title>Oops</title>".utf8)))
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        await #expect(throws: FetchError.self) { try await previewer.fetch(URL(string: "https://page.test/")!) }
    }

    @Test(arguments: [400, 401, 403, 404, 410, 451])
    func permanentPageFailureHasNothingToShow(status: Int) async throws {
        let stub = StubFetcher()
        stub.serve("https://page.test/", .init(status: status, headers: ["Content-Type": "text/html"], body: Data("<title>No</title>".utf8)))
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        #expect(try await previewer.fetch(URL(string: "https://page.test/")!).kind == .none)
    }

    @Test func transientImageFailureRetriesTheWholePreview() async throws {
        let stub = StubFetcher()
        stub.serve("https://page.test/", .init(headers: ["Content-Type": "text/html"], body: Data("""
        <head><meta property="og:title" content="A post"><meta property="og:image" content="https://page.test/c.jpg"></head>
        """.utf8)))
        stub.serve("https://page.test/c.jpg", .init(status: 503, headers: ["Content-Type": "text/html"], body: Data()))
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        await #expect(throws: FetchError.self) { try await previewer.fetch(URL(string: "https://page.test/")!) }
        // An image that doesn't exist is a different matter: the page stands.
        stub.serve("https://page.test/c.jpg", .init(status: 404, headers: ["Content-Type": "text/html"], body: Data()))
        let preview = try await previewer.fetch(URL(string: "https://page.test/")!)
        #expect(preview.kind == .page && preview.imageFile == nil)
    }

    @Test func imageTimingOutRetriesTheWholePreview() async throws {
        struct TimingOutImages: LinkFetching {
            func fetch(_ url: URL, limits: FetchLimits) async throws -> FetchedResource {
                if url.path == "/c.jpg" { throw FetchError.timedOut }
                let body = Data(#"<head><meta property="og:title" content="T"><meta property="og:image" content="https://page.test/c.jpg"></head>"#.utf8)
                return FetchedResource(status: 200, headers: [:], mimeType: "text/html", charset: nil, url: url, body: body)
            }
        }
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: TimingOutImages())
        await #expect(throws: FetchError.timedOut) { try await previewer.fetch(URL(string: "https://page.test/")!) }
    }

    @Test func transientFailureIsNotStoredAndTheNextAttemptSucceeds() async throws {
        let stub = StubFetcher()
        let url = "https://page.test/"
        stub.serve(url, .init(status: 503, headers: ["Content-Type": "text/html"], body: Data()))
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        previewer.fetchIfNeeded(URL(string: url)!)
        #expect(await eventually { stub.requested.count == 1 })

        stub.serve(url, .init(headers: ["Content-Type": "text/html"], body: Data(#"<head><meta property="og:title" content="Back"></head>"#.utf8)))
        // Asked again as the message shows again, until the earlier run is done.
        let found = await eventually {
            previewer.fetchIfNeeded(URL(string: url)!)
            return (try? await stored(url)) != nil
        }
        #expect(found)
        #expect(try await stored(url)?.title == "Back")
    }

    @Test func linkIsFetchedOnceWhileInFlight() async throws {
        let gate = GatedFetcher()
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: gate)
        let url = URL(string: "https://page.test/")!
        previewer.fetchIfNeeded(url)
        previewer.fetchIfNeeded(url)
        #expect(await eventually { gate.fetches >= 1 })
        previewer.fetchIfNeeded(url)
        gate.release()
        #expect(await eventually { (try? await stored(url.absoluteString)) != nil })
        #expect(gate.fetches == 1)
    }

    @Test func aPreviewThatCouldNotBeStoredIsNotFetchedAgainWhileTheAppRuns() async throws {
        try await db.writer.write {
            try $0.execute(sql: "CREATE TRIGGER failPreview BEFORE INSERT ON linkPreview BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let stub = StubFetcher()
        let url = URL(string: "https://page.test/")!
        stub.serve(url.absoluteString, .init(headers: ["Content-Type": "text/html"], body: Data(#"<head><meta property="og:title" content="T"></head>"#.utf8)))
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        previewer.fetchIfNeeded(url)
        #expect(await eventually { stub.requested.count == 1 })
        // Let the failed write finish and the in-flight mark clear.
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<3 { previewer.fetchIfNeeded(url) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(stub.requested.count == 1)
    }

    @Test func storedPreviewIsNotFetchedAgain() async throws {
        let stub = StubFetcher()
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        try await db.writer.write { db in try LinkPreview(url: "https://page.test/", kind: .none).save(db) }
        previewer.fetchIfNeeded(URL(string: "https://page.test/")!)
        try await Task.sleep(for: .milliseconds(150))
        #expect(stub.requested.isEmpty)
    }

    @Test func siteNameFromThePageOrElseTheHost() async throws {
        let stub = StubFetcher()
        let previewer = LinkPreviewer(database: db, directory: directory, fetcher: stub)
        stub.serve("https://named.test/a", .init(headers: ["Content-Type": "text/html"], body: Data("""
        <head><meta property="og:title" content="T"><meta property="og:site_name" content="The Named"></head>
        """.utf8)))
        stub.serve("https://unnamed.test/a", .init(headers: ["Content-Type": "text/html"], body: Data("""
        <head><meta property="og:title" content="T"></head>
        """.utf8)))
        #expect(try await previewer.fetch(URL(string: "https://named.test/a")!).siteName == "The Named")
        #expect(try await previewer.fetch(URL(string: "https://unnamed.test/a")!).siteName == "unnamed.test")
    }
}
