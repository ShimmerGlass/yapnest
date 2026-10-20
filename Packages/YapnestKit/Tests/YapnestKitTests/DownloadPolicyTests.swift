import Foundation
import Testing
@testable import YapnestKit

/// Where a received file may be fetched from without being asked to.
struct DownloadPolicyTests {
    private func policy(insecure: Bool = false, dns: [String: [IPAddress]] = [:]) -> DownloadPolicy {
        let transport = FakeTransport()
        transport.dns = dns
        return DownloadPolicy(allowsInsecure: insecure, transport: transport)
    }

    private let publicAddress = IPAddress(literal: "93.184.216.34")!

    private func refused(_ policy: DownloadPolicy, _ url: String) async -> Bool {
        do { try await policy.check(URL(string: url)!); return false } catch { return true }
    }

    @Test func publicHttpsIsAllowed() async {
        let policy = policy(dns: ["up.example.com": [publicAddress]])
        #expect(await !refused(policy, "https://up.example.com/a/cat.png"))
        #expect(await !refused(policy, "https://93.184.216.34/a/cat.png"))
    }

    @Test func plainHttpIsRefused() async {
        let policy = policy(dns: ["up.example.com": [publicAddress]])
        #expect(await refused(policy, "http://up.example.com/a/cat.png"))
    }

    @Test(arguments: [
        "https://localhost/a.png", "https://printer.local/a.jpg", "https://nas/a.jpg", "https://router.lan/a.jpg",
        "https://127.0.0.1/a.jpg", "https://192.168.1.1/a.jpg", "https://10.0.0.5/a.jpg", "https://169.254.1.1/a.jpg",
        "https://[::1]/a.jpg", "https://[fe80::1]/a.jpg", "https://user:pw@up.example.com/a.jpg",
    ])
    func localHostsAreRefused(url: String) async {
        let policy = policy(dns: ["up.example.com": [publicAddress]])
        #expect(await refused(policy, url))
    }

    @Test func aNameThatResolvesIntoTheLanIsRefused() async {
        let policy = policy(dns: [
            "evil.example.com": [publicAddress, IPAddress(literal: "192.168.0.10")!],
            "rebind.example.com": [IPAddress(literal: "127.0.0.1")!],
        ])
        #expect(await refused(policy, "https://evil.example.com/a.jpg"))
        #expect(await refused(policy, "https://rebind.example.com/a.jpg"))
        // Nothing resolves.
        #expect(await refused(policy, "https://missing.example.com/a.jpg"))
    }

    @Test func redirectsAreCheckedLikeTheFirstRequest() async {
        let policy = policy(dns: ["up.example.com": [publicAddress]])
        // What the redirect delegate asks of each hop.
        #expect(await refused(policy, "http://up.example.com/next"))
        #expect(await refused(policy, "https://192.168.1.1/admin.jpg"))
        #expect(await !refused(policy, "https://up.example.com/next"))
    }

    @Test func developmentServersAreNotChecked() async {
        let policy = policy(insecure: true)
        #expect(await !refused(policy, "http://localhost:5280/upload/a.jpg"))
        #expect(await !refused(policy, "http://192.168.1.1/a.jpg"))
    }
}
