import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct GifFavoritesTests {
    private func gif(_ id: String) -> Gif {
        Gif(id: id, slug: "slug-\(id)", title: "Title \(id)",
            preview: Rendition(url: URL(string: "https://cdn.example/\(id)/sm.gif")!, width: 200, height: 150, size: 12_345),
            still: URL(string: "https://cdn.example/\(id)/sm.jpg"),
            shared: Rendition(url: URL(string: "https://cdn.example/\(id)/md.gif")!, width: 400, height: 300, size: 987_654))
    }

    @Test func addsNewestFirst() throws {
        let db = try AppDatabase.inMemory()
        #expect(db.gifFavorites().isEmpty)
        try db.addGifFavorite(gif("1"))
        try db.addGifFavorite(gif("2"))
        #expect(db.gifFavorites().map(\.id) == ["2", "1"])
    }

    @Test func readdingMovesToFrontWithoutDuplicate() throws {
        let db = try AppDatabase.inMemory()
        for id in ["1", "2", "3"] { try db.addGifFavorite(gif(id)) }
        try db.addGifFavorite(gif("1"))
        #expect(db.gifFavorites().map(\.id) == ["1", "3", "2"])
    }

    @Test func removes() throws {
        let db = try AppDatabase.inMemory()
        for id in ["1", "2", "3"] { try db.addGifFavorite(gif(id)) }
        try db.removeGifFavorite(id: "2")
        try db.removeGifFavorite(id: "missing")
        #expect(db.gifFavorites().map(\.id) == ["3", "1"])
    }

    @Test func capDropsTheOldest() throws {
        let db = try AppDatabase.inMemory()
        for index in 0..<(AppDatabase.gifFavoritesCapacity + 5) { try db.addGifFavorite(gif(String(index))) }
        let ids = db.gifFavorites().map(\.id)
        #expect(ids.count == 200)
        #expect(ids.first == "204")
        #expect(ids.last == "5")
    }

    @Test func roundTripKeepsEveryField() throws {
        let db = try AppDatabase.inMemory()
        let original = gif("7")
        try db.addGifFavorite(original)
        #expect(db.gifFavorites() == [original])
        var bare = gif("8")
        bare.still = nil
        bare.preview.size = nil
        try db.addGifFavorite(bare)
        #expect(db.gifFavorites().first == bare)
    }

    @Test func garbageReadsAsEmpty() throws {
        let db = try AppDatabase.inMemory()
        try db.setSetting(.gifFavorites, "not json {")
        #expect(db.gifFavorites().isEmpty)
        // A write after garbage starts over rather than failing.
        try db.addGifFavorite(gif("1"))
        #expect(db.gifFavorites().map(\.id) == ["1"])
    }

    @Test func observationEmitsAfterAChange() async throws {
        let db = try AppDatabase.inMemory()
        var values = db.observeGifFavorites().values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        #expect(try await values.next()?.isEmpty == true)
        try db.addGifFavorite(gif("1"))
        #expect(try await values.next()?.map(\.id) == ["1"])
    }
}
