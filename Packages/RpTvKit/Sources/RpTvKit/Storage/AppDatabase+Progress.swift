// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

// Watch progress of movies and episodes, for resuming and for Continue Watching. Like favorites, it points at
// items by `ItemKey`, so it survives resyncs.

/// A movie the user stopped partway through.
public struct ContinueWatchingMovie: Sendable, Hashable, Identifiable {
    public var movie: MovieSummary
    /// A wide image for the card: the backdrop when the movie has one, else the poster.
    public var artworkURL: String?
    public var progress: PlaybackProgress

    public var id: String { movie.stableKey }
}

/// The episode of a series the user stopped partway through, the latest one for each series.
public struct ContinueWatchingEpisode: Sendable, Hashable, Identifiable {
    public var series: SeriesSummary
    public var episode: Episode
    /// A wide image for the card: the episode's still, else the series' backdrop or poster.
    public var artworkURL: String?
    public var progress: PlaybackProgress

    public var id: String { series.stableKey }
}

// MARK: - Writes

extension AppDatabase {
    /// How many items each Continue Watching row holds.
    public static let continueWatchingLimit = 20

    /// Records how far into a movie or episode playback got. At ``PlaybackProgress/watchedThreshold`` of its length
    /// or more, the item is marked watched. A watched item stays watched when it's reopened and closed again
    /// right away.
    public func saveProgress(_ key: ItemKey, position: TimeInterval, duration: TimeInterval, at date: Date = .now) async throws {
        try await writer.write { db in
            let wasWatched = try PlaybackProgress.fetchOne(db, key: Self.progressKey(key))?.isWatched ?? false
            let isWatched = PlaybackProgress.isWatched(position: position, duration: duration)
                || (wasWatched && position < PlaybackProgress.minimumResumePosition)
            try PlaybackProgress(key, position: max(position, 0), duration: max(duration, 0), updatedAt: date,
                                 isWatched: isWatched).upsert(db)
        }
    }

    /// Marks an item watched, keeping how far it got, or unwatched, which forgets its progress.
    public func setWatched(_ key: ItemKey, _ isWatched: Bool, at date: Date = .now) async throws {
        try await writer.write { db in
            guard isWatched else {
                try PlaybackProgress.deleteOne(db, key: Self.progressKey(key))
                return
            }
            var progress = try PlaybackProgress.fetchOne(db, key: Self.progressKey(key))
                ?? PlaybackProgress(key, position: 0, duration: 0)
            progress.isWatched = true
            progress.updatedAt = date
            try progress.upsert(db)
        }
    }

    /// Takes an item off Continue Watching by forgetting its progress. For an episode, every unfinished episode
    /// of its series goes, so the series leaves the row.
    public func removeFromContinueWatching(_ key: ItemKey) async throws {
        try await writer.write { db in
            if key.kind == .episode,
               let seriesKey = try String.fetchOne(db, sql: "SELECT seriesKey FROM episode WHERE sourceID = ? AND stableKey = ?",
                                                   arguments: [key.sourceID, key.stableKey]) {
                try db.execute(sql: """
                    DELETE FROM playbackProgress
                    WHERE sourceID = ? AND kind = ? AND isWatched = 0
                      AND stableKey IN (SELECT stableKey FROM episode WHERE sourceID = ? AND seriesKey = ?)
                    """, arguments: [key.sourceID, ItemKind.episode, key.sourceID, seriesKey])
            }
            try PlaybackProgress.deleteOne(db, key: Self.progressKey(key))
        }
    }

    private static func progressKey(_ key: ItemKey) -> [String: any DatabaseValueConvertible] {
        ["sourceID": key.sourceID, "kind": key.kind, "stableKey": key.stableKey]
    }
}

// MARK: - Reads

extension AppDatabase {
    public func progress(for key: ItemKey) async throws -> PlaybackProgress? {
        try await reader.read { db in try PlaybackProgress.fetchOne(db, key: Self.progressKey(key)) }
    }

    public func observeProgress(for key: ItemKey) -> AsyncThrowingStream<PlaybackProgress?, Error> {
        observe { db in try PlaybackProgress.fetchOne(db, key: Self.progressKey(key)) }
    }

