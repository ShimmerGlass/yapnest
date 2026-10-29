import Foundation
import Network
import os
import Security

/// The real transport: our own `getaddrinfo` and a Network.framework
/// connection to the address we picked.
struct SystemTransport: FetchTransport {
    func resolve(_ host: String, timeout: TimeInterval) async throws -> [IPAddress] {
        // getaddrinfo can't be interrupted, so a timer settles the result
        // first when the resolver hangs.
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let finish: @Sendable (Result<[IPAddress], Error>) -> Void = { result in
                guard once.first() else { return }
                continuation.resume(with: result)
            }
            DispatchQueue.global(qos: .utility).async { finish(Result { try Self.lookup(host) }) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(.failure(FetchError.timedOut)) }
        }
    }

    func localPrefixes() throws -> [AddressPrefix] {
        try LocalInterfaces.prefixes()
    }

    func makeConnection(to address: IPAddress, serverName: String) -> FetchConnection {
        NWFetchConnection(address: address, serverName: serverName)
    }

    /// The trailing dot makes the name fully qualified. Without it the system
    /// resolver may retry a failed name with the search domains from the
    /// network's configuration appended, which sends queries derived from the
    /// LAN and could land on a LAN host. The certificate name and the Host
    /// header keep the name without the dot.
    static func fullyQualified(_ host: String) -> String {
        host.hasSuffix(".") ? host : host + "."
    }

    private static func lookup(_ host: String) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(fullyQualified(host), "443", &hints, &list)
        guard code == 0 else { throw FetchError.unreachable("lookup: \(String(cString: gai_strerror(code)))") }
        defer { freeaddrinfo(list) }

        var result: [IPAddress] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let sa = entry.pointee.ai_addr, let bytes = LocalInterfaces.bytes(of: UnsafePointer(sa)) else { continue }
            if let address = IPAddress(bytes: bytes), !result.contains(address) { result.append(address) }
        }
        return result
    }
}

final class NWFetchConnection: FetchConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "yapnest.linkpreview.connection")
    private let closedLocally = OSAllocatedUnfairLock(initialState: false)
    private let endOfStream = OSAllocatedUnfairLock(initialState: false)

    /// What differs between production and the tests' local server. Only the
    /// defaults are reachable from `SystemTransport`.
    struct Configuration: Sendable {
        var port: UInt16 = 443
        var allowsLoopback = false
        var usesTLS = true
    }

    init(address: IPAddress, serverName: String, configuration: Configuration = Configuration()) {
        let host: NWEndpoint.Host = address.isIPv4
            ? .ipv4(IPv4Address(Data(address.bytes))!)
            : .ipv6(IPv6Address(Data(address.bytes))!)

        let parameters: NWParameters
        if configuration.usesTLS {
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            if address != IPAddress(literal: serverName) {
                sec_protocol_options_set_tls_server_name(options, serverName)
            }
            sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            // Judge the certificate by the real name, whatever address we dialled.
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(reference, SecPolicyCreateSSL(true, serverName as CFString))
                complete(SecTrustEvaluateWithError(reference, nil))
            }, queue)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        parameters.preferNoProxies = true
        if !configuration.allowsLoopback { parameters.prohibitedInterfaceTypes = [.loopback] }
        connection = NWConnection(to: .hostPort(host: host, port: NWEndpoint.Port(rawValue: configuration.port)!), using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            let first: @Sendable () -> Bool = { once.first() }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if first() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // Waiting means no route right now; the caller retries later.
                    if first() { continuation.resume(throwing: Self.map(error)) }
                    self.connection.cancel()
                case .cancelled:
                    if first() { continuation.resume(throwing: FetchError.unreachable("cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Self.map(error)) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data? {
        // The last bytes can arrive together with the server's close. Asking
        // for more after that fails with ENODATA instead of reporting the end.
        if endOfStream.withLock({ $0 }) { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [closedLocally, endOfStream] data, _, isComplete, error in
                if isComplete, error == nil { endOfStream.withLock { $0 = true } }
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete, closedLocally.withLock({ $0 }) {
                    // Our own close must not look like the server finishing, or
                    // a body cut off by a timeout would pass for a whole one.
                    continuation.resume(throwing: FetchError.unreachable("closed"))
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    func remoteAddress() -> IPAddress? {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let address): return IPAddress(bytes: Array(address.rawValue))
        case .ipv6(let address): return IPAddress(bytes: Array(address.rawValue))
        default: return nil
        }
    }

    func close() {
        closedLocally.withLock { $0 = true }
        connection.cancel()
    }

    private static func map(_ error: NWError) -> FetchError {
        if case .tls = error { return .refused("TLS: \(error)") }
        return .unreachable("\(error)")
    }
}
