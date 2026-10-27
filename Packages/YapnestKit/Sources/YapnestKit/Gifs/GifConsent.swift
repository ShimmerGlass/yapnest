import Foundation
import GRDB

/// The GIF service behind the account's consent. KLIPY is run from the
/// United States, which the EU has no adequacy decision for, so the first
/// request is only made once the user has agreed (GDPR Art. 49(1)(a)).
/// Every request asks the database, so nothing is left to remember.
public struct ConsentedGifService: Sendable {
    public struct ConsentRequired: Error, Sendable, Equatable {}

    private let service: GifService
    private let database: AppDatabase

    public init(service: GifService, database: AppDatabase) {
        self.service = service
        self.database = database
    }

    public func hasConsent() async -> Bool {
        let database = database
        return (try? await database.reader.read { try Self.consent($0) }) ?? false
    }

    /// Recorded per account and not synced: each install is asked once.
    public func agree() async throws {
        let database = database
        try await database.writer.write { try AppDatabase.setSetting($0, .gifConsent, "1") }
    }

    /// Turns GIFs off, the setting Settings has, and records no consent.
    public func turnOffGifs() async throws {
        let database = database
        try database.setFlag(.gifs, false)
    }

    public func trending(page: Int) async throws -> GifPage {
        try await requireConsent()
        return try await service.trending(page: page)
    }

    public func search(_ query: String, page: Int) async throws -> GifPage {
        try await requireConsent()
        return try await service.search(query, page: page)
    }

    private func requireConsent() async throws {
        guard await hasConsent() else { throw ConsentRequired() }
    }

    private static func consent(_ db: Database) throws -> Bool {
        try AppDatabase.flag(db, .gifConsent, default: false)
    }
}
