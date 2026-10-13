// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The active source's movies: category chips over a poster grid, with sorting and search.
struct MoviesView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    /// `nil` for all movies.
    @State private var categoryID: Int64?
    @State private var search = ""
    @AppStorage("movieSort") private var sort = MovieSort.added

    var body: some View {
        NavigationStack {
            Group {
                if let sourceID = model.activeSource?.id {
                    MovieGrid(sourceID: sourceID, categoryID: categoryID, search: search, sort: sort)
                        .safeAreaBar(edge: .top) {
                            if categories.count > 1 {
                                CategoryChips(categories: categories, selection: $categoryID)
                            }
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
                    if let categoryID, !categories.contains(where: { $0.id == categoryID }) { self.categoryID = nil }
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .onChange(of: model.activeSource?.id) { categoryID = nil }
    }
}

/// "All" and one chip per category, scrolling sideways.
private struct CategoryChips: View {
    let categories: [CategorySummary]
    @Binding var selection: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    chip("All", id: nil)
                    ForEach(categories) { summary in
                        chip(summary.category.name, id: summary.category.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            // A horizontal scroll view takes all the height it's offered: keep the bar to its chips.
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func chip(_ title: String, id: Int64?) -> some View {
        let button = Button(title) { selection = id }
            .controlSize(.small)
            .accessibilityAddTraits(selection == id ? .isSelected : [])
            .id(id)
        if selection == id {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// Posters in an adaptive grid. Only the posters on screen are built, and each image is downsampled.
private struct MovieGrid: View {
    let sourceID: Int64
    let categoryID: Int64?
    let search: String
    let sort: MovieSort

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var movies: [MovieSummary] = []
    @State private var hasLoaded = false

    var body: some View {
        let posterWidth: CGFloat = sizeClass == .compact ? 105 : 150
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(movies) { movie in
                    NavigationLink(value: movie) {
                        PosterCell(movie: movie, posterWidth: posterWidth * 1.4)
                    }
                    .buttonStyle(.plain)
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
                } else {
                    ContentUnavailableView("No Movies", systemImage: "film",
                                           description: Text("This source doesn't have any movies."))
                }
            }
        }
        .task(id: QueryKey(sourceID: sourceID, categoryID: categoryID, search: search, sort: sort)) {
            do {
                for try await movies in model.database.observeMovies(sourceID: sourceID, categoryID: categoryID,
                                                                     search: search, sort: sort) {
                    self.movies = movies
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
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
        var categoryID: Int64?
        var search: String
        var sort: MovieSort
    }
}

private struct PosterCell: View {
    let movie: MovieSummary
    let posterWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: movie.posterURL, title: movie.name, width: posterWidth)
                .overlay(alignment: .topTrailing) {
                    if let rating = movie.rating {
                        Label(rating.ratingText, systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(5)
                    }
                }
            Text(movie.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            if let year = movie.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    MoviesView()
        .environment(AppModel.preview())
}
