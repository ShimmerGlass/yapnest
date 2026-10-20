import Foundation
import GRDB

extension AppDatabase {
    /// The most GIFs kept. A star is a deliberate act, so this is only a bound
    /// on the stored value, not something people should reach.
    static let gifFavoritesCapacity = 200

    /// The starred GIFs, newest first. Whole GIFs are stored, as KLIPY has no
    /// lookup by id that we use, so the grid draws without a request.
    func gifFavorites() -> [Gif] {
        let raw = try? setting(.gifFavorites)
        return Self.decodeGifFavorites(raw)
    }

    /// Stars a GIF, or moves it to the front if it already is. Read and
    /// written in one transaction so two writers can't lose each other's.
    public func addGifFavorite(_ gif: Gif) throws {
        try updateGifFavorites { favorites in
            favorites.removeAll { $0.id == gif.id }
            favorites.insert(gif, at: 0)
            if favorites.count > Self.gifFavoritesCapacity {
                favorites.removeLast(favorites.count - Self.gifFavoritesCapacity)
            }
        }
    }

    public func removeGifFavorite(id: String) throws {
        try updateGifFavorites { $0.removeAll { $0.id == id } }
    }

    public func observeGifFavorites() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[Gif]>>> {
        ValueObservation.tracking { db in
            Self.decodeGifFavorites(try Self.setting(db, .gifFavorites))
        }
        .removeDuplicates()
    }

    private func updateGifFavorites(_ change: (inout [Gif]) -> Void) throws {
        try updateJSONSetting(.gifFavorites, default: [Gif](), change)
    }

    /// An unreadable value reads as no favorites rather than failing the picker.
    private static func decodeGifFavorites(_ raw: String?) -> [Gif] {
        raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([Gif].self, from: $0) } ?? []
    }
}
