import SwiftUI
import YapnestKit

/// Trending, searched and favorite GIFs, in a waterfall grid. Choosing one
/// hands it back; the caller downloads it and stages it in the composer.
struct GifPicker: View {
    /// The account's, where favorites are kept.
    let database: AppDatabase
    let onPick: (Gif) -> Void

    private enum Source: String { case trending, favorites }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var service = Klipy.service()
    /// Whether the user has agreed to KLIPY: nil until the database answers.
    /// Nothing goes to KLIPY, previews included, unless it's true.
    @State private var consent: Bool?
    @State private var isAgreeing = false
    @State private var consentError: String?
    @State private var query = ""
    @State private var gifs: [Gif] = []
    @State private var seen: Set<String> = []
    @State private var page = 0
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var error: String?
    /// The query `gifs` are the results of, so coming back from Favorites keeps them.
    @State private var loadedQuery: String?
    @State private var nextPageError = false
    @State private var isLoadingMore = false
    @State private var moreTask: Task<Void, Never>?
    /// Bumped when a new search's results land, to scroll back to the top.
    @State private var resultsGeneration = 0
    @State private var favorites: [Gif] = []
    @State private var favoriteError: String?
    /// Which list shows when the search field is empty. Remembered, as it's
    /// the viewer's habit and not part of any chat.
    @AppStorage("gifPickerSource") private var source = Source.trending

    private struct LoadKey: Hashable {
        let query: String
        let favorites: Bool
        let consented: Bool
    }

    private var gate: ConsentedGifService? {
        service.map { ConsentedGifService(service: $0, database: database) }
    }

