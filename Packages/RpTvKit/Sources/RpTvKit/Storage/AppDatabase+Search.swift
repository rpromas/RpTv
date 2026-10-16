// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// What a search across all sources found, by kind.
public struct SearchResults: Sendable, Equatable {
    public struct ChannelHit: Sendable, Hashable, Identifiable {
        public var channel: Channel
        public var sourceName: String

        public var id: Int64? { channel.id }
    }

    public struct MovieHit: Sendable, Hashable, Identifiable {
        public var movie: MovieSummary
        public var sourceName: String

        public var id: Int64 { movie.id }
    }

    public struct SeriesHit: Sendable, Hashable, Identifiable {
        public var series: SeriesSummary
        public var sourceName: String

        public var id: Int64 { series.id }
    }

    public struct ProgrammeHit: Sendable, Hashable, Identifiable {
        public var programme: Programme
        /// The channel the programme is on.
        public var channel: Channel
        public var sourceName: String

        public var id: Int64? { programme.id }
    }

    public var channels: [ChannelHit] = []
    public var movies: [MovieHit] = []
    public var series: [SeriesHit] = []
    /// Programmes on air or still to come, the soonest first.
    public var programmes: [ProgrammeHit] = []

    public init(channels: [ChannelHit] = [], movies: [MovieHit] = [], series: [SeriesHit] = [], programmes: [ProgrammeHit] = []) {
        self.channels = channels
        self.movies = movies
        self.series = series
        self.programmes = programmes
    }

    public var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty && programmes.isEmpty }
}

extension AppDatabase {
    /// Searches every source for channels, movies, series and programmes by word prefixes, ignoring case and
    /// diacritics: "spo new" finds "Sports News", "cafe" finds "Café".
    ///
    /// Hidden categories are left out, locked ones unless `includingLocked`. Returns at most `limit` of each
    /// kind, best matches first.
    public func observeSearch(_ text: String, now: Date = .now, limit: Int = 50,
                              includingLocked: Bool = false) -> AsyncThrowingStream<SearchResults, Error> {
        let pattern = Self.searchPattern(text)
        return observe { db in
            guard let pattern else { return SearchResults() }
            return try Self.search(db, pattern: pattern, now: now, limit: limit, includingLocked: includingLocked)
        }
    }

    /// One-off ``observeSearch(_:now:limit:includingLocked:)``.
    public func search(_ text: String, now: Date = .now, limit: Int = 50, includingLocked: Bool = false) async throws -> SearchResults {
        guard let pattern = Self.searchPattern(text) else { return SearchResults() }
        return try await reader.read { db in
            try Self.search(db, pattern: pattern, now: now, limit: limit, includingLocked: includingLocked)
        }
    }

    /// Every word of `text` as a prefix, or `nil` when there's nothing to search for.
    static func searchPattern(_ text: String) -> FTS5Pattern? {
        FTS5Pattern(matchingAllPrefixesIn: text)
    }

    private static func search(_ db: Database, pattern: FTS5Pattern, now: Date, limit: Int, includingLocked: Bool) throws -> SearchResults {
        // Hidden categories are always left out, locked ones while they're locked.
        let excluded = includingLocked ? "mediaCategory.isHidden" : "(mediaCategory.isHidden OR mediaCategory.isLocked)"
        let channelRows = try Row.fetchAll(db, sql: """
            SELECT channel.*, source.name AS sourceName
            FROM channelSearch
            JOIN channel ON channel.id = channelSearch.rowid
            JOIN source ON source.id = channel.sourceID
            LEFT JOIN mediaCategory ON mediaCategory.id = channel.categoryID
            WHERE channelSearch MATCH ? AND COALESCE(\(excluded), 0) = 0
            ORDER BY channelSearch.rank, channel.sourceID, channel.sortIndex
            LIMIT ?
            """, arguments: [pattern, limit])
        let channels = try channelRows.map { SearchResults.ChannelHit(channel: try Channel(row: $0), sourceName: $0["sourceName"]) }

        let movieRows = try Row.fetchAll(db, sql: """
            SELECT movie.id, movie.sourceID, movie.stableKey, movie.name, movie.posterURL, movie.rating, movie.year,
                   source.name AS sourceName
            FROM movieSearch
            JOIN movie ON movie.id = movieSearch.rowid
            JOIN source ON source.id = movie.sourceID
            LEFT JOIN mediaCategory ON mediaCategory.id = movie.categoryID
            WHERE movieSearch MATCH ? AND COALESCE(\(excluded), 0) = 0
            ORDER BY movieSearch.rank, movie.sourceID, movie.sortIndex
            LIMIT ?
            """, arguments: [pattern, limit])
        let movies = try movieRows.map { SearchResults.MovieHit(movie: try MovieSummary(row: $0), sourceName: $0["sourceName"]) }

        let seriesRows = try Row.fetchAll(db, sql: """
            SELECT series.id, series.sourceID, series.stableKey, series.name, series.posterURL, series.rating, series.year,
                   source.name AS sourceName
            FROM seriesSearch
            JOIN series ON series.id = seriesSearch.rowid
            JOIN source ON source.id = series.sourceID
            LEFT JOIN mediaCategory ON mediaCategory.id = series.categoryID
            WHERE seriesSearch MATCH ? AND COALESCE(\(excluded), 0) = 0
            ORDER BY seriesSearch.rank, series.sourceID, series.sortIndex
            LIMIT ?
            """, arguments: [pattern, limit])
        let series = try seriesRows.map { SearchResults.SeriesHit(series: try SeriesSummary(row: $0), sourceName: $0["sourceName"]) }

        // A programme is shown on the first visible channel matched to its guide channel.
        let programmeRows = try Row.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT programme.*, source.name AS sourceName, (
                    SELECT MIN(channel.id) FROM channel
                    LEFT JOIN mediaCategory ON mediaCategory.id = channel.categoryID
                    WHERE channel.sourceID = programme.sourceID AND channel.guideID = programme.epgChannelID
                      AND COALESCE(\(excluded), 0) = 0
                ) AS channelID
                FROM programmeSearch
                JOIN programme ON programme.id = programmeSearch.rowid
                JOIN source ON source.id = programme.sourceID
                WHERE programmeSearch MATCH ? AND COALESCE(programme.stop, programme.start + 3600) > ?
            )
            WHERE channelID IS NOT NULL
            ORDER BY start, sourceID, channelID
            LIMIT ?
            """, arguments: [pattern, Int64(now.timeIntervalSince1970), limit])
        let programmeChannels = try Dictionary(
            Channel.fetchAll(db, keys: Set(programmeRows.map { $0["channelID"] as Int64 })).map { ($0.id!, $0) },
            uniquingKeysWith: { first, _ in first })
        let programmes = try programmeRows.compactMap { row -> SearchResults.ProgrammeHit? in
            guard let channel = programmeChannels[row["channelID"]] else { return nil }
            return SearchResults.ProgrammeHit(programme: try Programme(row: row), channel: channel, sourceName: row["sourceName"])
        }
        return SearchResults(channels: channels, movies: movies, series: series, programmes: programmes)
    }
}
