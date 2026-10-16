// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import Synchronization
import Testing
@testable import RpTvKit

/// The fixture Xtream server, recording the actions it's asked for and failing the ones in `failing`.
final class RecordingXtreamServer: HTTPClient {
    let stub: StubXtreamServer
    let failing: Set<String>
    private let log = Mutex<[String]>([])

    init(overrides: [String: String] = [:], failing: Set<String> = []) {
        stub = StubXtreamServer(overrides: overrides)
        self.failing = failing
    }

    var actions: [String] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let action = items.first { $0.name == "action" }?.value ?? "auth"
        log.withLock { $0.append(action) }
        if failing.contains(action) {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        return try await stub.send(request)
    }
}

struct M3UClassificationTests {
    private func kind(_ url: String, group: String? = nil) -> M3UEntry.ContentKind {
        M3UEntry(name: "x", url: url, attributes: [:], group: group).contentKind
    }

    @Test(arguments: [
        ("http://h:8080/movie/u/p/1.mkv", nil, M3UEntry.ContentKind.movie),
        ("http://h:8080/series/u/p/7.mp4", "Drama", .movie), // a name that doesn't say which episode
        ("http://h/films/a.mp4", "Films", .movie),
        ("http://h/films/a.MKV?token=1", nil, .movie),
        ("http://h/films/a.avi", "Uncategorized", .movie),
        ("http://h/movie/u/p/1.ts", "Live Sports", .movie), // the path wins
        ("http://h/loops/a.mp4", "24/7 Movies", .live),
        ("http://h/loops/a.mp4", "LIVE: Events", .live),
        ("http://h/live/a.m3u8", "Movies", .live),
        ("http://h/live/a.ts", nil, .live),
        ("http://h:8080/u/p/12345", nil, .live),
        ("http://h/olive/a.mp4", "Olive Oil Cooking", .movie), // "live" only as a word
    ])
    func classifies(url: String, group: String?, expected: M3UEntry.ContentKind) {
        #expect(kind(url, group: group) == expected)
    }

    @Test(arguments: [
        ("Heat (1995)", 1995),
        ("Ronin - 1998", 1998),
        ("Alien [1979] 4K", 1979),
        ("2001: A Space Odyssey", nil),
        ("Blade Runner 2049", nil),
        ("Room 1408", nil),
    ] as [(String, Int?)])
    func findsYearInTitle(title: String, year: Int?) {
        #expect(Movie.year(inTitle: title) == year)
    }

    @Test func parsesTrailerIDsAndURLs() {
        var movie = Movie(sourceID: 1, stableKey: "k", name: "M", sortIndex: 0, trailer: "abc_123-X")
        #expect(movie.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=abc_123-X")
        movie.trailer = "https://youtu.be/xyz"
        #expect(movie.trailerURL?.absoluteString == "https://youtu.be/xyz")
        movie.trailer = "  "
        #expect(movie.trailerURL == nil)
        movie.trailer = "not an id"
        #expect(movie.trailerURL == nil)
    }
}

struct MovieSyncTests {
    let database: AppDatabase
    let credentials = InMemoryCredentialStore(["xtream-key": "secret"])

    init() throws {
        database = try AppDatabase.inMemory()
    }

    private func service(_ http: any HTTPClient = StubXtreamServer()) throws -> SourceSyncService {
        SourceSyncService(database: database, credentials: credentials,
                          playlistDirectory: try Fixture.url("vod.m3u").deletingLastPathComponent(), http: http)
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    private func xtreamSource() async throws -> Source {
        try await database.insertSource(Source(name: "Xtream", kind: .xtream, location: "http://example.com:8080",
                                               username: "demo", credentialKey: "xtream-key"))
    }

    private let manyMovies = ["get_vod_categories": "get_vod_categories_list", "get_vod_streams": "get_vod_streams_many"]

    // MARK: - M3U

    @Test func m3uRoutesMoviesOutOfTheChannelList() async throws {
        let source = try await database.insertSource(Source(name: "VOD", kind: .m3u, location: "vod.m3u", isLocalFile: true))
        #expect(try await service().sync(source) == 8)

        let channels = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil))
        #expect(channels.map(\.name) == ["News One", "Looping Classics", "Concert Feed", "News Two"])
        let liveCategories = try await firstValue(database.observeLiveCategories(sourceID: source.id!))
        #expect(liveCategories.map(\.category.name) == ["News", "24/7 Channels", "Live Events"])

