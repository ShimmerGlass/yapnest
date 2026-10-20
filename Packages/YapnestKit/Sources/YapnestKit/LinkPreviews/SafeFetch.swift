import Foundation
import os

// Link previews fetch addresses that strangers put in messages, so they must
// never reach the local network: not a router's admin page, not a printer,
// not mDNS. URLSession can't promise that. It resolves names itself, so an
// address checked beforehand can differ from the one it connects to (DNS
// rebinding), and it follows redirects to anywhere. So this file resolves the
// name once, checks every address, and connects to exactly the one it checked,
// with every redirect hop going through the same steps.

struct FetchedResource: Sendable {
    var status: Int
    /// Lowercased names.
    var headers: [String: String]
    var mimeType: String?
    var charset: String?
    /// After redirects.
    var url: URL
    var body: Data
}

enum FetchError: Error, Equatable {
    /// The URL or the address behind it isn't allowed. Retrying won't help.
    case refused(String)
    case tooManyRedirects
    case badResponse
    case tooLarge
    /// Worth trying again later.
    case timedOut
    case unreachable(String)

    var isRetryable: Bool {
        switch self {
        case .timedOut, .unreachable: true
        default: false
        }
    }
}

protocol LinkFetching: Sendable {
    func fetch(_ url: URL, limits: FetchLimits) async throws -> FetchedResource
}

/// One TLS connection to a fixed address.
protocol FetchConnection: AnyObject, Sendable {
    /// Returns once the TLS handshake has completed.
    func start() async throws
    func send(_ data: Data) async throws
    /// Nil once the server closed the connection.
    func receive() async throws -> Data?
    /// Where the connection really went, once started.
    func remoteAddress() -> IPAddress?
    func close()
}

/// The parts of fetching that touch the system, so that tests can replace them.
protocol FetchTransport: Sendable {
    func resolve(_ host: String, timeout: TimeInterval) async throws -> [IPAddress]
    func localPrefixes() throws -> [AddressPrefix]
    /// Must connect to `address` only, never resolving anything, and verify
    /// the server's certificate for `serverName`.
    func makeConnection(to address: IPAddress, serverName: String) -> FetchConnection
}

/// What a URL needs to pass before anything is resolved.
struct FetchTarget: Equatable {
    var host: HostPolicy.Kind
    var requestTarget: String

    var hostName: String {
        switch host {
        case .name(let name): name
        case .literal(let address): Self.text(of: address)
        }
    }

    /// Only HTTPS on port 443: the port is the usual way to reach a router
    /// or a printer on a public-looking name, and sharing links to other
    /// ports is rare enough not to be worth the exposure.
    init(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else { throw FetchError.refused("not https") }
        guard components.percentEncodedUser == nil, components.percentEncodedPassword == nil else {
            throw FetchError.refused("credentials in URL")
        }
        guard components.port == nil || components.port == 443 else { throw FetchError.refused("port") }
        guard let raw = components.percentEncodedHost, !raw.contains("%"), let kind = HostPolicy.classify(raw) else {
            throw FetchError.refused("host")
        }
        host = kind
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard target.hasPrefix("/"), target.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw FetchError.refused("path") }
        requestTarget = target
    }

    private static func text(of address: IPAddress) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        let family = address.isIPv4 ? AF_INET : AF_INET6
        _ = address.bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, 64) }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

final class SafeFetcher: LinkFetching {
    static let maxRedirects = 5
    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    private let transport: FetchTransport
    private let requestTimeout: TimeInterval
    private let totalTimeout: TimeInterval

    init(transport: FetchTransport = SystemTransport(), requestTimeout: TimeInterval = 15, totalTimeout: TimeInterval = 30) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.totalTimeout = totalTimeout
    }

    func fetch(_ url: URL, limits: FetchLimits) async throws -> FetchedResource {
        let deadline = ProcessInfo.processInfo.systemUptime + totalTimeout
        var current = url
        for hop in 0...Self.maxRedirects {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw FetchError.timedOut }
            let response = try await fetchOnce(current, limits: limits, timeout: min(requestTimeout, remaining))
            guard Self.redirectStatuses.contains(response.status), let location = response.headers["location"] else {
                return response
            }
            guard hop < Self.maxRedirects else { throw FetchError.tooManyRedirects }
            guard let next = URL(string: location, relativeTo: current)?.absoluteURL else { throw FetchError.badResponse }
            current = next
        }
        throw FetchError.tooManyRedirects
    }

    private func fetchOnce(_ url: URL, limits: FetchLimits, timeout: TimeInterval) async throws -> FetchedResource {
        let target = try FetchTarget(url)

        let candidates: [IPAddress]
        switch target.host {
        case .literal(let address): candidates = [address]
        case .name(let name): candidates = try await transport.resolve(name, timeout: timeout)
        }
        // The networks are read after resolving, right before connecting.
        let prefixes: [AddressPrefix]
        do { prefixes = try transport.localPrefixes() } catch { throw FetchError.refused("interfaces unknown") }
        // One bad address among the answers is enough to distrust the rest.
        guard let address = candidates.first else { throw FetchError.unreachable("no address") }
        if let blocked = candidates.first(where: { AddressPolicy.isBlocked($0, localPrefixes: prefixes) }) {
            throw FetchError.refused("address \(blocked.bytes) is local")
        }

        let connection = transport.makeConnection(to: address, serverName: target.hostName)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            timedOut.withLock { $0 = true }
            connection.close()
        }
        defer {
            timer.cancel()
            connection.close()
        }

        do {
            return try await withTaskCancellationHandler {
                try await connection.start()
                guard let remote = connection.remoteAddress(), AddressPolicy.endpoint(remote, matches: address) else {
                    throw FetchError.refused("connected elsewhere")
                }
                try await connection.send(HTTP1.request(host: target.hostName, target: target.requestTarget))

                var parser = HTTP1ResponseParser(limits: limits)
                while !parser.isComplete {
                    guard let chunk = try await connection.receive() else {
                        try parser.receiveEnd()
                        break
                    }
                    try parser.receive(chunk)
                }
                guard let head = parser.head else { throw FetchError.badResponse }
                let type = HTTP1.parseContentType(head.headers["content-type"])
                return FetchedResource(status: head.status, headers: head.headers, mimeType: type.mimeType, charset: type.charset,
                                       url: url, body: parser.body)
            } onCancel: {
                connection.close()
            }
        } catch where Task.isCancelled {
            // The cancel handler closed the connection, which surfaces as
            // whatever error the read saw; the caller asked to stop, though.
            throw CancellationError()
        } catch let error as HTTP1ResponseParser.Failure {
            throw error == .tooLarge ? FetchError.tooLarge : FetchError.badResponse
        } catch let error as FetchError {
            throw timedOut.withLock { $0 } ? FetchError.timedOut : error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw timedOut.withLock { $0 } ? FetchError.timedOut : FetchError.unreachable("\(error)")
        }
    }
}
