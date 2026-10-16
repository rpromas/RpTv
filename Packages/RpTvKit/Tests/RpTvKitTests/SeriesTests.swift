// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import Testing
@testable import RpTvKit

struct EpisodeNameTests {
    @Test(arguments: [
        ("Show S01 E02", "Show", 1, 2, nil),
        ("Show S01E02", "Show", 1, 2, nil),
        ("Show - s1e2 - The Title", "Show", 1, 2, "The Title"),
        ("The Office (US) S05E13 Stress Relief", "The Office (US)", 5, 13, "Stress Relief"),
        ("Show.Name.S01.E02.720p", "Show Name", 1, 2, "720p"),
        ("Show S10 EP100", "Show", 10, 100, nil),
        ("Show 1x02", "Show", 1, 2, nil),
        ("Show: 2x10 | Finale", "Show", 2, 10, "Finale"),
    ] as [(String, String, Int, Int, String?)])
    func parses(name: String, show: String, season: Int, episode: Int, title: String?) throws {
        let parsed = try #require(EpisodeName(parsing: name))
        #expect(parsed == EpisodeName(show: show, season: season, episode: episode, title: title))
    }

    @Test(arguments: [
        "Heat (1995)",
        "S01E02", // no show name
        "Blade Runner 2049",
        "Sports 1 HD",
        "Mission S01", // no episode
        "Box 4x4 Rally", // "4x4" isn't an episode
    ])
    func rejects(name: String) {
        #expect(EpisodeName(parsing: name) == nil)
    }

    @Test(arguments: [
        ("A Show S01 E01", "http://h:8080/series/u/p/7.mp4", nil, M3UEntry.ContentKind.episode),
        ("A Show S01 E01", "http://h/shows/a.mkv", "Drama", .episode),
        ("Special", "http://h:8080/series/u/p/7.mp4", nil, .movie), // can't tell which episode
        ("Heat S01E01", "http://h:8080/movie/u/p/1.mkv", nil, .movie), // the path wins
        ("News S01E01", "http://h/live/a.m3u8", nil, .live),
        ("Loop S01E01", "http://h/loops/a.mp4", "24/7 Shows", .live),
    ] as [(String, String, String?, M3UEntry.ContentKind)])
    func classifiesEpisodes(name: String, url: String, group: String?, expected: M3UEntry.ContentKind) {
        #expect(M3UEntry(name: name, url: url, attributes: [:], group: group).contentKind == expected)
    }
}

struct SeriesSyncTests {
    let database: AppDatabase
    let credentials = InMemoryCredentialStore(["xtream-key": "secret"])

    init() throws {
        database = try AppDatabase.inMemory()
    }