    private var columnCount: Int { sizeClass == .compact ? 2 : 3 }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }
    /// Searching always asks KLIPY, so it leaves the favorites aside.
    private var showsFavorites: Bool { !isSearching && source == .favorites }

    var body: some View {
        NavigationStack {
            Group {
                if consent == true {
                    browser
                } else if consent == false {
                    consentNotice
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
            }
            .task { consent = await gate?.hasConsent() ?? false }
            .task {
                await database.forEachValue(of: database.observeGifFavorites(), "GIF favorites") { favorites = $0 }
            }
            .errorAlert("Couldn't Update Favorites", $favoriteError)
            .errorAlert("Couldn't Save Your Choice", $consentError)
        }
    }

    /// Asked once, before the first request: KLIPY is a company in the United
    /// States, which the EU has no adequacy decision for.
    private var consentNotice: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("GIFs from KLIPY")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("GIFs come from KLIPY, a company in the United States. KLIPY sees what you search, your region and your IP address. The United States may not protect this data the way the EU does.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 8) {
                Button {
                    agree()
                } label: {
                    ZStack {
                        Text("Accept").opacity(isAgreeing ? 0 : 1)
                        if isAgreeing { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAgreeing)
                Button("Turn Off GIFs", role: .destructive) { turnOff() }
                    .disabled(isAgreeing)
                Text("You can turn GIFs back on in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    private func turnOff() {
        guard let gate, !isAgreeing else { return }
        isAgreeing = true
        Task {
            defer { isAgreeing = false }
            do {
                try await gate.turnOffGifs()
                dismiss()
            } catch {
                consentError = error.localizedDescription
            }
        }
    }

    private func agree() {
        guard let gate, !isAgreeing else { return }
        isAgreeing = true
        Task {
            defer { isAgreeing = false }
            do {
                try await gate.agree()
                consent = true
            } catch {
                consentError = error.localizedDescription
            }
        }
    }

    private var browser: some View {
        ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if !isSearching {
                            Picker("Show", selection: $source) {
                                Text("Trending").tag(Source.trending)
                                Text("Favorites").tag(Source.favorites)
                            }
                            .pickerStyle(.segmented)
                        }
                        if showsFavorites { favoritesContent } else { content }
                    }
                    .padding(.horizontal, 8)
                    .id("top")
                    footer
                }
                // Shown over the old grid while a new search loads, which
                // stays until its results replace it. An overlay, so it
                // neither moves the grid nor scrolls out of view.
                .overlay(alignment: .top) {
                    if isLoading && !gifs.isEmpty && !showsFavorites {
                        ProgressView()
                            .padding(8)
                            .background(.regularMaterial, in: .capsule)
                            .padding(.top, 8)
                    }
                }
                .onChange(of: resultsGeneration) {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search KLIPY"))
            .autocorrectionDisabled()
            // Waits for typing to stop, and a newer query cancels this one,
            // request included.
            // Trending only loads while it shows, so the key has the source too.
            .task(id: LoadKey(query: query, favorites: showsFavorites, consented: consent == true)) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if let error, gifs.isEmpty {
            VStack(spacing: 12) {
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await reload(debounce: false) } }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else if isLoading && gifs.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else if gifs.isEmpty {
            Text("No GIFs found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else {
            grid(gifs, paginates: true)
        }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if favorites.isEmpty {
            Text(Platform.isMac
                ? "Right-click a GIF to add it to your favorites."
                : "Touch and hold a GIF to add it to your favorites.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else {
            grid(favorites, paginates: false)
        }
    }

    /// Favorites never paginate, so only the loaded list asks for more.
    private func grid(_ shown: [Gif], paginates: Bool) -> some View {
        let columns = Self.columns(of: shown, count: columnCount)
        let favoriteIds = Set(favorites.map(\.id))
        return HStack(alignment: .top, spacing: 6) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(spacing: 6) {
                    ForEach(columns[index]) { gif in
                        GifTile(gif: gif, isFavorite: favoriteIds.contains(gif.id)) {
                            dismiss()
                            onPick(gif)
                        } onToggleFavorite: {
                            toggleFavorite(gif, isFavorite: favoriteIds.contains(gif.id))
                        }
                        .onAppear { if paginates, gif.id == nearEnd { loadMore() } }
                    }
                }
            }
        }
    }

    private func toggleFavorite(_ gif: Gif, isFavorite: Bool) {
        Task {
            do {
                let database = database
                try await offMain {
                    if isFavorite { try database.removeGifFavorite(id: gif.id) } else { try database.addGifFavorite(gif) }
                }
            } catch {
                favoriteError = error.localizedDescription
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            // These belong to the trending list, not to favorites.
            if !showsFavorites {
                if nextPageError {
                    Button("Couldn't load more · Retry") { loadMore() }
                        .font(.footnote)
                } else if isLoadingMore {
                    ProgressView()
                }
            }
            Text("Powered by KLIPY")
                .font(.footnote.weight(.semibold))
            Text("Searches go to KLIPY.")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// The tile that starts loading the next page once it's drawn, a few
    /// from the end so the page is there before the user gets to it.
    private var nearEnd: String? {
        guard hasNext, !gifs.isEmpty else { return nil }
        return gifs[max(0, gifs.count - 6)].id
    }

    /// Each GIF goes in the shortest column so far. It only looks at the GIFs
    /// before it, so appending a page never moves what's shown.
    static func columns(of gifs: [Gif], count: Int) -> [[Gif]] {
        var columns = Array(repeating: [Gif](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for gif in gifs {
            let index = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[index].append(gif)
            heights[index] += gif.preview.width > 0 ? gif.preview.height / gif.preview.width : 1
        }
        return columns
    }

    // MARK: Loading

    private func reload(debounce: Bool = true) async {
        moreTask?.cancel()
        moreTask = nil
        guard let service = gate, consent == true, !showsFavorites else { return }
        let text = trimmedQuery
        // Back from Favorites, the pages already loaded are still right. A
        // failed load, and so Retry, has no loaded query and goes on.
        if loadedQuery == text, error == nil {
            isLoadingMore = false
            return
        }
        if debounce, !text.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        isLoading = true
        isLoadingMore = false
        nextPageError = false
        defer { isLoading = false }
        do {
            let result = try await fetch(service, text, page: 1)
            if Task.isCancelled { return }
            var ids: Set<String> = []
            gifs = result.gifs.filter { ids.insert($0.id).inserted }
            seen = ids
            resultsGeneration += 1
            page = result.page
            hasNext = result.hasNext
            error = nil
            loadedQuery = text
        } catch {
            if Task.isCancelled { return }
            self.loadedQuery = nil
            self.gifs = []
            self.seen = []
            self.hasNext = false
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard let service = gate, consent == true, hasNext, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        nextPageError = false
        let text = trimmedQuery
        let next = page + 1
        moreTask = Task {
            defer { if !Task.isCancelled { isLoadingMore = false } }
            do {
                let result = try await fetch(service, text, page: next)
                // A newer query replaced the list while this was loading.
                if Task.isCancelled { return }
                let fresh = result.gifs.filter { seen.insert($0.id).inserted }
                gifs += fresh
                page = result.page
                hasNext = result.hasNext && !result.gifs.isEmpty
            } catch {
                if Task.isCancelled { return }
                nextPageError = true
            }
        }
    }

    private func fetch(_ service: ConsentedGifService, _ text: String, page: Int) async throws -> GifPage {
        text.isEmpty ? try await service.trending(page: page) : try await service.search(text, page: page)
    }
}

/// One GIF in the grid, in the shape its preview announces.
private struct GifTile: View {
    let gif: Gif
    let isFavorite: Bool
    let onTap: () -> Void
    let onToggleFavorite: () -> Void
    @State private var data: Data?

    var body: some View {
        let rendition = gif.preview
        let ratio = rendition.width > 0 && rendition.height > 0 ? rendition.width / rendition.height : 1
        Button(action: onTap) {
            Color(.tertiarySystemFill)
                .aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    if let data {
                        AnimatedImageView(data: data)
                    } else if let still = gif.still {
                        GifStill(url: still)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // A shadow, not a backdrop, so it reads over light and dark GIFs alike.
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onToggleFavorite) {
                if isFavorite {
                    Label("Remove from Favorites", systemImage: "star.slash")
                } else {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
        }
        .accessibilityValue(isFavorite ? "Favorite" : "")
        .accessibilityLabel(gif.title.isEmpty ? "GIF" : gif.title)
        .task(id: rendition.url) {
            data = await GifPreviewCache.data(for: rendition.url)
        }
    }
}

/// The still shown while a preview loads. Fetched like the previews, as
/// `AsyncImage` would use the shared session, which keeps cookies.
private struct GifStill: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let data = await GifPreviewCache.data(for: url)
            // The task is cancelled when the URL changes, and a late answer
            // for the old one must not replace the new one's.
            guard !Task.isCancelled else { return }
            guard let data else {
                image = nil
                return
            }
            // Decoded here rather than when first drawn, which would be on
            // the main thread.
            let decoded = await offMain { UIImage(data: data)?.preparingForDisplay() }
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

/// Preview GIFs, kept by size so scrolling back doesn't fetch them again.
@MainActor
enum GifPreviewCache {
    private static let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        // About 30 MB.
        cache.totalCostLimit = 30_000_000
        return cache
    }()

    static func data(for url: URL) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        guard let (data, response) = try? await GifService.privateSession.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}
