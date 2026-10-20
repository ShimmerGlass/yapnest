import Foundation
import Testing
@testable import YapnestKit

private func ip(_ text: String) -> IPAddress { IPAddress(literal: text)! }

struct AddressPolicyTests {
    func blocked(_ text: String, local: [String] = []) -> Bool {
        AddressPolicy.isBlocked(ip(text), localPrefixes: local.map(AddressPrefix.init))
    }

    @Test func blocksPrivateIPv4() {
        for address in [
            "0.0.0.0", "0.255.255.255", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.255", "127.0.0.1", "127.255.0.3",
            "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.0.2.5", "192.88.99.1", "192.168.1.1",
            "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9", "224.0.0.251", "239.255.255.250", "240.0.0.1",
            "255.255.255.255",
        ] {
            #expect(blocked(address), "\(address)")
        }
    }

    @Test func allowsPublicIPv4() {
        for address in ["1.1.1.1", "8.8.8.8", "9.255.255.255", "11.0.0.1", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1",
                        "192.167.255.255", "192.169.0.1", "198.17.255.255", "198.20.0.1", "223.255.255.255", "93.184.216.34"] {
            #expect(!blocked(address), "\(address)")
        }
    }

    @Test func blocksSpecialIPv6() {
        for address in ["::", "::1", "fe80::1", "febf::1", "fc00::1", "fd12:3456::1", "ff02::fb", "fec0::1", "2001:db8::1", "100::1",
                        "100::ffff:0:1", "2001::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2"] {
            #expect(blocked(address), "\(address)")
        }
    }

    @Test func allowsPublicIPv6() {
        for address in ["2606:4700:4700::1111", "2a00:1450:4001::200e", "2001:4860:4860::8888", "100:0:0:1::1", "fec0:ffff::1".replacingOccurrences(of: "fec0:ffff::1", with: "2620:fe::fe")] {
            #expect(!blocked(address), "\(address)")
        }
    }

    @Test func unwrapsEmbeddedIPv4() {
        // Mapped and compatible forms.
        #expect(blocked("::ffff:127.0.0.1"))
        #expect(blocked("::ffff:192.168.1.1"))
        #expect(!blocked("::ffff:8.8.8.8"))
        #expect(blocked("::10.0.0.1"))
        #expect(!blocked("::8.8.8.8"))
        // NAT64 stays reachable for public addresses, which IPv6-only networks need.
        #expect(!blocked("64:ff9b::808:808"))
        #expect(blocked("64:ff9b::7f00:1"))
        #expect(blocked("64:ff9b::c0a8:101"))
        // Blocked if either layout of the local-use prefix yields a private address.
        #expect(blocked("64:ff9b:1::808:808"))
        #expect(!blocked("64:ff9b:1:808:8:800:808:808"))
        #expect(blocked("64:ff9b:1::c0a8:101"))
        // The /48 layout: 192.168.1.1 sits in bytes 6, 7, 9 and 10.
        #expect(blocked("64:ff9b:1:c0a8:0001:0100::"))
        // 6to4.
        #expect(blocked("2002:7f00:1::1"))
        #expect(blocked("2002:c0a8:101::"))
        #expect(!blocked("2002:0808:0808::1"))
    }

    @Test func blocksTheDevicesOwnNetworks() {
        let local = ["203.0.113.0/24", "93.184.216.0/24", "2606:4700:1234:5678::/64", "10.8.0.2/32"]
        // Public addresses in a prefix the device is on.
        #expect(blocked("93.184.216.34", local: ["93.184.216.0/24"]))
        #expect(!blocked("93.184.217.34", local: ["93.184.216.0/24"]))
        #expect(blocked("2606:4700:1234:5678::99", local: local))
        #expect(!blocked("2606:4700:1234:5679::99", local: local))
        #expect(blocked("::ffff:93.184.216.34", local: local))
        #expect(blocked("64:ff9b::5db8:d822", local: local))
        // Prefix lengths that aren't whole bytes, and families don't mix.
        #expect(blocked("8.8.4.9", local: ["8.8.4.0/22"]))
        #expect(!blocked("8.8.8.1", local: ["8.8.4.0/22"]))
        #expect(!blocked("1.1.1.1", local: ["2606:4700::/32"]))
    }