    private func service(_ http: any HTTPClient = StubXtreamServer()) throws -> SourceSyncService {
        SourceSyncService(database: database, credentials: credentials,
                          playlistDirectory: try Fixture.url("series.m3u").deletingLastPathComponent(), http: http)
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    private func xtreamSource() async throws -> Source {
        try await database.insertSource(Source(name: "Xtream", kind: .xtream, location: "http://example.com:8080",
                                               username: "demo", credentialKey: "xtream-key"))
    }

    private func m3uSource() async throws -> Source {
        try await database.insertSource(Source(name: "Shows", kind: .m3u, location: "series.m3u", isLocalFile: true))
    }

    // MARK: - M3U

    @Test func m3uGroupsEpisodesIntoSeries() async throws {
        let source = try await m3uSource()
        #expect(try await service().sync(source) == 1 + 2 + 3) // a channel, two movies, three series
        let id = source.id!

        let categories = try await firstValue(database.observeSeriesCategories(sourceID: id))
        #expect(categories.map(\.category.name) == ["Series: Drama", "Series: Comedy"])
        #expect(categories.map(\.itemCount) == [1, 2])
        // The episode with no number stays playable, as a movie.
        let movieCategories = try await firstValue(database.observeMovieCategories(sourceID: id))
        #expect(movieCategories.map(\.category.name) == ["Series: Drama", "Movies"])

        let series = try await firstValue(database.observeSeries(sourceID: id, categoryID: nil, sort: .name))
        // The same show in another group is another series.
        #expect(series.map(\.name) == ["A Show", "A Show", "Other Show"])

        let drama = try #require(try await database.series(sourceID: id, stableKey: "m3u-series:A Show|Series: Drama"))
        #expect(drama.posterURL == "http://img.example.com/show-s1e2.jpg")
        #expect(!drama.needsDetails())
        let episodes = try await database.episodes(sourceID: id, seriesKey: drama.stableKey)
        // In order, though the playlist lists S01E02 first; the duplicate S02E01 gets a key of its own.
        #expect(episodes.episodes.map(\.code) == ["S1 E1", "S1 E2", "S2 E1", "S2 E1"])
        #expect(episodes.episodes.map(\.title) == ["Episode 1", "The Second", "Episode 1", "Episode 1"])
        #expect(episodes.episodes.map(\.stableKey).last == "m3u-episode:A Show|Series: Drama|2x1#2")
        #expect(episodes.seasonNumbers == [1, 2])
        #expect(episodes.episodes(inSeason: 2).count == 2)
        #expect(episodes.episode(after: episodes.episodes[1])?.code == "S2 E1")
        #expect(episodes.episode(after: episodes.episodes[3]) == nil)

        let third = episodes.episodes[2]
        #expect(third.durationSeconds == 3600)
        #expect(third.containerExtension == "mp4")
        let item = try PlaybackResolver(credentials: credentials).item(for: third, of: drama, in: source, startPosition: 42)
        #expect(item.url.absoluteString == "http://provider.example.com/series/user/pass/7003.mp4")
        #expect(item.headers["User-Agent"] == "SeriesAgent/1.0")
        #expect(item.title == "A Show")
        #expect(item.subtitle == "S2 E1 · Episode 1")
        #expect(item.startPosition == 42)
        #expect(!item.isLive)

        let other = try #require(try await database.series(sourceID: id, stableKey: "m3u-series:Other Show|Series: Comedy"))
        #expect(try await database.episodes(sourceID: id, seriesKey: other.stableKey).episodes.map(\.title) == ["Pilot"])
    }

    @Test func m3uResyncReplacesEpisodes() async throws {
        let source = try await m3uSource()
        let service = try service()
        try await service.sync(source)
        let before = try await database.episodes(sourceID: source.id!, seriesKey: "m3u-series:A Show|Series: Drama")
        try await service.sync(source)
        let after = try await database.episodes(sourceID: source.id!, seriesKey: "m3u-series:A Show|Series: Drama")
        #expect(after.episodes.map(\.stableKey) == before.episodes.map(\.stableKey))
        #expect(after.episodes.map(\.id) != before.episodes.map(\.id)) // rows are replaced, not duplicated
    }

    // MARK: - Xtream

    @Test func xtreamSyncsSeriesList() async throws {
        let source = try await xtreamSource()
        try await service().sync(source)
        let id = source.id!

        let categories = try await firstValue(database.observeSeriesCategories(sourceID: id))
        #expect(categories.map(\.category.name) == ["Drama", "Comedy"])
        let series = try await firstValue(database.observeSeries(sourceID: id, categoryID: nil))
        #expect(series.map(\.name) == ["A Show", "Funny Business (2018)"]) // newest first; the one without an id is skipped
        #expect(series.map(\.rating) == [8, nil]) // a 0 rating means unrated
        #expect(series.map(\.year) == [2020, 2018])

        let show = try #require(try await database.series(sourceID: id, stableKey: "xtream-series:1"))
        #expect(show.plot == "Show plot")
        #expect(show.backdropURL == "http://img.example.com/bd.jpg")
        #expect(show.needsDetails())
        // Episodes come when the series is opened.
        #expect(try await database.episodes(sourceID: id, seriesKey: show.stableKey).episodes.isEmpty)
    }

    @Test func seriesFailuresKeepTheSeriesAndStillUpdateChannels() async throws {
        let source = try await xtreamSource()
        try await service().sync(source)
        let count = try await service(RecordingXtreamServer(failing: ["get_series"])).sync(source)
        #expect(count == 2 + 1) // channels and the movie
        #expect(try await database.seriesCount(sourceID: source.id!) == 2)
        #expect(try await database.source(id: source.id!)?.lastSyncError == nil)
    }

    @Test func fetchesEpisodesOnceAWeekAndKeepsThemAcrossResyncs() async throws {
        let source = try await xtreamSource()
        let server = RecordingXtreamServer()
        let service = try service(server)
        try await service.sync(source)
        let saved = try #require(try await database.source(id: source.id!))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let show = try #require(try await database.series(sourceID: source.id!, stableKey: "xtream-series:1"))
        try await service.refreshDetails(of: show, in: saved, now: now)
        var episodes = try await database.episodes(sourceID: source.id!, seriesKey: show.stableKey)
        #expect(episodes.episodes.map(\.code) == ["S1 E1", "S1 E2", "S2 E1"])
        #expect(episodes.episodes.map(\.stableKey) == ["xtream-episode:9001", "xtream-episode:9002", "xtream-episode:9003"])
        #expect(episodes.seasons.map(\.name) == ["Season 1"])
        #expect(episodes.season(1)?.posterURL == "http://img.example.com/s1.jpg")
        #expect(episodes.seasonNumbers == [1, 2]) // season 2 only exists through its episode
        let second = episodes.episodes[1]
        #expect(second.plot == "Second")
        #expect(second.durationSeconds == 2700)
        #expect(second.stillURL == "http://img.example.com/e2.jpg")
        #expect(second.containerExtension == "mkv")
        #expect(second.streamURL == nil) // credentials never stored
        #expect(try await database.series(sourceID: source.id!, stableKey: show.stableKey)?.detailsFetchedAt == now)

        // Cached for a week.
        let fetched = try #require(try await database.series(sourceID: source.id!, stableKey: show.stableKey))
        try await service.refreshDetails(of: fetched, in: saved, now: now.addingTimeInterval(6 * 24 * 3600))
        #expect(server.actions.filter { $0 == "get_series_info" }.count == 1)
        #expect(fetched.needsDetails(now: now.addingTimeInterval(8 * 24 * 3600)))

        // A resync replaces the series row but keeps its episodes and when they were fetched.
        try await service.sync(saved)
        let resynced = try #require(try await database.series(sourceID: source.id!, stableKey: show.stableKey))
        #expect(resynced.id != show.id)
        #expect(resynced.detailsFetchedAt == now)
        episodes = try await database.episodes(sourceID: source.id!, seriesKey: show.stableKey)
        #expect(episodes.episodes.count == 3)

        let item = try PlaybackResolver(credentials: credentials).item(for: second, of: resynced, in: saved)
        #expect(item.url.absoluteString == "http://example.com:8080/series/demo/secret/9002.mkv")
        #expect(item.id == "xtream-episode:9002")

        // A series that leaves the catalog takes its episodes with it.
        try await self.service(StubXtreamServer(overrides: ["get_series": "get_series_categories"])).sync(saved)
        #expect(try await database.seriesCount(sourceID: source.id!) == 0)
        #expect(try await database.episodes(sourceID: source.id!, seriesKey: show.stableKey).episodes.isEmpty)
    }

    @Test func searchFindsSeriesOutsideLockedCategories() async throws {
        let source = try await xtreamSource()
        try await service().sync(source)
        #expect(try await database.search("funny").series.map(\.series.name) == ["Funny Business (2018)"])
        #expect(try await firstValue(database.observeSeries(sourceID: source.id!, categoryID: nil, search: "show")).map(\.name)
            == ["A Show"])

        try await database.updateCategory(sourceID: source.id!, kind: .series, remoteID: "21") { $0.isLocked = true }
        #expect(try await database.search("funny").series.isEmpty)
        #expect(try await database.search("funny", includingLocked: true).series.count == 1)
        #expect(try await firstValue(database.observeSeries(sourceID: source.id!, categoryID: nil)).map(\.name) == ["A Show"])
    }

