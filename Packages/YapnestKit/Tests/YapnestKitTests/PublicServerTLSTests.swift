import Foundation
import Martin
import Network
import Testing

/// Connects to a public server by its domain alone, so the connector looks up
/// its SRV records and checks its certificate against the system's roots, the
/// way the app does for a real account. It signs in to nothing: the client has
/// no auth module, so the exchange ends at the stream features over TLS.
/// Enable with `YAPNEST_PUBLIC_SERVER=<domain>`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAPNEST_PUBLIC_SERVER"] != nil))
struct PublicServerTLSTests {
    @Test func theStreamFeaturesArriveOverTLSWithTheSystemsTrust() async throws {
        let domain = try #require(ProcessInfo.processInfo.environment["YAPNEST_PUBLIC_SERVER"])
        let client = XMPPClient()
        _ = client.modulesManager.register(StreamFeaturesModule())
        client.connectionConfiguration.userJid = BareJID(domain)
        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnectorNetwork.Options.self) { $0.connectionTimeout = 20 }
        client.login()
        defer { _ = client.disconnect() }

        let deadline = Date().addingTimeInterval(25)
        var started = false
        var seen: SocketConnectorNetwork?
        while Date() < deadline, client.module(.streamFeatures).streamFeatures.element == nil {
            // Kept, as the client lets go of it when the connection ends.
            seen = seen ?? client.connector as? SocketConnectorNetwork
            // The client reads as disconnected until the login has begun.
            if case .connecting = client.state { started = true }
            if started, case .disconnected = client.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let connector = try #require(seen)
        let endpoint = connector.currentEndpoint.map { String(describing: $0) } ?? "unknown"
        let version = connector.negotiatedTLSVersion.map { String($0.rawValue, radix: 16) } ?? "none"
        print("PUBLICSERVER \(domain) endpoint=\(endpoint) tls=\(version) state=\(client.state)")
        #expect(connector.activeFeatures.contains(.TLS))
        #expect(client.module(.streamFeatures).streamFeatures.element != nil)
        #expect(connector.negotiatedTLSVersion != nil)
    }
}
