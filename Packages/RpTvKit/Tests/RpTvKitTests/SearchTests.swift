// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import Testing
@testable import RpTvKit

struct SearchTests {
    let database: AppDatabase
    let service: SourceSyncService
    /// 2026-10-14 09:30 UTC, in the middle of the fixture guide.
    let now = Date(timeIntervalSince1970: 1_791_970_200)

    init() throws {
        database = try AppDatabase.inMemory()
        service = SourceSyncService(
            database: database,
            credentials: InMemoryCredentialStore(),
            playlistDirectory: try Fixture.url("sample.m3u").deletingLastPathComponent(),
            http: StubXtreamServer()
        )
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    /// A source whose live catalog is `names`, one category per entry in `groups` (by index), if given.
    private func source(named name: String, channels names: [String], groups: [String?]? = nil) async throws -> Source {
        let source = try await database.insertSource(Source(name: name, kind: .m3u, location: "http://example.com/\(name).m3u"))
        try await database.replaceLiveCatalog(sourceID: source.id!, with: catalog(name, names, groups: groups))
        return source
    }

    private func catalog(_ prefix: String, _ names: [String], groups: [String?]? = nil) -> LiveCatalog {
        let groupNames = Set((groups ?? []).compactMap { $0 }).sorted()
        return LiveCatalog(
            groups: groupNames.map { CatalogGroup(remoteID: $0, name: $0) },
            items: names.enumerated().map { index, channelName in
                LiveCatalog.Item(channel: Channel(sourceID: 0, stableKey: "\(prefix)-\(index)", name: channelName, sortIndex: index),
                                 groupRemoteID: groups?[index])
            })
    }

    @Test func matchesWordPrefixesIgnoringDiacritics() async throws {
        let source = try await source(named: "A", channels: ["Café Noir", "Cafeteria Live", "Zürich Info", "Ñandú TV", "Cinema One"])

        #expect(try await database.search("cafe").channels.map(\.channel.name) == ["Café Noir", "Cafeteria Live"])
        #expect(try await database.search("CAFÉ").channels.map(\.channel.name) == ["Café Noir", "Cafeteria Live"])
        #expect(try await database.search("zurich").channels.map(\.channel.name) == ["Zürich Info"])
        #expect(try await database.search("nandu").channels.map(\.channel.name) == ["Ñandú TV"])
        // Every word must match the start of a word, in any order.
        #expect(try await database.search("noir caf").channels.map(\.channel.name) == ["Café Noir"])
        #expect(try await database.search("one cin").channels.map(\.channel.name) == ["Cinema One"])
        #expect(try await database.search("afe").channels.isEmpty)
        #expect(try await database.search("cafe tv").channels.isEmpty)
        // Nothing to search for.
        #expect(try await database.search("  ").isEmpty)
        #expect(try await database.search("%").isEmpty)

        // The per-source list uses the same index.
        let filtered = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil, search: "cafe"))
        #expect(filtered.map(\.name) == ["Café Noir", "Cafeteria Live"])
        #expect(try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil, search: "\"")).isEmpty)
    }

    @Test func findsChannelsAcrossSourcesWithTheirSourceName() async throws {
        _ = try await source(named: "Home", channels: ["Sports Central", "News 24"])
        _ = try await source(named: "Travel", channels: ["Sports Extra", "Movies"])

        let hits = try await database.search("sport").channels
        #expect(Set(hits.map { "\($0.sourceName): \($0.channel.name)" }) == ["Home: Sports Central", "Travel: Sports Extra"])
    }

    @Test func leavesOutHiddenCategories() async throws {
        let source = try await source(named: "A", channels: ["Kids Fun", "Kids Adult"], groups: ["Kids", "Adult"])
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE mediaCategory SET isHidden = 1 WHERE sourceID = ? AND name = 'Adult'", arguments: [source.id!])
        }
        #expect(try await database.search("kids").channels.map(\.channel.name) == ["Kids Fun"])
    }

    @Test func indexFollowsResyncs() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)
        try await service.sync(source)
        // Each channel is found once, under its current row.
        let hits = try await database.search("sport").channels
        #expect(hits.map(\.channel.name) == ["Sport 2, Extra"])
        let current = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil, search: "spo ext"))
        #expect(hits.map(\.channel.id) == current.map(\.id))

        try await database.deleteSource(id: source.id!)
        #expect(try await database.search("sport").isEmpty)
    }

    @Test func findsMoviesAcrossSourcesIgnoringDiacritics() async throws {
        let source = try await source(named: "Home", channels: ["Heat TV"])
        let movies = ["Amélie (2001)", "Heat (1995)", "Ronin - 1998"].enumerated().map { index, name in
            MovieCatalog.Item(movie: Movie(sourceID: 0, stableKey: "m\(index)", name: name, sortIndex: index), groupRemoteID: nil)
        }
        try await database.replaceCatalog(sourceID: source.id!, with: SourceCatalog(
            live: LiveCatalog(groups: [], items: [LiveCatalog.Item(channel: Channel(sourceID: 0, stableKey: "c", name: "Heat TV", sortIndex: 0),
                                                                   groupRemoteID: nil)]),
            movies: MovieCatalog(groups: [], items: movies)))

        let heat = try await database.search("heat")
        #expect(heat.channels.map(\.channel.name) == ["Heat TV"])
        #expect(heat.movies.map(\.movie.name) == ["Heat (1995)"])
        #expect(heat.movies.first?.sourceName == "Home")
        #expect(try await database.search("amelie").movies.map(\.movie.name) == ["Amélie (2001)"])
        // The poster grid uses the same index.
        #expect(try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: nil, search: "ron 19")).map(\.name)
            == ["Ronin - 1998"])
        #expect(try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: nil, search: "\"")).isEmpty)

        try await database.deleteSource(id: source.id!)
        #expect(try await database.search("heat").isEmpty)
    }

    @Test func findsProgrammesOnAirOrToCome() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)
        let synced = try #require(try await database.source(id: source.id!))
        try await EPGSyncService(database: database, credentials: InMemoryCredentialStore(), downloader: StubDownloader())
            .sync(synced, now: now)

        let news = try await database.search("news", now: now)
        #expect(news.channels.map(\.channel.name) == ["News One HD"])
        #expect(news.programmes.map(\.programme.title) == ["Evening News"])
        #expect(news.programmes.first?.channel.name == "News One HD")
        #expect(news.programmes.first?.sourceName == "Local")

        // On air now, and before what's to come.
        #expect(try await database.search("late high", now: now).programmes.map(\.channel.name) == ["Sport 2, Extra"])
        // Over already.
        #expect(try await database.search("match", now: now).programmes.isEmpty)
    }

    @Test func searchesLargeCatalogsQuickly() async throws {
        let words = ["Sport", "News", "Movie", "Kids", "Music", "Café", "Documentary", "Nature", "Comedy", "Drama",
                     "Arena", "World", "Premium", "Classic", "Family", "Science", "History", "Travel", "Cinema", "Live"]
        let regions = ["UK", "US", "DE", "FR", "ES", "IT", "PL", "LT", "NL", "SE"]
        let count = 100_000
        let names = (0..<count).map { index in
            "\(words[index % words.count]) \(words[(index / words.count) % words.count]) \(regions[index % regions.count]) \(index)"
        }
        let clock = ContinuousClock()
        let big = try await source(named: "Big", channels: names)
        // Search what a resync leaves behind, as it would be on a device.
        let resync = try await clock.measure {
            try await database.replaceLiveCatalog(sourceID: big.id!, with: catalog("Big", names))
        }
        print("Resynced \(count) channels with their search index in \(resync)")

        _ = try await database.search("warm")
        for query in ["s", "spo", "news uk", "cafe", "documentary 4242", "nothingmatches"] {
            var results = SearchResults()
            let elapsed = try await clock.measure { results = try await database.search(query) }
            print("\"\(query)\": \(results.channels.count) results in \(elapsed)")
            #expect(elapsed < .milliseconds(100), "\"\(query)\" took \(elapsed)")
        }
        #expect(try await database.search("movie 4242").channels.map(\.channel.name) == ["Movie Premium DE 4242", "Movie News DE 42422"])
        #expect(try await database.search("cafe").channels.count == 50)
    }
}
