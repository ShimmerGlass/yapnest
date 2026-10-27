import Foundation
import Testing
@testable import YapnestKit

/// Counts requests with a protocol of its own, as `StubProtocol`'s handler is
/// shared with the other load tests, which run alongside.
@Suite(.serialized) struct GifConsentTests {
    private final class CountingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var counter: Counter?
        static let body = Data(#"{"result":true,"data":{"data":[],"current_page":1,"has_next":false}}"#.utf8)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.counter?.hit()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func hit() { lock.withLock { value += 1 } }
    }

    private func make(_ counter: Counter) throws -> (ConsentedGifService, AppDatabase) {
        CountingProtocol.counter = counter
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        let service = GifService(apiKey: "k", locale: nil, session: URLSession(configuration: configuration))
        let database = try AppDatabase.inMemory()
        return (ConsentedGifService(service: service, database: database), database)
    }

    @Test func nothingIsRequestedBeforeConsent() async throws {
        let counter = Counter()
        let (gated, _) = try make(counter)
        await #expect(throws: ConsentedGifService.ConsentRequired()) { try await gated.trending(page: 1) }
        await #expect(throws: ConsentedGifService.ConsentRequired()) { try await gated.search("cats", page: 1) }
        #expect(counter.count == 0)
        #expect(await !gated.hasConsent())
    }

    @Test func acceptingLetsRequestsThrough() async throws {
        let counter = Counter()
        let (gated, database) = try make(counter)
        try await gated.agree()
        _ = try await gated.trending(page: 1)
        _ = try await gated.search("cats", page: 1)
        #expect(counter.count == 2)
        #expect(try database.setting(.gifConsent) == "1")
    }

    @Test func turningGifsOffFromTheNoticeRecordsNoConsentAndSendsNothing() async throws {
        let counter = Counter()
        let (gated, database) = try make(counter)
        try await gated.turnOffGifs()
        #expect(!database.flag(.gifs, default: true))
        #expect(try database.setting(.gifConsent) == nil)
        await #expect(throws: ConsentedGifService.ConsentRequired()) { try await gated.trending(page: 1) }
        #expect(counter.count == 0)
    }

    @Test func turningGifsBackOnWithoutAcceptingStillAsks() async throws {
        let counter = Counter()
        let (gated, database) = try make(counter)
        try await gated.turnOffGifs()
        try database.setFlag(.gifs, true)
        #expect(await !gated.hasConsent())
    }

    @Test func anEarlierAcceptStaysValidAfterGifsAreToggled() async throws {
        let counter = Counter()
        let (gated, database) = try make(counter)
        try await gated.agree()
        try database.setFlag(.gifs, false)
        try database.setFlag(.gifs, true)
        #expect(await gated.hasConsent())
    }
}