        let categories = try await firstValue(database.observeMovieCategories(sourceID: source.id!))
        // "A Show S01 E01" is an episode, so "Series: Drama" is a series category.
        #expect(categories.map(\.category.name) == ["Movies: Action", "Documentaries"])
        #expect(categories.map(\.itemCount) == [2, 1])
        #expect(categories.allSatisfy { $0.category.kind == .movie })

        let action = try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: categories[0].id, sort: .name))
        #expect(action.map(\.name) == ["Heat (1995)", "Ronin - 1998"])
        #expect(action.map(\.year) == [1995, 1998])
        #expect(action[0].posterURL == "http://img.example.com/heat.jpg")

        let ronin = try #require(try await database.movie(sourceID: source.id!, stableKey: action[1].stableKey))
        #expect(ronin.containerExtension == "mp4")
        #expect(ronin.userAgent == "VODAgent/2.0")
        let item = try PlaybackResolver(credentials: credentials).item(for: ronin, in: source)
        #expect(item.url.absoluteString == "http://cdn.example.com/films/ronin.mp4?token=abc")
        #expect(item.headers["User-Agent"] == "VODAgent/2.0")
        #expect(!item.isLive)
        #expect(item.title == "Ronin - 1998")
    }

    @Test func m3uMoviesHaveNoDetailsToFetch() async throws {
        let source = try await database.insertSource(Source(name: "VOD", kind: .m3u, location: "vod.m3u", isLocalFile: true))
        let server = RecordingXtreamServer()
        try await service(server).sync(source)
        let movies = try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: nil))
        let movie = try #require(try await database.movie(sourceID: source.id!, stableKey: movies[0].stableKey))
        #expect(!movie.needsDetails())
        try await service(server).refreshDetails(of: movie, in: source)
        #expect(server.actions.isEmpty)
    }

    // MARK: - Xtream

    @Test func xtreamSyncsMoviesAlongsideChannels() async throws {
        let source = try await xtreamSource()
        let server = RecordingXtreamServer(overrides: manyMovies)
        #expect(try await service(server).sync(source) == 2 + 3 + 2) // channels, movies, series
        #expect(Set(server.actions) == ["auth", "get_live_categories", "get_live_streams", "get_vod_categories", "get_vod_streams",
                                        "get_series_categories", "get_series"])

        let categories = try await firstValue(database.observeMovieCategories(sourceID: source.id!))
        #expect(categories.map(\.category.name) == ["Action", "Drama"])
        #expect(categories.map(\.itemCount) == [1, 2])

        let movies = try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: nil))
        #expect(movies.map(\.name) == ["A Movie", "Older Film (1984)", "Unrated"]) // newest first, undated last
        #expect(movies.map(\.year) == [nil, 1984, 2021])
        #expect(movies.map(\.rating) == [7.4, nil, nil]) // a 0 rating means unrated

        let movie = try #require(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501"))
        #expect(movie.streamURL == nil) // credentials never stored
        #expect(movie.xtreamStreamID == 501)
        #expect(movie.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let saved = try #require(try await database.source(id: source.id!))
        let item = try PlaybackResolver(credentials: credentials).item(for: movie, in: saved)
        #expect(item.url.absoluteString == "http://example.com:8080/movie/demo/secret/501.mkv")
        #expect(!item.isLive)
        #expect(item.id == "xtream-movie:501")
        #expect(item.artworkURL?.absoluteString == "http://img.example.com/m.jpg")

        // Nothing in the database holds the password.
        let dump = try await database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT quote(movie.streamURL) || quote(movie.posterURL) FROM movie")
        }
        #expect(!dump.joined().contains("secret"))
    }

    @Test func sortsMovies() async throws {
        let source = try await xtreamSource()
        try await service(StubXtreamServer(overrides: manyMovies)).sync(source)
        let id = source.id!
        #expect(try await firstValue(database.observeMovies(sourceID: id, categoryID: nil, sort: .name)).map(\.name)
            == ["A Movie", "Older Film (1984)", "Unrated"])
        #expect(try await firstValue(database.observeMovies(sourceID: id, categoryID: nil, sort: .rating)).map(\.name)
            == ["A Movie", "Older Film (1984)", "Unrated"])
    }

    @Test func movieFailuresKeepTheMoviesAndStillUpdateChannels() async throws {
        let source = try await xtreamSource()
        try await service(StubXtreamServer(overrides: manyMovies)).sync(source)
        #expect(try await database.movieCount(sourceID: source.id!) == 3)

        let count = try await service(RecordingXtreamServer(overrides: manyMovies, failing: ["get_vod_streams"])).sync(source)
        #expect(count == 2 + 2) // channels and series
        #expect(try await database.movieCount(sourceID: source.id!) == 3)
        #expect(try await database.channelCount(sourceID: source.id!) == 2)
        #expect(try await database.source(id: source.id!)?.lastSyncError == nil)
    }

    @Test func fetchesDetailsOnceAWeek() async throws {
        let source = try await xtreamSource()
        let server = RecordingXtreamServer()
        let service = try service(server)
        try await service.sync(source)
        let saved = try #require(try await database.source(id: source.id!))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var movie = try #require(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501"))
        #expect(movie.needsDetails(now: now))
        try await service.refreshDetails(of: movie, in: saved, now: now)
        movie = try #require(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501"))
        #expect(movie.plot == "A plot.")
        #expect(movie.cast == "Actor One, Actor Two")
        #expect(movie.director == "Someone")
        #expect(movie.genre == "Sci-Fi")
        #expect(movie.durationSeconds == 8160)
        #expect(movie.backdropURL == "http://img.example.com/bd1.jpg")
        #expect(movie.trailer == "abc123")
        #expect(movie.year == 1999) // from the release date
        #expect(movie.rating == 7.4) // the catalog's rating stays
        #expect(movie.detailsFetchedAt == now)

        // Cached for a week.
        try await service.refreshDetails(of: movie, in: saved, now: now.addingTimeInterval(6 * 24 * 3600))
        #expect(server.actions.filter { $0 == "get_vod_info" }.count == 1)
        let later = now.addingTimeInterval(8 * 24 * 3600)
        #expect(movie.needsDetails(now: later))
        try await service.refreshDetails(of: movie, in: saved, now: later)
        #expect(server.actions.filter { $0 == "get_vod_info" }.count == 2)
        #expect(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501")?.detailsFetchedAt == later)
    }

    @Test func detailsAndHiddenCategoriesSurviveAResync() async throws {
        let source = try await xtreamSource()
        let service = try service(StubXtreamServer(overrides: manyMovies))
        try await service.sync(source)
        let saved = try #require(try await database.source(id: source.id!))
        let movie = try #require(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501"))
        try await service.refreshDetails(of: movie, in: saved)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE mediaCategory SET isHidden = 1 WHERE kind = 'movie' AND name = 'Drama'")
        }

        try await service.sync(saved)
        let resynced = try #require(try await database.movie(sourceID: source.id!, stableKey: "xtream-movie:501"))
        #expect(resynced.id != movie.id) // rows are replaced
        #expect(resynced.plot == "A plot.")
        #expect(resynced.detailsFetchedAt != nil)

        let categories = try await firstValue(database.observeMovieCategories(sourceID: source.id!))
        #expect(categories.map(\.category.name) == ["Action"])
        let visible = try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: nil))
        #expect(visible.map(\.name) == ["A Movie"])
        // Live categories are separate: hiding a movie category leaves them alone.
        #expect(try await firstValue(database.observeLiveCategories(sourceID: source.id!)).count == 2)
    }

    @Test func gridQueryStaysFastWithTwentyThousandMovies() async throws {
        let source = try await database.insertSource(Source(name: "Big", kind: .m3u, location: "big.m3u"))
        let groups = (0..<50).map { CatalogGroup(remoteID: "g\($0)", name: "Group \($0)") }
        let items = (0..<20_000).map { index in
            MovieCatalog.Item(
                movie: Movie(sourceID: 0, stableKey: "m\(index)", name: "Movie \(index)", posterURL: "http://img.example.com/\(index).jpg",
                             rating: Double(index % 100) / 10, addedAt: Date(timeIntervalSince1970: Double(index) * 60),
                             streamURL: "http://h/\(index).mp4", year: 1950 + index % 70, sortIndex: index,
                             plot: String(repeating: "A long plot. ", count: 40)),
                groupRemoteID: "g\(index % 50)")
        }
        try await database.replaceCatalog(sourceID: source.id!,
                                          with: SourceCatalog(live: LiveCatalog(groups: [], items: []),
                                                              movies: MovieCatalog(groups: groups, items: items)))

        for sort in MovieSort.allCases {
            let clock = ContinuousClock()
            var movies: [MovieSummary] = []
            let elapsed = try await clock.measure {
                movies = try await database.reader.read { db in
                    try AppDatabase.movieRequest(sourceID: source.id!, categoryID: nil, search: "", sort: sort).fetchAll(db)
                }
            }
            #expect(movies.count == 20_000)
            #expect(elapsed < .milliseconds(500), "Sorting by \(sort) took \(elapsed)")
        }
    }
}
