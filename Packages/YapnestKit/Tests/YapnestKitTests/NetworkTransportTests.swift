import Foundation
import Testing
@testable import YapnestKit

private func ip(_ text: String) -> IPAddress { IPAddress(literal: text)! }

/// The real connection, plain TCP to a local server. TLS stays covered by the
/// live tests, which need real certificates.
private func localConfiguration(_ server: LocalHTTPServer) -> NWFetchConnection.Configuration {
    .init(port: server.port, allowsLoopback: true, usesTLS: false)
}

struct NWFetchConnectionTests {
    @Test func productionDefaultsAreStrict() {
        let defaults = NWFetchConnection.Configuration()
        #expect(defaults.port == 443)
        #expect(!defaults.allowsLoopback)
        #expect(defaults.usesTLS)
    }

    @Test func connectsToTheGivenAddressAndSendsTheRequest() async throws {
        let server = try await LocalHTTPServer(replies: [.send([LocalHTTPServer.response(200, body: "hi")])])
        defer { server.stop() }
        let connection = NWFetchConnection(address: ip("127.0.0.1"), serverName: "site.example", configuration: localConfiguration(server))
        defer { connection.close() }

        try await connection.start()
        #expect(connection.remoteAddress() == ip("127.0.0.1"))
        try await connection.send(HTTP1.request(host: "site.example", target: "/a/b?q=1&r=%20x"))

        var received = Data()
        while let chunk = try await connection.receive() { received.append(chunk) }
        #expect(String(decoding: received, as: UTF8.self).hasSuffix("\r\n\r\nhi"))

        #expect(server.accepted == 1)
        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("GET /a/b?q=1&r=%20x HTTP/1.1\r\nHost: site.example\r\n"))
        #expect(request.contains("\r\nUser-Agent: \(HTTP1.userAgent)\r\n"))
        #expect(request.contains("\r\nConnection: close\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func receiveReturnsNilOnceTheServerCloses() async throws {
        let server = try await LocalHTTPServer(replies: [.closeWithoutAnswer])
        defer { server.stop() }
        let connection = NWFetchConnection(address: ip("127.0.0.1"), serverName: "site.example", configuration: localConfiguration(server))
        defer { connection.close() }
        try await connection.start()
        try await connection.send(HTTP1.request(host: "site.example", target: "/"))
        #expect(try await connection.receive() == nil)
    }

    @Test func closeEndsTheConnectionAndWakesAReader() async throws {
        let server = try await LocalHTTPServer(replies: [.silent])
        defer { server.stop() }
        let connection = NWFetchConnection(address: ip("127.0.0.1"), serverName: "site.example", configuration: localConfiguration(server))
        try await connection.start()
        try await connection.send(HTTP1.request(host: "site.example", target: "/"))

        let reading = Task { try await connection.receive() }
        try await Task.sleep(for: .milliseconds(100))
        connection.close()

        // Our own close is an error for the reader, never a clean end of stream.
        await #expect(throws: FetchError.self) { try await reading.value }
        #expect(await eventually { server.closedByClient == 1 })
    }

    @Test func failsWhenNothingListens() async throws {
        let server = try await LocalHTTPServer()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let connection = NWFetchConnection(address: ip("127.0.0.1"), serverName: "site.example",
                                           configuration: .init(port: port, allowsLoopback: true, usesTLS: false))
        defer { connection.close() }
        await #expect(throws: FetchError.self) { try await connection.start() }
    }

    @Test func loopbackIsOffLimitsUnlessAllowed() async throws {
        let server = try await LocalHTTPServer(replies: [.silent])
        defer { server.stop() }
        let connection = NWFetchConnection(address: ip("127.0.0.1"), serverName: "site.example",
                                           configuration: .init(port: server.port, allowsLoopback: false, usesTLS: false))
        defer { connection.close() }
        await #expect(throws: FetchError.self) { try await connection.start() }
        #expect(server.accepted == 0)
    }
}

/// Real sockets under the real `SafeFetcher`. Names resolve to made-up public
/// addresses, which the connection reports as where it went, while the bytes
/// really go to the local server.
final class LocalTransport: FetchTransport, @unchecked Sendable {
    var dns: [String: [IPAddress]] = [
        "site.example": [ip("93.184.216.34")],
        "cdn.example": [ip("151.101.1.1")],
    ]
    let configuration: NWFetchConnection.Configuration
    private(set) var connections: [NWFetchConnection] = []
    private let lock = NSLock()

    init(server: LocalHTTPServer) {
        configuration = localConfiguration(server)
    }

    func resolve(_ host: String, timeout: TimeInterval) async throws -> [IPAddress] {
        guard let answer = dns[host] else { throw FetchError.unreachable("NXDOMAIN") }
        return answer
    }

