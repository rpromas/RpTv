// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The active source's series: list and category chips over a poster grid, with sorting and search, and the
/// series to continue at the top.
struct SeriesView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    @State private var list = LibraryList.all
    @State private var search = ""
    @AppStorage("seriesSort") private var sort = MovieSort.added

    var body: some View {
        NavigationStack {
            Group {
                if let sourceID = model.activeSource?.id {
                    Group {
                        if isLocked(list) {
                            LockedContentView()
                        } else {
                            SeriesGrid(sourceID: sourceID, list: list, search: search, sort: sort)
                        }
                    }
                    .safeAreaBar(edge: .top) {
                        LibraryChips(categories: categories, selection: $list, identifierPrefix: "series")
                    }
                } else {
                    ContentUnavailableView("No Source", systemImage: "tv")
                }
            }
            .navigationTitle("Series")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SeriesSummary.self) { series in
                SeriesDetailView(summary: series)
            }
            .toolbar {
                LibrarySwitcher()
                SourceToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            Text("Recently Updated").tag(MovieSort.added)
                            Text("Name").tag(MovieSort.name)
                            Text("Rating").tag(MovieSort.rating)
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("seriesSortMenu")
                }
            }
            .searchable(text: $search, prompt: "Search series")
        }
        .task(id: model.activeSource?.id) {
            guard let sourceID = model.activeSource?.id else { return }
            do {
                for try await categories in model.database.observeSeriesCategories(sourceID: sourceID) {
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
private struct SeriesGrid: View {
    let sourceID: Int64
    let list: LibraryList
    let search: String
    let sort: MovieSort

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var series: [SeriesSummary] = []
    @State private var hasLoaded = false

    var body: some View {
        let posterWidth: CGFloat = sizeClass == .compact ? 105 : 150
        ScrollView {
            if list == .all, search.isEmpty {
                ContinueWatchingShelf(kind: .series, sourceID: sourceID)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(series) { series in
                    NavigationLink(value: series) {
                        PosterCell(title: series.name, posterURL: series.posterURL, rating: series.rating, year: series.year,
                                   posterWidth: posterWidth * 1.4,
                                   isFavorite: list != .favorites && model.isFavorite(series.itemKey))
                    }
                    .buttonStyle(.plain)
                    .favoriteActions(for: series.itemKey)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await refresh() }
        .overlay {
            if hasLoaded, series.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if list == .favorites {
                    ContentUnavailableView("No Favorite Series", systemImage: "star",
                                           description: Text("Touch and hold a poster to add it to your favorites."))
                } else if list == .recent {
                    ContentUnavailableView("Nothing Watched Yet", systemImage: "clock",
                                           description: Text("Series you watch appear here."))
                } else {
                    ContentUnavailableView("No Series", systemImage: "tv",
                                           description: Text("This source doesn't have any series."))
                }
            }
        }
        .task(id: QueryKey(sourceID: sourceID, list: list, search: search, sort: sort, includesLocked: model.includesLocked)) {
            do {
                for try await series in observeSeries() {
                    self.series = series
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    /// Favorites keep the user's order and recents the latest first; the few they hold are searched here.
    private func observeSeries() -> any AsyncSequence<[SeriesSummary], any Error> {
        let database = model.database
        let search = search
        let includesLocked = model.includesLocked
        let filter: @Sendable ([SeriesSummary]) -> [SeriesSummary] = { series in
            search.isEmpty ? series : series.filter { $0.name.localizedStandardContains(search) }
        }
        switch list {
        case .all:
            return database.observeSeries(sourceID: sourceID, categoryID: nil, search: search, sort: sort, includingLocked: includesLocked)
        case .category(let id):
            return database.observeSeries(sourceID: sourceID, categoryID: id, search: search, sort: sort, includingLocked: includesLocked)
        case .favorites: return database.observeFavoriteSeries(sourceID: sourceID, includingLocked: includesLocked).map(filter)
        case .recent: return database.observeRecentSeries(sourceID: sourceID, includingLocked: includesLocked).map(filter)
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
    SeriesView()
        .environment(AppModel.preview())
}
