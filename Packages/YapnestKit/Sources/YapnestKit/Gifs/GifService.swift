import Foundation
import GRDB

public struct GifServiceError: Error, Sendable, Equatable {
    /// The HTTP status, when the server answered at all.
    public var status: Int?

    public init(status: Int? = nil) {
        self.status = status
    }
}

/// One size of a GIF.
public struct Rendition: Sendable, Equatable, Codable {
    public var url: URL
    public var width: Double
    public var height: Double
    public var size: Int64?

    public init(url: URL, width: Double, height: Double, size: Int64? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.size = size
    }
}

public struct Gif: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var slug: String
    public var title: String
    /// What the picker's grid shows.
    public var preview: Rendition
    /// A still frame to hold the place while the preview loads.
    public var still: URL?
    /// What gets sent: big enough to look good, small enough to upload quickly.
    public var shared: Rendition

    public init(id: String, slug: String, title: String, preview: Rendition, still: URL? = nil, shared: Rendition) {
        self.id = id
        self.slug = slug
        self.title = title
        self.preview = preview
        self.still = still
        self.shared = shared
    }
}

public struct GifPage: Sendable, Equatable {
    public var gifs: [Gif]
    public var hasNext: Bool
    public var page: Int
}

/// A client for KLIPY's GIF search. It sends no customer id, so KLIPY can't
/// tie searches to a person beyond the connection itself.
public struct GifService: Sendable {
    static let baseURL = URL(string: "https://api.klipy.com")!
    static let perPage = 24
    /// Above this the medium size is too slow to upload, so the small one is sent.
    static let maxSharedSize: Int64 = 3_000_000

    let apiKey: String
    let locale: String?
    let session: URLSession

    /// For everything fetched from KLIPY and its CDN: no cookies and no cache,
    /// so nothing ties one request to the next beyond the connection.
    public static let privateSession = URLSession.privateEphemeral()

    public init(apiKey: String, locale: String?, session: URLSession = GifService.privateSession) {
        self.apiKey = apiKey
        self.locale = locale
        self.session = session
    }

    public func trending(page: Int) async throws -> GifPage {
        try await load(request(query: nil, page: page), page: page)
    }

    public func search(_ query: String, page: Int) async throws -> GifPage {
        try await load(request(query: query, page: page), page: page)
    }

    func request(query: String?, page: Int) -> URLRequest {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A key containing a slash must not change the path.
        var segment = CharacterSet.urlPathAllowed
        segment.remove("/")
        let key = apiKey.addingPercentEncoding(withAllowedCharacters: segment) ?? apiKey
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.baseURL.host
        components.percentEncodedPath = "/api/v1/\(key)/gifs/\(trimmed.isEmpty ? "trending" : "search")"
        var items = [URLQueryItem(name: "page", value: String(max(page, 1))),
                     URLQueryItem(name: "per_page", value: String(Self.perPage))]
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        if let locale { items.append(URLQueryItem(name: "locale", value: locale)) }
        items.append(URLQueryItem(name: "content_filter", value: "medium"))
        items.append(URLQueryItem(name: "format_filter", value: "gif,jpg"))
        components.queryItems = items
        // URLComponents leaves "+" and "&" alone in values, which servers read as a space or a separator.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=;")
        components.percentEncodedQuery = items.map {
            "\($0.name)=\($0.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return URLRequest(url: components.url!)
    }

    /// The most a GIF to send may be, the same as a picture from a contact
    /// downloads on its own. KLIPY says how big its files are, but a CDN's
    /// answer is its own to give.
    public static let maxDownloadSize = 15 * 1024 * 1024

    public enum DownloadError: Error, Sendable, Equatable {
        case notHTTPS
        case tooLarge
        case status(Int)
    }

    /// The GIF at `url`, over HTTPS only, never from a local address and
    /// never more than `maxDownloadSize`.
    public static func download(_ url: URL, session: URLSession = privateSession) async throws -> Data {
        try await download(url, session: session, policy: DownloadPolicy(allowsInsecure: false))
    }

    static func download(_ url: URL, session: URLSession, policy: DownloadPolicy, limit: Int = maxDownloadSize) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw DownloadError.notHTTPS }
        try await policy.check(url)
        // The delegate checks every redirect like the first request.
        let delegate = ProgressDelegate(limit: Int64(limit), policy: policy) { _ in }
        do {
            let (data, _) = try await session.cappedDownload(URLRequest(url: url), delegate: delegate, limit: Int64(limit)) { response in
                guard response.url?.scheme?.lowercased() == "https" else { throw DownloadError.notHTTPS }
            }
            return data
        } catch is TooLarge {
            throw DownloadError.tooLarge
        } catch let error as HTTPStatusError {
            throw DownloadError.status(error.status)
        }
    }

    private func load(_ request: URLRequest, page: Int) async throws -> GifPage {
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw GifServiceError(status: status)
        }
        return try Self.decode(data, page: page)
    }

    static func decode(_ data: Data, page: Int) throws -> GifPage {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.result else {
            throw GifServiceError()
        }
        let gifs = envelope.data?.data.compactMap { $0.value?.gif } ?? []
        return GifPage(gifs: gifs, hasNext: envelope.data?.hasNext ?? false, page: envelope.data?.currentPage ?? page)
    }
}

// MARK: - Decoding

/// Decoding that never fails, so one odd item doesn't lose the page.
private struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private struct Envelope: Decodable {
    var result: Bool
    var data: Page?

    struct Page: Decodable {
        var data: [Lenient<Item>]
        var currentPage: Int?
        var hasNext: Bool?

        enum CodingKeys: String, CodingKey {
            case data
            case currentPage = "current_page"
            case hasNext = "has_next"
        }
    }

    struct File: Decodable {
        var url: URL
        var width: Double
        var height: Double
        var size: Double?
    }

    struct Size: Decodable {
        var gif: File?
        var jpg: File?
    }

    struct Item: Decodable {
        var id: String
        var slug: String?
        var title: String?
        var type: String?
        var file: [String: Lenient<Size>]?

        enum CodingKeys: String, CodingKey { case id, slug, title, type, file }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decode(Int64.self, forKey: .id) {
                id = String(number)
            } else {
                id = try container.decode(String.self, forKey: .id)
            }
            slug = try? container.decode(String.self, forKey: .slug)
            title = try? container.decode(String.self, forKey: .title)
            type = try? container.decode(String.self, forKey: .type)
            file = try? container.decode([String: Lenient<Size>].self, forKey: .file)
        }

        var gif: Gif? {
            guard type != "ad" else { return nil }
            func gif(_ size: String) -> Rendition? {
                file?[size]?.value?.gif.map { Rendition(url: $0.url, width: $0.width, height: $0.height, size: $0.size.flatMap { $0.isFinite && $0 >= 0 && $0 < 9.2e18 ? Int64($0) : nil }) }
            }
            guard let preview = gif("sm") ?? gif("xs") ?? gif("md") else { return nil }
            // The medium size if it's small enough to upload quickly, else the
            // small one, or the extra small. An oversized medium still beats
            // the larger hd.
            let medium = gif("md")
            let fitting = medium.flatMap { ($0.size ?? 0) <= GifService.maxSharedSize ? $0 : nil }
            guard let shared = fitting ?? gif("sm") ?? gif("xs") ?? medium ?? gif("hd") else { return nil }
            let still = (file?["sm"]?.value?.jpg ?? file?["xs"]?.value?.jpg)?.url
            return Gif(id: id, slug: slug ?? "", title: title ?? "", preview: preview, still: still, shared: shared)
        }
    }
}
