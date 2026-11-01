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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FetchError.refused("host") }
        host = try AddressVetting.hostKind(of: components) { $0 == nil || $0 == 443 }
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

extension AddressPolicy {
    enum Vetting {
        case allowed([IPAddress])
        case blocked(IPAddress)
    }

    /// Reads the local networks, right after the name was resolved, and
    /// checks every address. One bad address among the answers is enough to
    /// distrust the rest.
    static func vet(_ candidates: [IPAddress], transport: FetchTransport) throws -> Vetting {
        let prefixes: [AddressPrefix]
        do { prefixes = try transport.localPrefixes() } catch { throw FetchError.refused("interfaces unknown") }
        guard !candidates.isEmpty else { throw FetchError.unreachable("no address") }
        if let blocked = candidates.first(where: { isBlocked($0, localPrefixes: prefixes) }) { return .blocked(blocked) }
        return .allowed(candidates)
    }
}

/// The checks a URL passes before anything is requested, shared by link
/// previews and downloads so that the two can't drift apart. The port rule is
/// the caller's: previews allow only 443, downloads any.
enum AddressVetting {
    /// Only HTTPS, no credentials, a port `allowsPort` accepts, and a host
    /// that isn't local by its name.
    static func hostKind(of components: URLComponents, allowsPort: (Int?) -> Bool) throws -> HostPolicy.Kind {
        guard components.scheme?.lowercased() == "https" else { throw FetchError.refused("not https") }
        guard components.percentEncodedUser == nil, components.percentEncodedPassword == nil else {
            throw FetchError.refused("credentials in URL")
        }
        guard allowsPort(components.port) else { throw FetchError.refused("port") }
        guard let raw = components.percentEncodedHost, !raw.contains("%"), let kind = HostPolicy.classify(raw) else {
            throw FetchError.refused("host")
        }
        return kind
    }

    /// Resolves the host and checks every address. The networks are read after
    /// resolving, right before the caller connects.
    static func addresses(for host: HostPolicy.Kind, transport: FetchTransport, timeout: TimeInterval) async throws -> [IPAddress] {
        let candidates: [IPAddress]
        switch host {
        case .literal(let address): candidates = [address]
        case .name(let name): candidates = try await transport.resolve(name, timeout: timeout)
        }
        switch try AddressPolicy.vet(candidates, transport: transport) {
        case .blocked:
            // A name that resolves to a local address is often a captive
            // portal's or a flaky resolver's answer, which passes; only a
            // literal address is final.
            if case .literal = host { throw FetchError.refused("address is local") }
            throw FetchError.unreachable("address is local")
        case .allowed(let allowed): return allowed
        }
    }
}

final class SafeFetcher: LinkFetching {
    static let maxRedirects = 5
    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    private let transport: FetchTransport
    private let requestTimeout: TimeInterval
    private let totalTimeout: TimeInterval
    private let connectTimeout: TimeInterval

    init(transport: FetchTransport = SystemTransport(), requestTimeout: TimeInterval = 15, totalTimeout: TimeInterval = 30, connectTimeout: TimeInterval = 4) {
        self.transport = transport
        self.connectTimeout = connectTimeout
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
        // The lookup counts against the hop's timeout, or a slow resolver
        // and a slow server would take twice the budget between them.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let target = try FetchTarget(url)

        let addresses = try await AddressVetting.addresses(for: target.host, transport: transport, timeout: timeout)

        // One timeout covers every address: a fetch that is slow everywhere
        // shouldn't take a timeout per address. Connecting to an address that
        // isn't the last has a deadline of its own, though, as one that
        // swallows packets would use up the whole timeout before the next
        // was tried; a connection that failed or didn't answer in time goes
        // on to the next, and a request that timed out doesn't.
        var failure = FetchError.unreachable("no address")
        for (index, address) in addresses.enumerated() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw FetchError.timedOut }
            // Half of what is left, so the others share the rest, and at most
            // a few round trips of a slow mobile network.
            let isLast = index == addresses.count - 1
            let connectTimeout = isLast ? nil : min(remaining / 2, self.connectTimeout)
            do {
                return try await fetchOnce(url, target: target, from: address, limits: limits, timeout: remaining, connectTimeout: connectTimeout)
            } catch let error as NotConnected {
                failure = error.error
            }
        }
        throw failure
    }

    /// The connection to an address failed before anything was sent, so
    /// another address may do.
    private struct NotConnected: Error {
        var error: FetchError
    }

    private func fetchOnce(_ url: URL, target: FetchTarget, from address: IPAddress, limits: FetchLimits, timeout: TimeInterval, connectTimeout: TimeInterval?) async throws -> FetchedResource {
        let connection = transport.makeConnection(to: address, serverName: target.hostName)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let connectTimedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            timedOut.withLock { $0 = true }
            connection.close()
        }
        let connectTimer = connectTimeout.map { limit in
            Task {
                try await Task.sleep(for: .seconds(limit))
                connectTimedOut.withLock { $0 = true }
                connection.close()
            }
        }
        defer {
            timer.cancel()
            connectTimer?.cancel()
            connection.close()
        }

        do {
            return try await withTaskCancellationHandler {
                do {
                    try await connection.start()
                    connectTimer?.cancel()
                } catch is CancellationError {
                    throw CancellationError()
                } catch where connectTimedOut.withLock({ $0 }) {
                    throw NotConnected(error: .unreachable("no answer in time"))
                } catch let error as FetchError {
                    // A refusal, such as a certificate that doesn't fit, is final.
                    guard case .unreachable = error else { throw error }
                    throw NotConnected(error: error)
                } catch {
                    throw NotConnected(error: .unreachable("\(error)"))
                }
                guard let remote = connection.remoteAddress(), AddressPolicy.endpoint(remote, matches: address) else {
                    throw FetchError.refused("connected elsewhere")
                }
                try await connection.send(HTTP1.request(host: target.hostName, target: target.requestTarget))

                var parser = HTTP1ResponseParser(limits: limits)
                while !parser.isComplete {
                    guard let chunk = try await connection.receive() else {
                        // A connection that closed early (a reset, a dropped
                        // network) says nothing about the page.
                        do { try parser.receiveEnd() } catch { throw FetchError.unreachable("response cut short") }
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
        } catch let error as NotConnected {
            throw timedOut.withLock { $0 } ? FetchError.timedOut : error
        } catch let error as FetchError {
            throw timedOut.withLock { $0 } ? FetchError.timedOut : error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw timedOut.withLock { $0 } ? FetchError.timedOut : FetchError.unreachable("\(error)")
        }
    }
}