    @Test func connectionEndpointMustMatch() {
        #expect(AddressPolicy.endpoint(ip("8.8.8.8"), matches: ip("8.8.8.8")))
        #expect(AddressPolicy.endpoint(ip("64:ff9b::808:808"), matches: ip("8.8.8.8")))
        #expect(AddressPolicy.endpoint(ip("::ffff:8.8.8.8"), matches: ip("8.8.8.8")))
        #expect(!AddressPolicy.endpoint(ip("8.8.4.4"), matches: ip("8.8.8.8")))
        #expect(!AddressPolicy.endpoint(ip("127.0.0.1"), matches: ip("8.8.8.8")))
        #expect(!AddressPolicy.endpoint(ip("2606:4700::1"), matches: ip("2606:4700::2")))
    }

    @Test func readsTheDevicesInterfaces() throws {
        let prefixes = try LocalInterfaces.prefixes()
        // Loopback is always up.
        #expect(prefixes.contains { $0.contains(ip("127.0.0.1")) })
        #expect(prefixes.contains { $0.contains(ip("::1")) })
    }
}

struct HostPolicyTests {
    @Test func acceptsPublicNames() {
        #expect(HostPolicy.classify("Example.COM.") == .name("example.com"))
        #expect(HostPolicy.classify("en.wikipedia.org") == .name("en.wikipedia.org"))
        #expect(HostPolicy.classify("my_host.example.net") == .name("my_host.example.net"))
        #expect(HostPolicy.classify("8.8.8.8") == .literal(ip("8.8.8.8")))
        #expect(HostPolicy.classify("[2606:4700::1111]") == .literal(ip("2606:4700::1111")))
        #expect(HostPolicy.classify("lanternfish.com") == .name("lanternfish.com"))
        #expect(HostPolicy.classify("notlocal.example") == .name("notlocal.example"))
    }

    @Test func refusesLocalNames() {
        for host in [
            "localhost", "LOCALHOST.", "foo.localhost", "printer", "nas.local", "NAS.Local.", "local", "router.lan", "lan",
            "x.home.arpa", "home.arpa", "db.internal", "wiki.intranet", "a.corp", "b.private",
        ] {
            #expect(HostPolicy.classify(host) == nil, "\(host)")
        }
    }

    @Test func refusesOddHosts() {
        for host in ["", ".", "a..b.com", ".example.com", "fe80::1%en0", "exa mple.com", "ex/ample.com", "bücher.example",
                     "127.1", "2130706433", "0x7f.0.0.1", "10.0.0.0x1", "fe80::zz"] {
            #expect(HostPolicy.classify(host) == nil, "\(host)")
        }
    }

    @Test func resolverGetsFullyQualifiedNames() {
        #expect(SystemTransport.fullyQualified("example.com") == "example.com.")
        #expect(SystemTransport.fullyQualified("example.com.") == "example.com.")
    }

    @Test func urlRules() throws {
        let ok = try FetchTarget(URL(string: "https://Example.com/a/b?q=1&r=%20x")!)
        #expect(ok.host == .name("example.com"))
        #expect(ok.requestTarget == "/a/b?q=1&r=%20x")
        #expect(try FetchTarget(URL(string: "https://example.com")!).requestTarget == "/")
        #expect(try FetchTarget(URL(string: "https://example.com:443/x#frag")!).requestTarget == "/x")
        #expect(try FetchTarget(URL(string: "https://example.com?x=1")!).requestTarget == "/?x=1")
        for bad in ["http://example.com/", "ftp://example.com/", "https://example.com:8443/", "https://example.com:80/",
                    "https://user@example.com/", "https://user:pw@example.com/", "https://printer.local/", "https://localhost/",
                    "file:///etc/passwd", "https:///x"] {
            #expect(throws: FetchError.self, "\(bad)") { try FetchTarget(URL(string: bad)!) }
        }
    }
}

struct HTTP1ParserTests {
    static let limits = FetchLimits(maxBytes: 1000, maxHTMLBytes: 500, stopAtEndOfHead: false)

