import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!

/// A received file is fetched without being asked, so where it is fetched
/// from is checked for the first request and for every redirect.
struct DownloadRedirectTests {
    private func redirect(to location: String) -> LocalHTTPServer.Reply {
        .send([LocalHTTPServer.response(302, ["Location": location, "Connection": "close"])])
    }

    private func download(_ url: URL, allowingInsecure: Bool) async throws -> HTTPURLResponse {
        let delegate = ProgressDelegate(limit: nil, policy: DownloadPolicy(allowsInsecure: allowingInsecure)) { _ in }
        let (file, response) = try await URLSession(configuration: .ephemeral).download(from: url, delegate: delegate)
        try? FileManager.default.removeItem(at: file)
        return try #require(response as? HTTPURLResponse)
    }

    @Test func aRedirectIntoTheLocalNetworkIsNotFollowed() async throws {
        let server = try await LocalHTTPServer()
        defer { server.stop() }
        server.queue(redirect(to: "http://127.0.0.1:\(server.port)/secret"))
        server.queue(.send([LocalHTTPServer.response(200, body: "secret")]))

        let response = try await download(URL(string: "http://127.0.0.1:\(server.port)/pic.png")!, allowingInsecure: false)

        #expect(response.statusCode == 302)
        // Nothing asked the second address.
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.requests.count == 1)
    }

    @Test func aDevelopmentServerMayRedirectAnywhere() async throws {
        let server = try await LocalHTTPServer()
        defer { server.stop() }
        server.queue(redirect(to: "http://127.0.0.1:\(server.port)/next"))
        server.queue(.send([LocalHTTPServer.response(200, ["Connection": "close"], body: "ok")]))

        let response = try await download(URL(string: "http://127.0.0.1:\(server.port)/pic.png")!, allowingInsecure: true)

        #expect(response.statusCode == 200)
        #expect(server.requests.count == 2)
    }

    @Test func aFileAtAnAddressInTheLocalNetworkIsNeverRequested() async throws {
        let server = try await LocalHTTPServer()
        defer { server.stop() }
        let database = try AppDatabase.inMemory()
        let session = try makeSession(me, database: database)
        let conversation = try database.conversation(with: alice)
        let message = try database.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "https://127.0.0.1:\(server.port)/pic.png", remoteId: "m1"))
        let attachment = Attachment(messageId: message.id!, url: "https://127.0.0.1:\(server.port)/pic.png", name: "pic.png", mimeType: "image/png", state: .remote)
        try await database.writer.write { try attachment.insert($0) }

        session.download(attachment)

        let failed = await eventually { (try? database.attachment(messageId: message.id!))?.state == .downloadFailed }
        #expect(failed)
        #expect(server.accepted == 0)
    }
}