    func localPrefixes() throws -> [AddressPrefix] { [] }

    func makeConnection(to address: IPAddress, serverName: String) -> FetchConnection {
        let real = NWFetchConnection(address: ip("127.0.0.1"), serverName: serverName, configuration: configuration)
        lock.withLock { connections.append(real) }
        return Relabelled(real: real, address: address)
    }

    private final class Relabelled: FetchConnection, @unchecked Sendable {
        let real: NWFetchConnection
        let address: IPAddress
        init(real: NWFetchConnection, address: IPAddress) { self.real = real; self.address = address }
        func start() async throws { try await real.start() }
        func send(_ data: Data) async throws { try await real.send(data) }
        func receive() async throws -> Data? { try await real.receive() }
        func remoteAddress() -> IPAddress? { real.remoteAddress() == ip("127.0.0.1") ? address : nil }
        func close() { real.close() }
    }
}

struct SafeFetcherOverSocketsTests {
    static let limits = FetchLimits(maxBytes: 2000, maxHTMLBytes: 1000, stopAtEndOfHead: false)

    func fetch(_ server: LocalHTTPServer, _ url: String, limits: FetchLimits = limits,
               requestTimeout: TimeInterval = 5) async throws -> FetchedResource {
        let fetcher = SafeFetcher(transport: LocalTransport(server: server), requestTimeout: requestTimeout, totalTimeout: 10)
        return try await fetcher.fetch(URL(string: url)!, limits: limits)
    }