    func parse(_ chunks: [String], limits: FetchLimits = limits, close: Bool = true) throws -> HTTP1ResponseParser {
        var parser = HTTP1ResponseParser(limits: limits)
        for chunk in chunks { try parser.receive(Data(chunk.utf8)) }
        if close { try parser.receiveEnd() }
        return parser
    }

    @Test func contentLength() throws {
        let parser = try parse(["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhel", "lo, ignored"], close: false)
        #expect(parser.isComplete)
        #expect(parser.head?.status == 200)
        #expect(parser.head?.headers["content-type"] == "text/plain")
        #expect(String(decoding: parser.body, as: UTF8.self) == "hello")
    }

    @Test func arrivesInTinyPieces() throws {
        let text = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
        var parser = HTTP1ResponseParser(limits: Self.limits)
        for byte in text.utf8 { try parser.receive(Data([byte])) }
        #expect(parser.isComplete)
        #expect(parser.body == Data("abc".utf8))
    }

    @Test func chunkedWithExtensionsAndTrailers() throws {
        let parser = try parse([
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5;name=value\r\nhello\r\n", "6\r\n world\r\n", "0\r\nX-Trailer: 1\r\nAnother: 2\r\n\r\n",
        ], close: false)
        #expect(parser.isComplete)
        #expect(String(decoding: parser.body, as: UTF8.self) == "hello world")
    }

    @Test func chunkedSplitAnywhere() throws {
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123456789\r\n0\r\n\r\n"
        var parser = HTTP1ResponseParser(limits: Self.limits)
        for byte in text.utf8 { try parser.receive(Data([byte])) }
        #expect(parser.isComplete)
        #expect(parser.body.count == 10)
    }

