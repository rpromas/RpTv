// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// A series' seasons and episodes, as the detail screen shows them.
public struct SeriesEpisodes: Sendable, Equatable {
    /// What the provider says about each season. Some seasons only exist through their episodes.
    public var seasons: [Season]
    /// Every episode, by season then number.
    public var episodes: [Episode]

    public init(seasons: [Season] = [], episodes: [Episode] = []) {
        self.seasons = seasons
        self.episodes = episodes
    }

    /// Every season number that has episodes or a description, in order.
    public var seasonNumbers: [Int] {
        Array(Set(episodes.map(\.season)).union(seasons.map(\.number))).sorted()
    }

    public func episodes(inSeason number: Int) -> [Episode] {
        episodes.filter { $0.season == number }
    }

    public func season(_ number: Int) -> Season? {
        seasons.first { $0.number == number }
    }

    /// The episode Play should start, given each episode's progress by `stableKey`: the one watched last if it's
    /// unfinished, else the one after it, else the first. `nil` when there are no episodes.
    public func upNext(progress: [String: PlaybackProgress]) -> Episode? {
        let latest = episodes
            .compactMap { episode in progress[episode.stableKey].map { (episode, $0) } }
            .max { $0.1.updatedAt < $1.1.updatedAt }
        guard let (episode, last) = latest else { return episodes.first }
        if last.resumePosition != nil || !last.isWatched { return episode }
        return self.episode(after: episode) ?? episode
    }

    /// The episode after `episode`, across seasons, or `nil` for the last one.
    public func episode(after episode: Episode) -> Episode? {
        guard let index = episodes.firstIndex(where: { $0.stableKey == episode.stableKey }),
              episodes.indices.contains(index + 1) else { return nil }
        return episodes[index + 1]
    }
}

// MARK: - Writes

extension AppDatabase {
    /// Stores what `get_series_info` returned: the series' details, and its seasons and episodes in place of the
    /// ones stored before. The series is found by `stableKey`, so a sync that ran meanwhile doesn't lose them.
    public func saveSeriesDetails(sourceID: Int64, stableKey: String, info: XtreamSeriesInfo, fetchedAt: Date = .now) async throws {
        try await writer.write { db in
            guard var series = try Series.filter(Column("sourceID") == sourceID && Column("stableKey") == stableKey).fetchOne(db)
            else { return }
            series.apply(info.details, fetchedAt: fetchedAt)
            try series.update(db)

            let ofSeries = Column("sourceID") == sourceID && Column("seriesKey") == stableKey
            try Season.filter(ofSeries).deleteAll(db)
            try Episode.filter(ofSeries).deleteAll(db)
            for season in info.seasons {
                try Season(sourceID: sourceID, seriesKey: stableKey, number: season.number, name: season.name,
                           posterURL: season.cover, overview: season.overview?.nonEmpty, airDate: season.airDate,
                           episodeCount: season.episodeCount).upsert(db)
            }
            for (index, episode) in info.episodes.enumerated() {
                var row = Episode(xtream: episode, sourceID: sourceID, seriesKey: stableKey, sortIndex: index)
                try row.insert(db)
            }
        }
    }
}

// MARK: - Reads

extension AppDatabase {
    /// Visible series categories of a source, in the user's order, each with its series count. Empty categories are
    /// skipped. Locked ones are listed, so the user can unlock them.
    public func observeSeriesCategories(sourceID: Int64) -> AsyncThrowingStream<[CategorySummary], Error> {
        observeCategories(sourceID: sourceID, kind: .series, itemTable: Series.databaseTableName)
    }

    /// Series of a source for a poster grid, optionally narrowed to one category and to names with words starting
    /// with each word of `search`. Series in hidden categories are left out unless a category is picked explicitly,
    /// and series in locked categories unless `includingLocked`.
    public func observeSeries(sourceID: Int64, categoryID: Int64?, search: String = "", sort: MovieSort = .added,
                              includingLocked: Bool = false) -> AsyncThrowingStream<[SeriesSummary], Error> {
        observe { db in
            try Self.seriesRequest(sourceID: sourceID, categoryID: categoryID, search: search, sort: sort,
                                   includingLocked: includingLocked).fetchAll(db)
        }
    }