    /// The progress of every episode of a series that has some, by episode `stableKey`.
    public func observeEpisodeProgress(sourceID: Int64, seriesKey: String) -> AsyncThrowingStream<[String: PlaybackProgress], Error> {
        observe { db in
            let rows = try PlaybackProgress.fetchAll(db, sql: """
                SELECT * FROM playbackProgress
                WHERE sourceID = ? AND kind = ?
                  AND stableKey IN (SELECT stableKey FROM episode WHERE sourceID = ? AND seriesKey = ?)
                """, arguments: [sourceID, ItemKind.episode, sourceID, seriesKey])
            return Dictionary(rows.map { ($0.stableKey, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// A source's movies stopped partway through, the latest first. Movies in locked categories are left out
    /// unless `includingLocked`.
    public func observeContinueWatchingMovies(sourceID: Int64, includingLocked: Bool = false) -> AsyncThrowingStream<[ContinueWatchingMovie], Error> {
        observe { db in try Self.continueWatchingMovies(db, sourceID: sourceID, includingLocked: includingLocked) }
    }

    /// For each series of a source with an episode stopped partway through, the latest such episode, latest first.
    /// Series in locked categories are left out unless `includingLocked`.
    public func observeContinueWatchingEpisodes(sourceID: Int64, includingLocked: Bool = false) -> AsyncThrowingStream<[ContinueWatchingEpisode], Error> {
        observe { db in try Self.continueWatchingEpisodes(db, sourceID: sourceID, includingLocked: includingLocked) }
    }

    static func continueWatchingMovies(_ db: Database, sourceID: Int64, includingLocked: Bool = false) throws -> [ContinueWatchingMovie] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT playbackProgress.*,
                   movie.id AS movieID, movie.name, movie.posterURL, movie.rating, movie.year,
                   COALESCE(movie.backdropURL, movie.posterURL) AS artworkURL
            FROM playbackProgress
            JOIN movie ON movie.id = (
                SELECT MIN(id) FROM movie WHERE sourceID = playbackProgress.sourceID AND stableKey = playbackProgress.stableKey)
            WHERE playbackProgress.sourceID = ? AND playbackProgress.kind = ?
              AND playbackProgress.isWatched = 0 AND playbackProgress.position >= ?\(includingLocked ? "" : " AND \(unlocked("movie"))")
            ORDER BY playbackProgress.updatedAt DESC
            LIMIT ?
            """, arguments: [sourceID, ItemKind.movie, PlaybackProgress.minimumResumePosition, continueWatchingLimit])
        return try rows.map { row in
            let progress = try PlaybackProgress(row: row)
            let movie = MovieSummary(id: row["movieID"], sourceID: progress.sourceID, stableKey: progress.stableKey,
                                     name: row["name"], posterURL: row["posterURL"], rating: row["rating"], year: row["year"])
            return ContinueWatchingMovie(movie: movie, artworkURL: row["artworkURL"], progress: progress)
        }
    }

    static func continueWatchingEpisodes(_ db: Database, sourceID: Int64, includingLocked: Bool = false) throws -> [ContinueWatchingEpisode] {
        // The latest unfinished episode of each series: the window keeps one row per series.
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT playbackProgress.*, episode.id AS episodeID,
                       ROW_NUMBER() OVER (PARTITION BY episode.seriesKey ORDER BY playbackProgress.updatedAt DESC) AS rank
                FROM playbackProgress
                JOIN episode ON episode.id = (
                    SELECT MIN(id) FROM episode WHERE sourceID = playbackProgress.sourceID AND stableKey = playbackProgress.stableKey)
                WHERE playbackProgress.sourceID = ? AND playbackProgress.kind = ?
                  AND playbackProgress.isWatched = 0 AND playbackProgress.position >= ?
            )
            WHERE rank = 1
            ORDER BY updatedAt DESC
            LIMIT ?
            """, arguments: [sourceID, ItemKind.episode, PlaybackProgress.minimumResumePosition, continueWatchingLimit])
        let episodes = try Dictionary(
            Episode.fetchAll(db, keys: rows.map { $0["episodeID"] as Int64 }).map { ($0.id!, $0) },
            uniquingKeysWith: { first, _ in first })
        let seriesByKey = try Dictionary(
            Series.filter(Column("sourceID") == sourceID && Set(episodes.values.map(\.seriesKey)).contains(Column("stableKey")))
                .order(Column("id"))
                .fetchAll(db)
                .map { ($0.stableKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let locked = includingLocked ? [] : try Set(Int64.fetchAll(db, lockedCategoryIDs))
        return try rows.compactMap { row in
            guard let episode = episodes[row["episodeID"]], let series = seriesByKey[episode.seriesKey], let id = series.id,
                  series.categoryID.map({ !locked.contains($0) }) ?? true
            else { return nil }
            let summary = SeriesSummary(id: id, sourceID: series.sourceID, stableKey: series.stableKey, name: series.name,
                                        posterURL: series.posterURL, rating: series.rating, year: series.year)
            return ContinueWatchingEpisode(series: summary, episode: episode,
                                           artworkURL: episode.stillURL ?? series.backdropURL ?? series.posterURL,
                                           progress: try PlaybackProgress(row: row))
        }
    }
}