    @Test func favoriteSeriesSurviveAResync() async throws {
        let source = try await xtreamSource()
        let service = try service()
        try await service.sync(source)
        let show = try #require(try await database.series(sourceID: source.id!, stableKey: "xtream-series:1"))
        try await database.toggleFavorite(show.itemKey)
        try await service.sync(source)
        #expect(try await firstValue(database.observeFavoriteSeries(sourceID: source.id!)).map(\.name) == ["A Show"])
    }

    @Test func deletingSourceRemovesItsCatalog() async throws {
        let source = try await m3uSource()
        try await service().sync(source)
        try await database.deleteSource(id: source.id!)
        #expect(try await database.channelCount(sourceID: source.id!) == 0)
        #expect(try await database.movieCount(sourceID: source.id!) == 0)
        #expect(try await database.seriesCount(sourceID: source.id!) == 0)
        let episodes = try await database.reader.read { db in try Episode.fetchCount(db) }
        #expect(episodes == 0)
    }
}

struct PlaybackProgressTests {
    let database: AppDatabase
    let credentials = InMemoryCredentialStore(["xtream-key": "secret"])

    init() throws {
        database = try AppDatabase.inMemory()
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    /// An Xtream source with its catalog, and the episodes of "A Show" fetched.
    private func syncedSource() async throws -> (Source, SourceSyncService) {
        let inserted = try await database.insertSource(Source(name: "Xtream", kind: .xtream, location: "http://example.com:8080",
                                                              username: "demo", credentialKey: "xtream-key"))
        let service = SourceSyncService(database: database, credentials: credentials,
                                        playlistDirectory: URL.temporaryDirectory, http: StubXtreamServer())
        try await service.sync(inserted)
        let source = try #require(try await database.source(id: inserted.id!))
        let show = try #require(try await database.series(sourceID: source.id!, stableKey: "xtream-series:1"))
        try await service.refreshDetails(of: show, in: source)
        return (source, service)
    }

    private func episodeKey(_ id: Int, source: Source) -> ItemKey {
        ItemKey(sourceID: source.id!, kind: .episode, stableKey: "xtream-episode:\(id)")
    }

    @Test(arguments: [
        (100.0, 1000.0, false),
        (949.0, 1000.0, false),
        (950.0, 1000.0, true),
        (1000.0, 1000.0, true),
        (500.0, 0.0, false), // length unknown
    ])
    func watchedAtNinetyFivePercent(position: Double, duration: Double, watched: Bool) async throws {
        let (source, _) = try await syncedSource()
        let key = episodeKey(9001, source: source)
        try await database.saveProgress(key, position: position, duration: duration)
        let progress = try #require(try await database.progress(for: key))
        #expect(progress.isWatched == watched)
        #expect(progress.resumePosition == (watched ? nil : position))
    }

    @Test func resumePositionSkipsTheFirstSeconds() {
        let key = ItemKey(sourceID: 1, kind: .movie, stableKey: "m")
        #expect(PlaybackProgress(key, position: 5, duration: 100).resumePosition == nil)
        #expect(PlaybackProgress(key, position: 10, duration: 100).resumePosition == 10)
        #expect(PlaybackProgress(key, position: 50, duration: 200).fraction == 0.25)
        #expect(PlaybackProgress(key, position: 50, duration: 200).remaining == 150)
        #expect(PlaybackProgress(key, position: 50, duration: 0).fraction == nil)
    }

    @Test func watchedStaysWatchedWhenReopenedBriefly() async throws {
        let (source, _) = try await syncedSource()
        let key = episodeKey(9001, source: source)
        try await database.saveProgress(key, position: 990, duration: 1000)
        // Reopened and closed straight away: still watched.
        try await database.saveProgress(key, position: 3, duration: 1000)
        #expect(try await database.progress(for: key)?.isWatched == true)
        // Rewatched for real: in progress again.
        try await database.saveProgress(key, position: 300, duration: 1000)
        #expect(try await database.progress(for: key)?.isWatched == false)
    }

    @Test func marksWatchedAndUnwatched() async throws {
        let (source, _) = try await syncedSource()
        let key = episodeKey(9002, source: source)
        try await database.setWatched(key, true)
        #expect(try await database.progress(for: key)?.isWatched == true)
        try await database.setWatched(key, false)
        #expect(try await database.progress(for: key) == nil)
    }

    @Test func continueWatchingListsUnfinishedItemsLatestFirst() async throws {
        let (source, _) = try await syncedSource()
        let id = source.id!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let movie = ItemKey(sourceID: id, kind: .movie, stableKey: "xtream-movie:501")
        try await database.saveProgress(movie, position: 600, duration: 6000, at: start)

        // Two episodes of the same series: only the latest shows. A watched one and one barely started don't.
        try await database.saveProgress(episodeKey(9001, source: source), position: 100, duration: 1000, at: start)
        try await database.saveProgress(episodeKey(9002, source: source), position: 200, duration: 2700,
                                        at: start.addingTimeInterval(60))
        try await database.saveProgress(episodeKey(9003, source: source), position: 2690, duration: 2700,
                                        at: start.addingTimeInterval(120))

        let movies = try await firstValue(database.observeContinueWatchingMovies(sourceID: id))
        #expect(movies.map(\.movie.name) == ["A Movie"])
        #expect(movies.first?.progress.fraction == 0.1)
        #expect(movies.first?.artworkURL == "http://img.example.com/m.jpg")

        var episodes = try await firstValue(database.observeContinueWatchingEpisodes(sourceID: id))
        #expect(episodes.map(\.series.name) == ["A Show"])
        #expect(episodes.map(\.episode.code) == ["S1 E2"])
        #expect(episodes.first?.artworkURL == "http://img.example.com/e2.jpg")

        // Removing the series takes all its unfinished episodes off the row, and leaves the watched one watched.
        try await database.removeFromContinueWatching(episodeKey(9002, source: source))
        episodes = try await firstValue(database.observeContinueWatchingEpisodes(sourceID: id))
        #expect(episodes.isEmpty)
        #expect(try await database.progress(for: episodeKey(9003, source: source))?.isWatched == true)

        // Marking a movie watched takes it off the row too.
        try await database.setWatched(movie, true)
        #expect(try await firstValue(database.observeContinueWatchingMovies(sourceID: id)).isEmpty)
    }

    @Test func progressSurvivesAResync() async throws {
        let (source, service) = try await syncedSource()
        let key = episodeKey(9002, source: source)
        try await database.saveProgress(key, position: 1200, duration: 2700)
        let movie = ItemKey(sourceID: source.id!, kind: .movie, stableKey: "xtream-movie:501")
        try await database.saveProgress(movie, position: 600, duration: 6000)

        try await service.sync(source)
        #expect(try await database.progress(for: key)?.resumePosition == 1200)
        #expect(try await database.progress(for: movie)?.resumePosition == 600)
        #expect(try await firstValue(database.observeContinueWatchingEpisodes(sourceID: source.id!)).count == 1)
        #expect(try await firstValue(database.observeContinueWatchingMovies(sourceID: source.id!)).count == 1)
        let progress = try await firstValue(database.observeEpisodeProgress(sourceID: source.id!, seriesKey: "xtream-series:1"))
        #expect(progress.keys.sorted() == ["xtream-episode:9002"])
    }

    @Test func continueWatchingLeavesOutLockedCategories() async throws {
        let (source, _) = try await syncedSource()
        try await database.saveProgress(episodeKey(9001, source: source), position: 100, duration: 1000)
        try await database.updateCategory(sourceID: source.id!, kind: .series, remoteID: "20") { $0.isLocked = true }
        #expect(try await firstValue(database.observeContinueWatchingEpisodes(sourceID: source.id!)).isEmpty)
        #expect(try await firstValue(database.observeContinueWatchingEpisodes(sourceID: source.id!, includingLocked: true)).count == 1)
    }

    @Test func playStartsTheEpisodeUpNext() {
        let episodes = SeriesEpisodes(episodes: (1...3).map {
            Episode(sourceID: 1, seriesKey: "s", stableKey: "e\($0)", season: 1, number: $0, title: "E\($0)", sortIndex: $0)
        })
        func progress(_ entries: (String, Double, Double)...) -> [String: PlaybackProgress] {
            Dictionary(uniqueKeysWithValues: entries.enumerated().map { index, entry in
                let key = ItemKey(sourceID: 1, kind: .episode, stableKey: entry.0)
                return (entry.0, PlaybackProgress(key, position: entry.1, duration: entry.2,
                                                  updatedAt: Date(timeIntervalSince1970: Double(index)),
                                                  isWatched: PlaybackProgress.isWatched(position: entry.1, duration: entry.2)))
            })
        }
        #expect(episodes.upNext(progress: [:])?.stableKey == "e1")
        #expect(episodes.upNext(progress: progress(("e1", 990, 1000)))?.stableKey == "e2") // watched: the next one
        #expect(episodes.upNext(progress: progress(("e1", 990, 1000), ("e2", 300, 1000)))?.stableKey == "e2") // unfinished
        #expect(episodes.upNext(progress: progress(("e2", 300, 1000), ("e1", 990, 1000)))?.stableKey == "e2") // rewatched e1 last
        #expect(episodes.upNext(progress: progress(("e3", 1000, 1000)))?.stableKey == "e3") // the last one stays
        #expect(SeriesEpisodes().upNext(progress: [:]) == nil)
    }

    @Test func resumeStartsTheItemWhereItStopped() async throws {
        let (source, _) = try await syncedSource()
        let movie = try #require(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501"))
        try await database.saveProgress(movie.itemKey, position: 754, duration: 6000)
        let resume = try await database.progress(for: movie.itemKey)?.resumePosition
        let item = try PlaybackResolver(credentials: credentials).item(for: movie, in: source, startPosition: resume)
        #expect(item.startPosition == 754)
    }
}
