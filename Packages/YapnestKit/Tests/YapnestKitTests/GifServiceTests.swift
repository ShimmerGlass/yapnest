import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct GifServiceTests {
    private let service = GifService(apiKey: "k/ey", locale: "fr")

    private func items(_ request: URLRequest) -> [String: String] {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func trendingRequest() {
        let request = service.request(query: nil, page: 2)
        let url = request.url!
        #expect(url.scheme == "https" && url.host == "api.klipy.com")
        #expect(url.path(percentEncoded: true) == "/api/v1/k%2Fey/gifs/trending")
        #expect(items(request) == ["page": "2", "per_page": "24", "locale": "fr", "content_filter": "medium", "format_filter": "gif,jpg"])
    }

    @Test func searchRequestEncodesTheQuery() {
        let request = service.request(query: " cats & dogs+ ", page: 1)
        #expect(request.url!.path(percentEncoded: true) == "/api/v1/k%2Fey/gifs/search")
        #expect(request.url!.query(percentEncoded: true)!.contains("q=cats%20%26%20dogs%2B&"))
        #expect(items(request)["q"] == "cats & dogs+")
    }

    @Test func blankQueryIsTrending() {
        let request = service.request(query: "  \n", page: 1)
        #expect(request.url!.path(percentEncoded: true).hasSuffix("/gifs/trending"))
        #expect(items(request)["q"] == nil)
    }

    @Test func noLocaleOmitsIt() {
        #expect(items(GifService(apiKey: "k", locale: nil).request(query: nil, page: 1))["locale"] == nil)
    }

    private let fixture: Data = {
        func file(_ name: String, _ size: String = "100", ext: String = "gif") -> String {
            "{\"url\":\"https://static.klipy.com/\(name).\(ext)\",\"width\":200,\"height\":100,\"size\":\(size)}"
        }
        func item(_ id: Int, type: String = "gif", sizes: [String: String]) -> String {
            let file = sizes.map { "\"\($0.key)\":{\"gif\":\($0.value),\"jpg\":\(file("\(id)-\($0.key)", ext: "jpg"))}" }.joined(separator: ",")
            return "{\"id\":\(id),\"slug\":\"s\(id)\",\"title\":\"T\(id)\",\"type\":\"\(type)\",\"file\":{\(file)},\"tags\":[],\"blur_preview\":\"x\"}"
        }
        let json = """
        {"result":true,"data":{"data":[
        \(item(1, sizes: ["xs": file("1xs"), "sm": file("1sm"), "md": file("1md", "2000000"), "hd": file("1hd")])),
        \(item(2, sizes: ["sm": file("2sm"), "md": file("2md", "1000000")])),
        \(item(3, type: "ad", sizes: ["sm": file("3sm"), "md": file("3md")])),
        \(item(4, sizes: ["xs": file("4xs"), "sm": file("4sm")])),
        \(item(5, sizes: ["sm": file("5sm"), "md": file("5md", "3500000")])),
        \(item(6, sizes: ["sm": file("6sm", "330000.5"), "md": file("6md", "2200000.7")])),
        {"id":7,"slug":"broken","file":"nope"},
        {"id":8,"slug":"nogif","file":{"sm":{"jpg":\(file("8sm", ext: "jpg"))}}}
        ],"current_page":1,"per_page":24,"has_next":true}}
        """
        return Data(json.utf8)
    }()

    @Test func decodesAPage() throws {
        let page = try GifService.decode(fixture, page: 1)
        #expect(page.hasNext && page.page == 1)
        // The ad, the item without a gif and the malformed item are dropped.
        #expect(page.gifs.map(\.id) == ["1", "2", "4", "5", "6"])
        let first = page.gifs[0]
        #expect(first.slug == "s1" && first.title == "T1")
        #expect(first.preview.url.absoluteString == "https://static.klipy.com/1sm.gif")
        #expect(first.preview.size == 100 && first.preview.width == 200 && first.preview.height == 100)
        #expect(first.still?.absoluteString == "https://static.klipy.com/1-sm.jpg")
        #expect(first.shared.url.absoluteString == "https://static.klipy.com/1md.gif")
        #expect(first.shared.size == 2_000_000)
    }

    @Test func sharedFallsBackToSmall() throws {
        let gifs = try GifService.decode(fixture, page: 1).gifs
        // No medium size.
        #expect(gifs[2].shared.url.absoluteString == "https://static.klipy.com/4sm.gif")
        // A medium size over 3 MB.
        #expect(gifs[3].shared.url.absoluteString == "https://static.klipy.com/5sm.gif")
    }

    /// One item with the given sizes (name to byte size), each a gif at `<name>.gif`.
    private func shared(_ sizes: [String: Int]) throws -> String? {
        let files = sizes.map { name, size in
            "\"\(name)\":{\"gif\":{\"url\":\"https://static.klipy.com/\(name).gif\",\"width\":2,\"height\":1,\"size\":\(size)}}"
        }.joined(separator: ",")
        let json = #"{"result":true,"data":{"data":[{"id":1,"file":{\#(files)}}]}}"#
        let gif = try GifService.decode(Data(json.utf8), page: 1).gifs.first
        return gif?.shared.url.deletingPathExtension().lastPathComponent
    }

    @Test func mediumIsSharedWhenItFits() throws {
        #expect(try shared(["xs": 10, "sm": 100, "md": 3_000_000, "hd": 9_000_000]) == "md")
    }

    @Test func smallIsSharedWhenMediumIsTooBig() throws {
        #expect(try shared(["xs": 10, "sm": 100, "md": 3_000_001]) == "sm")
    }

    @Test func extraSmallBeatsAnOversizedMediumWhenSmallIsMissing() throws {
        #expect(try shared(["xs": 10, "md": 3_000_001, "hd": 9_000_000]) == "xs")
    }

    @Test func oversizedMediumBeatsHdWhenNothingSmallerExists() throws {
        #expect(try shared(["md": 3_000_001, "hd": 9_000_000]) == "md")
    }

    @Test func gifWithOnlyHdHasNoPreviewAndIsDropped() throws {
        #expect(try shared(["hd": 100]) == nil)
    }

    @Test func stillPrefersSmallThenExtraSmall() throws {
        let page = try GifService.decode(Data("""
        {"result":true,"data":{"data":[
        {"id":1,"file":{"sm":{"gif":{"url":"https://s.test/a.gif","width":1,"height":1},"jpg":{"url":"https://s.test/sm.jpg","width":1,"height":1}},
                        "xs":{"gif":{"url":"https://s.test/b.gif","width":1,"height":1},"jpg":{"url":"https://s.test/xs.jpg","width":1,"height":1}}}},
        {"id":2,"file":{"sm":{"gif":{"url":"https://s.test/a.gif","width":1,"height":1}},
                        "xs":{"gif":{"url":"https://s.test/b.gif","width":1,"height":1},"jpg":{"url":"https://s.test/xs.jpg","width":1,"height":1}}}},
        {"id":3,"file":{"sm":{"gif":{"url":"https://s.test/a.gif","width":1,"height":1}}}}
        ]}}
        """.utf8), page: 1)
        #expect(page.gifs.map { $0.still?.lastPathComponent } == ["sm.jpg", "xs.jpg", nil])
    }

    @Test func floatSizesDecode() throws {
        let gif = try GifService.decode(fixture, page: 1).gifs[4]
        #expect(gif.preview.size == 330_000)
        #expect(gif.shared.url.absoluteString == "https://static.klipy.com/6md.gif")
        #expect(gif.shared.size == 2_200_000)
    }

    @Test func failureThrows() {
        #expect(throws: GifServiceError.self) { try GifService.decode(Data(#"{"result":false}"#.utf8), page: 1) }
        #expect(throws: GifServiceError.self) { try GifService.decode(Data("nonsense".utf8), page: 1) }
    }
}

struct GifSettingTests {
    @Test func gifsAreOnUntilTurnedOffAndFollowTheSetting() async throws {
        let db = try AppDatabase.inMemory()
        var values = db.observeGifsEnabled().values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        #expect(try await values.next() == true)
        try db.setFlag(.gifs, false)
        #expect(try await values.next() == false)
        try db.setFlag(.gifs, true)
        #expect(try await values.next() == true)
    }
}

/// Answers every request from `handler`, so `load` can be driven without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Serialized because the stub's handler is shared.
@Suite(.serialized) struct GifServiceLoadTests {
    private func service(key: String = "key", _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> GifService {
        StubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GifService(apiKey: key, locale: nil, session: URLSession(configuration: configuration))
    }

    private let okBody = Data(#"{"result":true,"data":{"data":[{"id":1,"file":{"sm":{"gif":{"url":"https://s.test/a.gif","width":1,"height":1}}}}],"current_page":3,"has_next":false}}"#.utf8)

    @Test func successDecodesThePage() async throws {
        let page = try await service { _ in (200, okBody) }.trending(page: 3)
        #expect(page.gifs.map(\.id) == ["1"] && page.page == 3 && !page.hasNext)
    }

    @Test(arguments: [400, 401, 429, 500, 503])
    func errorStatusThrowsWithTheStatus(status: Int) async {
        let service = service { _ in (status, okBody) }
        await #expect(throws: GifServiceError(status: status)) { try await service.search("cats", page: 1) }
    }

    @Test func undecodableBodyThrowsWithoutStatus() async {
        let service = service { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: GifServiceError(status: nil)) { try await service.trending(page: 1) }
    }

    @Test func resultFalseThrows() async {
        let service = service { _ in (200, Data(#"{"result":false,"data":{"data":[]}}"#.utf8)) }
        await #expect(throws: GifServiceError(status: nil)) { try await service.trending(page: 1) }
    }

    @Test func slashInTheKeyStaysInOnePathSegment() async throws {
        let seen = OSAllocatedBox()
        let service = service(key: "a/b?c") { request in
            seen.value = request.url?.path(percentEncoded: true)
            return (200, okBody)
        }
        _ = try await service.trending(page: 1)
        #expect(seen.value == "/api/v1/a%2Fb%3Fc/gifs/trending")
    }
}

final class OSAllocatedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
