import Foundation
@preconcurrency import Martin
import os

/// What the server's external services (XEP-0215) mean for a call's ICE.
struct ExternalService: Sendable, Equatable {
    var type: String
    var host: String
    var port: Int?
    var transport: String?
    var username: String?
    var password: String?
    var expires: Date?
}

extension ExternalService {
    init(_ service: ExternalServiceDiscoveryModule.Service) {
        self.init(
            type: service.type, host: service.host, port: service.port.map(Int.init), transport: service.transport?.rawValue,
            username: service.username, password: service.password, expires: service.expires,
        )
    }
}

extension CallIceServer {
    /// STUN and TURN servers out of the services a server lists. Others, those
    /// whose credentials have run out, STUN over TLS and hosts that couldn't be
    /// written in a URL are left out.
    static func servers(from services: [ExternalService], now: Date = Date()) -> [CallIceServer] {
        services.compactMap { service in
            if let expires = service.expires, expires <= now { return nil }
            guard service.host.allSatisfy({ !$0.isWhitespace && !"/?#@".contains($0) }), !service.host.isEmpty else { return nil }
            let host = service.host.contains(":") && !service.host.hasPrefix("[") ? "[\(service.host)]" : service.host
            switch service.type.lowercased() {
            case "stun":
                return CallIceServer(urls: ["stun:\(host):\(service.port ?? 3478)"])
            case "turn":
                let transport = service.transport?.lowercased() == "tcp" ? "tcp" : "udp"
                return credentialed(["turn:\(host):\(service.port ?? 3478)?transport=\(transport)"], service)
            case "turns":
                return credentialed(["turns:\(host):\(service.port ?? 5349)?transport=tcp"], service)
            default:
                return nil
            }
        }
    }

    private static func credentialed(_ urls: [String], _ service: ExternalService) -> CallIceServer {
        CallIceServer(urls: urls, username: service.username, credential: service.password)
    }
}

/// The relays discovered for calls, kept until their credentials run out so
/// that answering a call needn't wait for the server. A discovery in flight
/// is shared by whoever asks meanwhile.
final class IceServerCache: Sendable {
    struct Discovered: Sendable {
        var servers: [CallIceServer]
        /// When the earliest of their credentials runs out; nil if none do.
        var expires: Date?
    }

    /// How long servers whose credentials never expire are kept.
    static let defaultLifetime: TimeInterval = 600
    /// A call keeps using its servers for a while, so ones about to expire
    /// aren't reused.
    static let margin: TimeInterval = 30

    private struct State {
        var servers: [CallIceServer]?
        var validUntil = Date.distantPast
        var inFlight: Task<[CallIceServer], Never>?
        /// Bumped by `reset`, so a discovery that began before it isn't kept.
        var generation = 0
    }

    private let guarded = OSAllocatedUnfairLock(initialState: State())

    /// The cached servers, or what `discover` finds. A nil from it, a failure,
    /// gives no servers and isn't kept.
    func servers(now: @escaping @Sendable () -> Date = { Date() }, discover: @escaping @Sendable () async -> Discovered?) async -> [CallIceServer] {
        let (cached, task) = guarded.withLockUnchecked { state -> ([CallIceServer]?, Task<[CallIceServer], Never>?) in
            if let servers = state.servers, now() < state.validUntil {
                return (servers, nil)
            }
            if let inFlight = state.inFlight { return (nil, inFlight) }
            let generation = state.generation
            let task = Task { [self] in
                let found = await discover()
                guarded.withLockUnchecked { state in
                    guard state.generation == generation else { return }
                    state.inFlight = nil
                    guard let found else { return }
                    let lifetime = found.expires.map { $0.timeIntervalSince(now()) - Self.margin } ?? Self.defaultLifetime
                    state.servers = found.servers
                    state.validUntil = now().addingTimeInterval(lifetime)
                }
                return found?.servers ?? []
            }
            state.inFlight = task
            return (nil, task)
        }
        if let cached { return cached }
        return await task!.value
    }

    /// Whether the last discovery got an answer, empty or not. When it didn't,
    /// the lack of servers says nothing about what the server offers.
    func hasAnswer(now: Date = Date()) -> Bool {
        guarded.withLockUnchecked { $0.servers != nil && now < $0.validUntil }
    }

    /// Forgets everything, as a new connection has new credentials.
    func reset() {
        guarded.withLockUnchecked { state in
            state.generation += 1
            state.servers = nil
            state.inFlight = nil
        }
    }
}