    @Test func readsAContentLengthResponse() async throws {
        let server = try await LocalHTTPServer(replies: [.send([
            LocalHTTPServer.response(200, ["Content-Type": "Text/HTML; Charset=ISO-8859-1", "X-Thing": "a"], body: "<p>caf\u{e9}</p>"),
        ])])
        defer { server.stop() }

        let result = try await fetch(server, "https://Site.example/page?x=1")
        #expect(result.status == 200)
        #expect(result.mimeType == "text/html")
        #expect(result.charset == "ISO-8859-1")
        #expect(result.headers["x-thing"] == "a")
        #expect(result.url == URL(string: "https://Site.example/page?x=1"))
        #expect(String(decoding: result.body, as: UTF8.self) == "<p>caf\u{e9}</p>")
        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("GET /page?x=1 HTTP/1.1\r\nHost: site.example\r\n"))
    }

    @Test func readsAChunkedResponseSplitAcrossPackets() async throws {
        let head = LocalHTTPServer.response(200, ["Content-Type": "text/plain", "Transfer-Encoding": "chunked"], length: false)
        let server = try await LocalHTTPServer(replies: [.send([
            head, Data("5\r\nhel".utf8), Data("lo\r\n7;ext=1\r\n, world".utf8), Data("\r\n0\r\nTrailer: x\r\n\r\n".utf8),
        ])])
        defer { server.stop() }
        let result = try await fetch(server, "https://site.example/")
        #expect(String(decoding: result.body, as: UTF8.self) == "hello, world")
    }

    @Test func readsABodyThatEndsWithTheConnection() async throws {
        let server = try await LocalHTTPServer(replies: [.send([
            LocalHTTPServer.response(200, ["Content-Type": "text/plain"], body: "until close", length: false),
        ])])
        defer { server.stop() }
        let result = try await fetch(server, "https://site.example/")
        #expect(String(decoding: result.body, as: UTF8.self) == "until close")
    }

    @Test func followsRedirectsOverNewConnectionsWithTheRightHost() async throws {
        let server = try await LocalHTTPServer(replies: [
            .send([LocalHTTPServer.response(302, ["Location": "/next?a=1"])]),
            .send([LocalHTTPServer.response(301, ["Location": "https://cdn.example/img.png"])]),
            .send([LocalHTTPServer.response(200, ["Content-Type": "image/png"], body: "png")]),
        ])
        defer { server.stop() }
        let result = try await fetch(server, "https://site.example/start")
        #expect(result.url == URL(string: "https://cdn.example/img.png"))
        #expect(result.mimeType == "image/png")
        #expect(server.accepted == 3)
        let requests = server.requests
        #expect(requests[0].hasPrefix("GET /start HTTP/1.1\r\nHost: site.example\r\n"))
        #expect(requests[1].hasPrefix("GET /next?a=1 HTTP/1.1\r\nHost: site.example\r\n"))
        #expect(requests[2].hasPrefix("GET /img.png HTTP/1.1\r\nHost: cdn.example\r\n"))
    }

    @Test func errorStatusesComeBackWithoutABody() async throws {
        let server = try await LocalHTTPServer(replies: [.send([LocalHTTPServer.response(404, body: "nope")])])
        defer { server.stop() }
        let result = try await fetch(server, "https://site.example/")
        #expect(result.status == 404)
        #expect(result.body.isEmpty)
    }

    @Test func refusesAnnouncedBodiesOverTheLimit() async throws {
        let server = try await LocalHTTPServer(replies: [.send([
            LocalHTTPServer.response(200, ["Content-Type": "image/png", "Content-Length": "999999"], length: false),
        ])])
        defer { server.stop() }
        await #expect(throws: FetchError.tooLarge) { try await fetch(server, "https://site.example/") }
    }

    @Test func cutsAnEndlessBodyAtTheLimitAndHangsUp() async throws {
        let head = LocalHTTPServer.response(200, ["Content-Type": "image/png"], length: false)
        let server = try await LocalHTTPServer(replies: [.endless(head: head, piece: Data(repeating: 0x78, count: 700))])
        defer { server.stop() }
        let result = try await fetch(server, "https://site.example/")
        #expect(result.body.count == Self.limits.maxBytes)
        #expect(await eventually { server.closedByClient == 1 })
    }

    @Test func htmlHasItsOwnLowerLimit() async throws {
        let head = LocalHTTPServer.response(200, ["Content-Type": "text/html"], length: false)
        let server = try await LocalHTTPServer(replies: [.endless(head: head, piece: Data(repeating: 0x78, count: 300))])
        defer { server.stop() }
        let result = try await fetch(server, "https://site.example/")
        #expect(result.body.count == Self.limits.maxHTMLBytes)
        #expect(await eventually { server.closedByClient == 1 })
    }

    @Test func stopsReadingAtTheEndOfHead() async throws {
        let head = LocalHTTPServer.response(200, ["Content-Type": "text/html"], length: false)
        let piece = Data("<head><title>T</title></head><body>more and more and more</body>".utf8)
        let server = try await LocalHTTPServer(replies: [.endless(head: head, piece: piece)])
        defer { server.stop() }
        let limits = FetchLimits(maxBytes: 100_000, maxHTMLBytes: 100_000, stopAtEndOfHead: true)
        let result = try await fetch(server, "https://site.example/", limits: limits)
        #expect(String(decoding: result.body, as: UTF8.self) == "<head><title>T</title></head>")
        #expect(await eventually { server.closedByClient == 1 })
    }

    @Test func aServerThatNeverAnswersTimesOutAndIsHungUpOn() async throws {
        let server = try await LocalHTTPServer(replies: [.silent])
        defer { server.stop() }
        await #expect(throws: FetchError.timedOut) { try await fetch(server, "https://site.example/", requestTimeout: 0.3) }
        #expect(await eventually { server.closedByClient == 1 })
    }

    @Test func aServerThatStallsMidBodyTimesOut() async throws {
        let server = try await LocalHTTPServer(replies: [.sendAndHold([
            LocalHTTPServer.response(200, ["Content-Type": "image/png", "Content-Length": "100"], length: false), Data("abc".utf8),
        ])])
        defer { server.stop() }
        await #expect(throws: FetchError.timedOut) { try await fetch(server, "https://site.example/", requestTimeout: 0.3) }
        #expect(await eventually { server.closedByClient == 1 })
    }

    @Test func aServerThatClosesBeforeAnsweringIsABadResponse() async throws {
        let server = try await LocalHTTPServer(replies: [.closeWithoutAnswer])
        defer { server.stop() }
        await #expect(throws: FetchError.badResponse) { try await fetch(server, "https://site.example/") }
    }

    @Test func aBodyCutShortByTheServerIsABadResponse() async throws {
        let server = try await LocalHTTPServer(replies: [.send([
            LocalHTTPServer.response(200, ["Content-Type": "image/png", "Content-Length": "100"], length: false), Data("abc".utf8),
        ])])
        defer { server.stop() }
        await #expect(throws: FetchError.badResponse) { try await fetch(server, "https://site.example/") }
    }

    @Test func cancellationHangsUp() async throws {
        let server = try await LocalHTTPServer(replies: [.silent])
        defer { server.stop() }
        let task = Task { try await fetch(server, "https://site.example/") }
        #expect(await eventually { server.requests.count == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { server.closedByClient == 1 })
    }
}

struct SystemResolverTests {
    @Test func resolvesLocalhost() async throws {
        let addresses = try await SystemTransport().resolve("localhost", timeout: 5)
        #expect(addresses.contains(ip("127.0.0.1")) || addresses.contains(ip("::1")))
        #expect(Set(addresses).count == addresses.count)
    }

    @Test func unknownNamesAreUnreachable() async {
        // The .invalid TLD never resolves.
        await #expect {
            try await SystemTransport().resolve("no-such-host.invalid", timeout: 10)
        } throws: { error in
            guard case FetchError.unreachable = error else { return false }
            return true
        }
    }
}
