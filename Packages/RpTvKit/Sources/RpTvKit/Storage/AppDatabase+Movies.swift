// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

// MARK: - Writes

extension AppDatabase {
    /// Stores the details of a movie fetched from the provider. The movie is found by `stableKey`, so a sync that
    /// ran meanwhile doesn't lose them.
    public func saveMovieDetails(sourceID: Int64, stableKey: String, details: XtreamVODInfo, fetchedAt: Date = .now) async throws {
        try await writer.write { db in
            guard var movie = try Movie.filter(Column("sourceID") == sourceID && Column("stableKey") == stableKey).fetchOne(db)
            else { return }
            movie.apply(details, fetchedAt: fetchedAt)
            try movie.update(db)
        }
    }
}

// MARK: - Reads

extension AppDatabase {
    /// Visible movie categories of a source, in the user's order, each with its movie count. Empty categories are
    /// skipped. Locked ones are listed, so the user can unlock them.
    public func observeMovieCategories(sourceID: Int64) -> AsyncThrowingStream<[CategorySummary], Error> {
        observeCategories(sourceID: sourceID, kind: .movie, itemTable: Movie.databaseTableName)
    }

    /// Movies of a source for a poster grid, optionally narrowed to one category and to names with words starting
    /// with each word of `search` (ignoring case and diacritics).
    /// Movies in hidden categories are left out unless a category is picked explicitly, and movies in locked
    /// categories unless `includingLocked`.
    public func observeMovies(sourceID: Int64, categoryID: Int64?, search: String = "", sort: MovieSort = .added,
                              includingLocked: Bool = false) -> AsyncThrowingStream<[MovieSummary], Error> {
        observe { db in
            try Self.movieRequest(sourceID: sourceID, categoryID: categoryID, search: search, sort: sort,
                                  includingLocked: includingLocked).fetchAll(db)
        }
    }

    static func movieRequest(sourceID: Int64, categoryID: Int64?, search: String, sort: MovieSort,
                             includingLocked: Bool = false) -> QueryInterfaceRequest<MovieSummary> {
        var request = Movie.filter(Column("sourceID") == sourceID)
        if let categoryID {
            request = request.filter(Column("categoryID") == categoryID)
        } else {
            let hidden = MediaCategory.filter(Column("isHidden") == true).select(Column("id"))
            request = request.filter(Column("categoryID") == nil || !hidden.contains(Column("categoryID")))
        }
        if !includingLocked {
            request = request.filter(Column("categoryID") == nil || !lockedCategoryIDs.contains(Column("categoryID")))
        }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Text with no words in it, like "%", matches nothing.
            if let pattern = searchPattern(search) {
                request = request.filter(sql: "id IN (SELECT rowid FROM movieSearch WHERE movieSearch MATCH ?)", arguments: [pattern])
            } else {
                request = request.none()
            }
        }
        let sortIndex = Column("sortIndex")
        // Movies without a date or rating go last.
        switch sort {
        case .added: request = request.order(Column("addedAt") == nil, Column("addedAt").desc, sortIndex)
        case .name: request = request.order(Column("name").collating(.nocase), sortIndex)
        case .rating: request = request.order(Column("rating") == nil, Column("rating").desc, sortIndex)
        }
        return request.select(MovieSummary.columns).asRequest(of: MovieSummary.self)
    }

    /// One movie with all its details, followed across resyncs by its `stableKey`. Yields `nil` if it goes away.
    public func observeMovie(sourceID: Int64, stableKey: String) -> AsyncThrowingStream<Movie?, Error> {
        observe { db in try Self.fetchMovie(db, sourceID: sourceID, stableKey: stableKey) }
    }

    public func movie(sourceID: Int64, stableKey: String) async throws -> Movie? {
        try await reader.read { db in try Self.fetchMovie(db, sourceID: sourceID, stableKey: stableKey) }
    }

    public func movieCount(sourceID: Int64) async throws -> Int {
        try await reader.read { db in try Movie.filter(Column("sourceID") == sourceID).fetchCount(db) }
    }

    private static func fetchMovie(_ db: Database, sourceID: Int64, stableKey: String) throws -> Movie? {
        try Movie.filter(Column("sourceID") == sourceID && Column("stableKey") == stableKey).fetchOne(db)
    }
}

extension Movie {
    /// Fills in the details from `get_vod_info`, keeping what the catalog already had where the details are empty.
    mutating func apply(_ info: XtreamVODInfo, fetchedAt: Date) {
        let details = info.details
        plot = details?.plot ?? plot
        cast = details?.cast ?? cast
        director = details?.director ?? director
        genre = details?.genre ?? genre
        durationSeconds = details?.durationSeconds ?? durationSeconds
        backdropURL = details?.backdrops.first ?? backdropURL
        trailer = details?.youtubeTrailer ?? trailer
        posterURL = posterURL ?? details?.cover
        rating = rating ?? details?.rating
        year = year ?? Self.year(inReleaseDate: details?.releaseDate)
        containerExtension = info.containerExtension ?? containerExtension
        detailsFetchedAt = fetchedAt
    }

    /// Carries cached details over to the same movie from a fresh catalog.
    mutating func keepDetails(of cached: Movie) {
        plot = cached.plot
        cast = cached.cast
        director = cached.director
        genre = cached.genre
        durationSeconds = cached.durationSeconds
        backdropURL = cached.backdropURL
        trailer = cached.trailer
        posterURL = posterURL ?? cached.posterURL
        rating = rating ?? cached.rating
        year = year ?? cached.year
        detailsFetchedAt = cached.detailsFetchedAt
    }
}