    @Test func badChunks() {
        for body in ["zz\r\nabc\r\n", "-1\r\n", "3\r\nabcXX", "123456789\r\n", "\r\n"] {
            #expect(throws: HTTP1ResponseParser.Failure.self, "\(body)") {
                _ = try parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", body], close: false)
            }
        }
    }

    @Test func readUntilClose() throws {
        let open = try parse(["HTTP/1.1 200 OK\r\n\r\nsome ", "bytes"], close: false)
        #expect(!open.isComplete)
        let closed = try parse(["HTTP/1.1 200 OK\r\n\r\nsome ", "bytes"])
        #expect(closed.isComplete)
        #expect(String(decoding: closed.body, as: UTF8.self) == "some bytes")
    }

    @Test func truncatedBodiesAreMalformed() {
        #expect(throws: HTTP1ResponseParser.Failure.malformed) { _ = try parse(["HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"]) }
        #expect(throws: HTTP1ResponseParser.Failure.malformed) { _ = try parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n"]) }
        #expect(throws: HTTP1ResponseParser.Failure.malformed) { _ = try parse(["HTTP/1.1 200"]) }
    }

    @Test func headersAreLowercasedAndJoined() throws {
        let parser = try parse(["HTTP/1.1 301 Moved\r\nLocation:  /next \r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\n\r\n"], close: false)
        #expect(parser.isComplete)
        #expect(parser.head?.headers["location"] == "/next")
        #expect(parser.head?.headers["set-cookie"] == "a=1, b=2")
        #expect(parser.body.isEmpty)
    }

    @Test func onlySuccessfulResponsesHaveBodies() throws {
        let parser = try parse(["HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\n\r\nnope"], close: false)
        #expect(parser.isComplete)
        #expect(parser.body.isEmpty)
    }

    @Test func skipsInterimResponses() throws {
        let parser = try parse(["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"], close: false)
        #expect(parser.head?.status == 200)
        #expect(parser.body == Data("ok".utf8))
    }

    @Test func refusesOversizeUpFront() {
        #expect(throws: HTTP1ResponseParser.Failure.tooLarge) {
            _ = try parse(["HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 1001\r\n\r\n"], close: false)
        }
    }

    @Test func cutsOffAtTheLimit() throws {
        let image = try parse(["HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n", String(repeating: "x", count: 900), String(repeating: "x", count: 900)], close: false)
        #expect(image.isComplete)
        #expect(image.body.count == 1000)
        // HTML has its own, lower limit, even when the length is announced.
        let html = try parse(["HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 900\r\n\r\n", String(repeating: "x", count: 900)], close: false)
        #expect(html.isComplete)
        #expect(html.body.count == 500)
    }

    @Test func stopsAfterEndOfHead() throws {
        let limits = FetchLimits(maxBytes: 1000, maxHTMLBytes: 1000, stopAtEndOfHead: true)
        // The marker is split across pieces and cased oddly.
        let parser = try parse(["HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<head><title>t</title></he", "AD><body>lots more", " body"], limits: limits, close: false)
        #expect(parser.isComplete)
        #expect(String(decoding: parser.body, as: UTF8.self) == "<head><title>t</title></heAD>")
        // Not for other types.
        let image = try parse(["HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n</head>more"], limits: limits, close: false)
        #expect(!image.isComplete)
        #expect(image.body.count == 11)
    }

    @Test func headerLimits() throws {
        #expect(throws: HTTP1ResponseParser.Failure.headTooLarge) {
            _ = try parse(["HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 40_000)], close: false)
        }
        #expect(throws: HTTP1ResponseParser.Failure.headTooLarge) {
            _ = try parse(["HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 33_000) + "\r\n\r\n"], close: false)
        }
        let many = (0..<101).map { "H\($0): v\r\n" }.joined()
        #expect(throws: HTTP1ResponseParser.Failure.tooManyHeaders) { _ = try parse(["HTTP/1.1 200 OK\r\n" + many + "\r\n"], close: false) }
        let hundred = (0..<100).map { "H\($0): v\r\n" }.joined()
        #expect(try parse(["HTTP/1.1 200 OK\r\n" + hundred + "\r\n"], close: false).head?.headers.count == 100)
    }

    @Test func malformedHeads() {
        for head in ["garbage\r\n\r\n", "HTTP/2 200 OK\r\n\r\n", "HTTP/1.1 20 OK\r\n\r\n", "HTTP/1.1 200 OK\r\nno colon\r\n\r\n",
                     "HTTP/1.1 200 OK\r\n folded\r\n\r\n", "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n"] {
            #expect(throws: HTTP1ResponseParser.Failure.self, "\(head)") { _ = try parse([head], close: false) }
        }
        for headers in ["Content-Length: abc", "Content-Length: -1", "Content-Length: 1, 2", "Transfer-Encoding: gzip", "Content-Encoding: gzip"] {
            #expect(throws: HTTP1ResponseParser.Failure.self, "\(headers)") { _ = try parse(["HTTP/1.1 200 OK\r\n\(headers)\r\n\r\nx"], close: false) }
        }
        // Repeated but equal lengths are fine.
        #expect(throws: Never.self) { _ = try parse(["HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx"], close: false) }
    }

    @Test func requestAndContentType() {
        let text = String(decoding: HTTP1.request(host: "example.com", target: "/a?b=1"), as: UTF8.self)
        #expect(text == "GET /a?b=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: WhatsApp/2\r\nAccept: text/html,image/*;q=0.9,*/*;q=0.5\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
        #expect(String(decoding: HTTP1.request(host: "2606:4700::1111", target: "/"), as: UTF8.self).contains("Host: [2606:4700::1111]\r\n"))
        let type = HTTP1.parseContentType("Text/HTML; Charset=\"ISO-8859-1\"")
        #expect(type.mimeType == "text/html")
        #expect(type.charset == "ISO-8859-1")
        #expect(HTTP1.parseContentType(nil).mimeType == nil)
    }
}

/// A transport that never touches the network.
final class FakeTransport: FetchTransport, @unchecked Sendable {
    struct Connect: Equatable {
        var address: IPAddress
        var serverName: String
        var request: String
    }

    private let lock = NSLock()
    var dns: [String: [IPAddress]] = [:]
    var prefixes: [AddressPrefix] = []
    var interfacesFail = false
    /// What each host answers, one entry per connection to it, in order.
    var scripts: [String: [[Data]]] = [:]
    var hangs = false
    var remote: ((IPAddress) -> IPAddress)?
    private(set) var lookups: [String] = []
    private(set) var connects: [Connect] = []

    func resolve(_ host: String, timeout: TimeInterval) async throws -> [IPAddress] {
        lock.withLock { lookups.append(host) }
        guard let answer = dns[host] else { throw FetchError.unreachable("NXDOMAIN") }
        return answer
    }

    func localPrefixes() throws -> [AddressPrefix] {
        if interfacesFail { throw LocalInterfaces.Unavailable() }
        return prefixes
    }

    func makeConnection(to address: IPAddress, serverName: String) -> FetchConnection {
        lock.withLock {
            var queue = scripts[serverName] ?? []
            let script = queue.isEmpty ? [] : queue.removeFirst()
            scripts[serverName] = queue
            let connection = FakeConnection(address: remote?(address) ?? address, script: script, hangs: hangs)
            connects.append(Connect(address: address, serverName: serverName, request: ""))
            connection.onSend = { [weak self] request in
                self?.lock.withLock { self?.connects[(self?.connects.count ?? 1) - 1].request = request }
            }
            return connection
        }
    }
}

final class FakeConnection: FetchConnection, @unchecked Sendable {
    let address: IPAddress
    var script: [Data]
    let hangs: Bool
    var onSend: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Data?, Error>?
    private var closed = false

    init(address: IPAddress, script: [Data], hangs: Bool) {
        self.address = address
        self.script = script
        self.hangs = hangs
    }

    func start() async throws {}
    func send(_ data: Data) async throws { onSend?(String(decoding: data, as: UTF8.self)) }
    func remoteAddress() -> IPAddress? { address }

    func receive() async throws -> Data? {
        if hangs {
            return try await withCheckedThrowingContinuation { continuation in
                let wasClosed = lock.withLock { () -> Bool in
                    if !closed { waiter = continuation }
                    return closed
                }
                if wasClosed { continuation.resume(throwing: FetchError.unreachable("closed")) }
            }
        }
        return lock.withLock { script.isEmpty ? nil : script.removeFirst() }
    }

    func close() {
        let pending = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            closed = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(throwing: FetchError.unreachable("closed"))
    }
}

struct SafeFetcherTests {
    static let limits = FetchLimits(maxBytes: 100_000, maxHTMLBytes: 100_000, stopAtEndOfHead: false)
    let transport = FakeTransport()

    init() {
        transport.dns = [
            "site.example": [ip("93.184.216.34")],
            "cdn.example": [ip("151.101.1.1")],
            "ipv6.example": [ip("2606:4700::1111")],
        ]
    }

    static func response(_ status: Int, _ headers: [String: String] = [:], body: String = "") -> [Data] {
        var text = "HTTP/1.1 \(status) X\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        return [Data(text.utf8)]
    }

    func fetch(_ url: String) async throws -> FetchedResource {
        try await SafeFetcher(transport: transport).fetch(URL(string: url)!, limits: Self.limits)
    }

    @Test func fetchesFromTheValidatedAddress() async throws {
        transport.scripts["site.example"] = [Self.response(200, ["Content-Type": "text/html; charset=utf-8"], body: "<head></head>")]
        let result = try await fetch("https://site.example/a?b=1")
        #expect(result.status == 200)
        #expect(result.mimeType == "text/html")
        #expect(result.charset == "utf-8")
        #expect(String(decoding: result.body, as: UTF8.self) == "<head></head>")
        #expect(transport.connects.count == 1)
        #expect(transport.connects[0].address == ip("93.184.216.34"))
        #expect(transport.connects[0].serverName == "site.example")
        #expect(transport.connects[0].request.hasPrefix("GET /a?b=1 HTTP/1.1\r\nHost: site.example\r\n"))
        #expect(transport.lookups == ["site.example"])
    }

    @Test func neverResolvesOrConnectsToLocalNames() async {
        for url in ["https://printer.local/", "https://localhost/", "https://nas/", "http://site.example/", "https://site.example:8443/"] {
            await #expect(throws: FetchError.self, "\(url)") { try await fetch(url) }
        }
        #expect(transport.lookups.isEmpty)
        #expect(transport.connects.isEmpty)
    }

    func expectRefused(_ url: String) async {
        do {
            _ = try await fetch(url)
            Issue.record("\(url) was fetched")
        } catch let error as FetchError {
            if case .refused = error { return }
            Issue.record("\(url): \(error)")
        } catch {
            Issue.record("\(url): \(error)")
        }
    }

    @Test func refusesBlockedLiterals() async {
        for url in ["https://127.0.0.1/", "https://192.168.1.1/x", "https://[::1]/", "https://[fe80::1]/", "https://[fd00::1]/", "https://169.254.169.254/"] {
            await expectRefused(url)
        }
        #expect(transport.connects.isEmpty)
    }

    @Test func refusesNamesThatResolveLocally() async throws {
        transport.dns["evil.example"] = [ip("127.0.0.1")]
        transport.dns["mixed.example"] = [ip("93.184.216.34"), ip("10.0.0.5")]
        transport.dns["mapped.example"] = [ip("::ffff:192.168.0.1")]
        transport.dns["empty.example"] = []
        for host in ["evil.example", "mixed.example", "mapped.example"] {
            do {
                _ = try await fetch("https://\(host)/")
                Issue.record("\(host) was fetched")
            } catch let error as FetchError {
                guard case .refused = error else { Issue.record("\(host): \(error)"); continue }
            }
        }
        await #expect(throws: FetchError.self) { try await fetch("https://empty.example/") }
        #expect(transport.connects.isEmpty)
    }

    @Test func refusesAddressesOnTheDevicesOwnNetwork() async {
        transport.prefixes = [AddressPrefix("93.184.216.0/24")]
        await #expect(throws: FetchError.self) { try await fetch("https://site.example/") }
        #expect(transport.connects.isEmpty)
        transport.interfacesFail = true
        await #expect(throws: FetchError.self) { try await fetch("https://cdn.example/") }
        #expect(transport.connects.isEmpty)
    }

    @Test func connectsOverIPv6() async throws {
        transport.scripts["ipv6.example"] = [Self.response(200)]
        _ = try await fetch("https://ipv6.example/")
        #expect(transport.connects.first?.address == ip("2606:4700::1111"))
    }

    @Test func refusesAConnectionThatWentElsewhere() async {
        transport.remote = { _ in ip("192.168.1.1") }
        transport.scripts["site.example"] = [Self.response(200)]
        await #expect(throws: FetchError.refused("connected elsewhere")) { try await fetch("https://site.example/") }
    }

    @Test func followsRedirectsThroughEveryCheck() async throws {
        transport.scripts["site.example"] = [Self.response(301, ["Location": "/moved"]), Self.response(302, ["Location": "https://cdn.example/final?x=1"])]
        transport.scripts["cdn.example"] = [Self.response(200, ["Content-Type": "text/plain"], body: "done")]
        let result = try await fetch("https://site.example/start")
        #expect(String(decoding: result.body, as: UTF8.self) == "done")
        #expect(transport.connects.map(\.serverName) == ["site.example", "site.example", "cdn.example"])
        #expect(transport.connects[1].request.hasPrefix("GET /moved HTTP/1.1"))
        #expect(transport.connects[2].request.hasPrefix("GET /final?x=1 HTTP/1.1"))
        #expect(result.url.absoluteString == "https://site.example/start" || result.url.host == "cdn.example")
    }

    @Test func refusesRedirectsToTheLocalNetwork() async {
        let targets = ["http://site.example/plain", "https://192.168.1.1/admin", "https://printer.local/", "https://[::1]/", "https://evil.example/",
                       "https://site.example:8443/", "//10.0.0.1/x", "https://localhost/"]
        transport.dns["evil.example"] = [ip("10.1.2.3")]
        for target in targets {
            transport.scripts["site.example"] = [Self.response(307, ["Location": target])]
            await #expect(throws: FetchError.self, "\(target)") { try await fetch("https://site.example/") }
        }
        #expect(transport.connects.allSatisfy { $0.serverName == "site.example" })
    }

    @Test func stopsAfterFiveRedirects() async throws {
        transport.scripts["site.example"] = (0..<6).map { _ in Self.response(302, ["Location": "/again"]) }
        await #expect(throws: FetchError.tooManyRedirects) { try await fetch("https://site.example/") }
        #expect(transport.connects.count == 6)

        transport.scripts["site.example"] = (0..<5).map { _ in Self.response(302, ["Location": "/again"]) } + [Self.response(200)]
        #expect(try await fetch("https://site.example/").status == 200)
    }

    @Test func redirectWithoutLocationIsReturnedAsIs() async throws {
        transport.scripts["site.example"] = [Self.response(302)]
        #expect(try await fetch("https://site.example/").status == 302)
    }

    @Test func badResponsesMapToErrors() async {
        transport.scripts["site.example"] = [[Data("not http at all\r\n\r\n".utf8)]]
        await #expect(throws: FetchError.badResponse) { try await fetch("https://site.example/") }
        transport.scripts["site.example"] = [[Data("HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n".utf8)]]
        await #expect(throws: FetchError.tooLarge) { try await fetch("https://site.example/") }
        transport.scripts["site.example"] = [[]]
        await #expect(throws: FetchError.self) { try await fetch("https://site.example/") }
    }

    @Test func timesOut() async {
        transport.hangs = true
        let fetcher = SafeFetcher(transport: transport, requestTimeout: 0.2, totalTimeout: 1)
        await #expect(throws: FetchError.timedOut) { try await fetcher.fetch(URL(string: "https://site.example/")!, limits: Self.limits) }
    }

    @Test func totalTimeoutSpansRedirects() async {
        transport.scripts["site.example"] = (0..<5).map { _ in Self.response(302, ["Location": "/again"]) }
        transport.hangs = false
        let fetcher = SafeFetcher(transport: transport, requestTimeout: 5, totalTimeout: 0)
        await #expect(throws: FetchError.timedOut) { try await fetcher.fetch(URL(string: "https://site.example/")!, limits: Self.limits) }
    }
}

/// Real network, off by default: `YAPNEST_NETWORK=1 swift test --filter LiveLinkFetchTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_NETWORK"] == "1"))
struct LiveLinkFetchTests {
    let limits = FetchLimits(maxBytes: 10_000_000, maxHTMLBytes: 1_000_000, stopAtEndOfHead: true)

    @Test func fetchesPublicPages() async throws {
        for url in ["https://www.apple.com/", "https://en.wikipedia.org/wiki/XMPP"] {
            let result = try await SafeFetcher().fetch(URL(string: url)!, limits: limits)
            let html = String(decoding: result.body, as: UTF8.self)
            let graph = OpenGraph(html: html, base: result.url)
            print("LIVE", url, result.status, result.mimeType ?? "-", result.body.count, graph.title ?? "-", graph.image?.absoluteString ?? "-")
            #expect(result.status == 200)
            #expect(graph.title != nil)
        }
    }

    @Test func followsRedirectToTheImage() async throws {
        let result = try await SafeFetcher().fetch(URL(string: "https://en.wikipedia.org/wiki/Special:FilePath/Example.jpg")!, limits: limits)
        #expect(result.status == 200)
        #expect(result.mimeType?.hasPrefix("image/") == true)
    }

    @Test func refusesNamesThatResolveToLoopback() async throws {
        let transport = SystemTransport()
        let addresses = try await transport.resolve("localtest.me", timeout: 10)
        print("LIVE localtest.me ->", addresses.map(\.bytes))
        let fetcher = SafeFetcher(transport: CountingTransport(base: transport))
        await #expect(throws: FetchError.self) { try await fetcher.fetch(URL(string: "https://localtest.me/")!, limits: limits) }
        #expect(CountingTransport.connections.withLock { $0 } == 0)
    }

    @Test func refusesBadCertificates() async {
        for url in ["https://expired.badssl.com/", "https://wrong.host.badssl.com/", "https://self-signed.badssl.com/"] {
            await #expect(throws: FetchError.self, "\(url)") { try await SafeFetcher().fetch(URL(string: url)!, limits: limits) }
        }
    }
}

import os

struct CountingTransport: FetchTransport {
    static let connections = OSAllocatedUnfairLock(initialState: 0)
    let base: SystemTransport
    func resolve(_ host: String, timeout: TimeInterval) async throws -> [IPAddress] { try await base.resolve(host, timeout: timeout) }
    func localPrefixes() throws -> [AddressPrefix] { try base.localPrefixes() }
    func makeConnection(to address: IPAddress, serverName: String) -> FetchConnection {
        Self.connections.withLock { $0 += 1 }
        return base.makeConnection(to: address, serverName: serverName)
    }
}
