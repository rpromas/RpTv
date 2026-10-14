// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The active source's movies: list and category chips over a poster grid, with sorting and search.
struct MoviesView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    @State private var list = LibraryList.all
    @State private var search = ""
    @AppStorage("movieSort") private var sort = MovieSort.added

    var body: some View {
        NavigationStack {
            Group {
                if let sourceID = model.activeSource?.id {
                    Group {
                        if isLocked(list) {
                            LockedContentView()
                        } else {
                            MovieGrid(sourceID: sourceID, list: list, search: search, sort: sort)
                        }
                    }
                    .safeAreaBar(edge: .top) {
                        LibraryChips(categories: categories, selection: $list, identifierPrefix: "movie")
                    }
                } else {
                    ContentUnavailableView("No Source", systemImage: "film")
                }
            }
            .navigationTitle("Movies")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MovieSummary.self) { movie in
                MovieDetailView(summary: movie)
            }
            .toolbar {
                LibrarySwitcher()
                SourceToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            Text("Recently Added").tag(MovieSort.added)
                            Text("Name").tag(MovieSort.name)
                            Text("Rating").tag(MovieSort.rating)
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("movieSortMenu")
                }
            }
            .searchable(text: $search, prompt: "Search movies")
        }
        .task(id: model.activeSource?.id) {
            guard let sourceID = model.activeSource?.id else { return }
            do {
                for try await categories in model.database.observeMovieCategories(sourceID: sourceID) {
                    self.categories = categories
                    if case .category(let id) = list, !categories.contains(where: { $0.id == id }) { list = .all }
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .onChange(of: model.activeSource?.id) { list = .all }
        .onChange(of: list) { _, list in
            if isLocked(list) { Task { await model.unlockLockedContent() } }
        }
    }

    /// Whether `list` is a locked category that the PIN hasn't opened yet.
    private func isLocked(_ list: LibraryList) -> Bool {
        guard case .category(let id) = list, model.parental.isRestricted else { return false }
        return categories.first { $0.category.id == id }?.category.isLocked ?? false
    }
}

/// Posters in an adaptive grid. Only the posters on screen are built, and each image is downsampled.
private struct MovieGrid: View {
    let sourceID: Int64
    let list: LibraryList
    let search: String
    let sort: MovieSort

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var movies: [MovieSummary] = []
    @State private var hasLoaded = false

    var body: some View {
        let posterWidth: CGFloat = sizeClass == .compact ? 105 : 150
        ScrollView {
            if list == .all, search.isEmpty {
                ContinueWatchingShelf(kind: .movies, sourceID: sourceID)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(movies) { movie in
                    NavigationLink(value: movie) {
                        PosterCell(title: movie.name, posterURL: movie.posterURL, rating: movie.rating, year: movie.year,
                                   posterWidth: posterWidth * 1.4,
                                   isFavorite: list != .favorites && model.isFavorite(movie.itemKey))
                    }
                    .buttonStyle(.plain)
                    .favoriteActions(for: movie.itemKey)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await refresh() }
        .overlay {
            if hasLoaded, movies.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if list == .favorites {
                    ContentUnavailableView("No Favorite Movies", systemImage: "star",
                                           description: Text("Touch and hold a poster to add it to your favorites."))
                } else if list == .recent {
                    ContentUnavailableView("Nothing Watched Yet", systemImage: "clock",
                                           description: Text("Movies you watch appear here."))
                } else {
                    ContentUnavailableView("No Movies", systemImage: "film",
                                           description: Text("This source doesn't have any movies."))
                }
            }
        }
        .task(id: QueryKey(sourceID: sourceID, list: list, search: search, sort: sort, includesLocked: model.includesLocked)) {
            do {
                for try await movies in observeMovies() {
                    self.movies = movies
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    /// Favorites keep the user's order and recents the latest first; the few they hold are searched here.
    private func observeMovies() -> any AsyncSequence<[MovieSummary], any Error> {
        let database = model.database
        let search = search
        let includesLocked = model.includesLocked
        let filter: @Sendable ([MovieSummary]) -> [MovieSummary] = { movies in
            search.isEmpty ? movies : movies.filter { $0.name.localizedStandardContains(search) }
        }
        switch list {
        case .all:
            return database.observeMovies(sourceID: sourceID, categoryID: nil, search: search, sort: sort, includingLocked: includesLocked)
        case .category(let id):
            return database.observeMovies(sourceID: sourceID, categoryID: id, search: search, sort: sort, includingLocked: includesLocked)
        case .favorites: return database.observeFavoriteMovies(sourceID: sourceID, includingLocked: includesLocked).map(filter)
        case .recent: return database.observeRecentMovies(sourceID: sourceID, includingLocked: includesLocked).map(filter)
        }
    }

    private func refresh() async {
        guard let source = model.sources.first(where: { $0.id == sourceID }) else { return }
        do {
            try await model.sync(source)
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private struct QueryKey: Equatable {
        var sourceID: Int64
        var list: LibraryList
        var search: String
        var sort: MovieSort
        var includesLocked: Bool
    }
}

#Preview {
    MoviesView()
        .environment(AppModel.preview())
}