    static func seriesRequest(sourceID: Int64, categoryID: Int64?, search: String, sort: MovieSort,
                              includingLocked: Bool = false) -> QueryInterfaceRequest<SeriesSummary> {
        var request = Series.filter(Column("sourceID") == sourceID)
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
            if let pattern = searchPattern(search) {
                request = request.filter(sql: "id IN (SELECT rowid FROM seriesSearch WHERE seriesSearch MATCH ?)", arguments: [pattern])
            } else {
                request = request.none()
            }
        }
        let sortIndex = Column("sortIndex")
        switch sort {
        case .added: request = request.order(Column("addedAt") == nil, Column("addedAt").desc, sortIndex)
        case .name: request = request.order(Column("name").collating(.nocase), sortIndex)
        case .rating: request = request.order(Column("rating") == nil, Column("rating").desc, sortIndex)
        }
        return request.select(SeriesSummary.columns).asRequest(of: SeriesSummary.self)
    }

    /// One series with its details, followed across resyncs by its `stableKey`. Yields `nil` if it goes away.
    public func observeSeries(sourceID: Int64, stableKey: String) -> AsyncThrowingStream<Series?, Error> {
        observe { db in try Self.fetchSeries(db, sourceID: sourceID, stableKey: stableKey) }
    }

    public func series(sourceID: Int64, stableKey: String) async throws -> Series? {
        try await reader.read { db in try Self.fetchSeries(db, sourceID: sourceID, stableKey: stableKey) }
    }

    public func seriesCount(sourceID: Int64) async throws -> Int {
        try await reader.read { db in try Series.filter(Column("sourceID") == sourceID).fetchCount(db) }
    }

    /// A series' seasons and episodes, kept up to date.
    public func observeEpisodes(sourceID: Int64, seriesKey: String) -> AsyncThrowingStream<SeriesEpisodes, Error> {
        observe { db in try Self.fetchEpisodes(db, sourceID: sourceID, seriesKey: seriesKey) }
    }

    public func episodes(sourceID: Int64, seriesKey: String) async throws -> SeriesEpisodes {
        try await reader.read { db in try Self.fetchEpisodes(db, sourceID: sourceID, seriesKey: seriesKey) }
    }

    public func episode(sourceID: Int64, stableKey: String) async throws -> Episode? {
        try await reader.read { db in
            try Episode.filter(Column("sourceID") == sourceID && Column("stableKey") == stableKey).fetchOne(db)
        }
    }

    private static func fetchSeries(_ db: Database, sourceID: Int64, stableKey: String) throws -> Series? {
        try Series.filter(Column("sourceID") == sourceID && Column("stableKey") == stableKey).fetchOne(db)
    }

    private static func fetchEpisodes(_ db: Database, sourceID: Int64, seriesKey: String) throws -> SeriesEpisodes {
        let ofSeries = Column("sourceID") == sourceID && Column("seriesKey") == seriesKey
        return SeriesEpisodes(
            seasons: try Season.filter(ofSeries).order(Column("number")).fetchAll(db),
            episodes: try Episode.filter(ofSeries).order(Column("sortIndex")).fetchAll(db))
    }
}

extension Series {
    /// Fills in the details from `get_series_info`, keeping what the catalog already had where they're empty.
    mutating func apply(_ details: XtreamMediaDetails?, fetchedAt: Date) {
        plot = details?.plot ?? plot
        cast = details?.cast ?? cast
        director = details?.director ?? director
        genre = details?.genre ?? genre
        backdropURL = details?.backdrops.first ?? backdropURL
        trailer = details?.youtubeTrailer ?? trailer
        posterURL = posterURL ?? details?.cover
        rating = rating ?? details?.rating
        year = year ?? Movie.year(inReleaseDate: details?.releaseDate)
        detailsFetchedAt = fetchedAt
    }

    /// Carries what was fetched for the same series over to its row from a fresh catalog.
    mutating func keepDetails(of cached: Series) {
        plot = plot ?? cached.plot
        cast = cast ?? cached.cast
        director = director ?? cached.director
        genre = genre ?? cached.genre
        backdropURL = backdropURL ?? cached.backdropURL
        trailer = trailer ?? cached.trailer
        posterURL = posterURL ?? cached.posterURL
        rating = rating ?? cached.rating
        year = year ?? cached.year
        detailsFetchedAt = cached.detailsFetchedAt
    }
}

extension Episode {
    init(xtream episode: XtreamEpisode, sourceID: Int64, seriesKey: String, sortIndex: Int) {
        // Titles are often "Show - S01E02 - Title": keep just the title, or nothing when that's all there is.
        let title: String
        if let parsed = EpisodeName(parsing: episode.title) {
            title = parsed.title ?? "Episode \(parsed.episode)"
        } else {
            title = episode.title
        }
        self.init(
            sourceID: sourceID,
            seriesKey: seriesKey,
            stableKey: "xtream-episode:\(episode.id)",
            season: episode.season ?? 1,
            number: episode.episodeNumber,
            title: title,
            plot: episode.plot,
            durationSeconds: episode.durationSeconds.flatMap { $0 > 0 ? $0 : nil },
            stillURL: episode.image,
            rating: episode.rating.flatMap { $0 > 0 ? $0 : nil },
            airDate: episode.releaseDate,
            containerExtension: episode.containerExtension,
            xtreamEpisodeID: episode.id,
            sortIndex: sortIndex
        )
    }
}
