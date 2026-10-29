import Foundation

extension URLSession {
    /// Downloads `request` to a temporary file and reads it, never taking more
    /// than `limit` bytes. The delegate cancels the transfer once the server
    /// says it is over, so a file is also checked after it arrived, as a
    /// server may not say. `inspect` sees the response before its status does.
    func cappedDownload(
        _ request: URLRequest, delegate: ProgressDelegate, limit: Int64,
        inspect: (HTTPURLResponse) throws -> Void = { _ in },
    ) async throws -> (Data, HTTPURLResponse) {
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await download(for: request, delegate: delegate)
        } catch {
            if let size = delegate.exceededSize { throw TooLarge(size: size) }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try inspect(http)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= limit else { throw TooLarge(size: Int64(data.count)) }
        return (data, http)
    }
}
