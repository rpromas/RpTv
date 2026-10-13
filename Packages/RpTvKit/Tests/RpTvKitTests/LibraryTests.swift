// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import Testing
@testable import RpTvKit

struct LibraryTests {
    let database: AppDatabase
    let service: SourceSyncService

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

    private func syncedSource(name: String = "Local") async throws -> Source {
        let source = try await database.insertSource(Source(name: name, kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)
        return source
    }

    private func channels(_ sourceID: Int64) async throws -> [String: Channel] {
        let channels = try await firstValue(database.observeChannels(sourceID: sourceID, categoryID: nil))
        return Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0) })
    }

    @Test func favoritesSurviveResync() async throws {
        let source = try await syncedSource()
        let before = try await channels(source.id!)
        let sport = try #require(before["Sport 2, Extra"])
        let news = try #require(before["News One HD"])
        #expect(try await database.toggleFavorite(sport.itemKey))
        #expect(try await database.toggleFavorite(news.itemKey))

        try await service.sync(source)

        let after = try await channels(source.id!)
        // The resync gave the channels new ids, and the favorites follow them.
        #expect(after["Sport 2, Extra"]?.id != sport.id)
        let favorites = try await firstValue(database.observeFavoriteChannels(sourceID: source.id!))
        #expect(favorites.map(\.name) == ["Sport 2, Extra", "News One HD"])
        #expect(favorites.map(\.id) == [after["Sport 2, Extra"]?.id, after["News One HD"]?.id])
        #expect(try await firstValue(database.observeFavoriteKeys()) == [sport.itemKey, news.itemKey])
    }

    @Test func togglingTwiceUnstars() async throws {
        let source = try await syncedSource()
        let news = try #require(try await channels(source.id!)["News One HD"])
        #expect(try await database.toggleFavorite(news.itemKey))
        #expect(try await !database.toggleFavorite(news.itemKey))
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: source.id!)).isEmpty)
    }

    @Test func favoritesKeepTheirPlaceWhileTheirChannelIsGone() async throws {
        let source = try await syncedSource()
        let channels = try await channels(source.id!)
        let names = ["News One HD", "Sport 2, Extra", "Unquoted Logo"]
        for name in names { try await database.toggleFavorite(channels[name]!.itemKey) }

        // A sync that drops the sport channel: the favorite stays stored but isn't listed.
        let remaining = names.filter { $0 != "Sport 2, Extra" }.map { name in
            var channel = channels[name]!
            channel.id = nil
            return LiveCatalog.Item(channel: channel, groupRemoteID: nil)
        }
        try await database.replaceLiveCatalog(sourceID: source.id!, with: LiveCatalog(groups: [], items: remaining))
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: source.id!)).map(\.name) == ["News One HD", "Unquoted Logo"])

        // Reordering what's listed keeps the missing one behind them.
        try await database.reorderFavorites(sourceID: source.id!, kind: .channel,
                                            stableKeys: [channels["Unquoted Logo"]!.stableKey, channels["News One HD"]!.stableKey])
        try await service.sync(source)
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: source.id!)).map(\.name)
            == ["Unquoted Logo", "News One HD", "Sport 2, Extra"])
    }

    @Test func reordersFavorites() async throws {
        let source = try await syncedSource()
        let channels = try await channels(source.id!)
        for name in ["News One HD", "Sport 2, Extra", "Unquoted Logo"] { try await database.toggleFavorite(channels[name]!.itemKey) }

        try await database.reorderFavorites(sourceID: source.id!, kind: .channel, stableKeys: [
            channels["Unquoted Logo"]!.stableKey, channels["News One HD"]!.stableKey, channels["Sport 2, Extra"]!.stableKey,
        ])
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: source.id!)).map(\.name)
            == ["Unquoted Logo", "News One HD", "Sport 2, Extra"])

        // A new favorite goes last.
        try await database.toggleFavorite(channels["Name From Attr"]!.itemKey)
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: source.id!)).last?.name == "Name From Attr")
    }

    @Test func favoritesArePerSource() async throws {
        let first = try await syncedSource(name: "First")
        let second = try await syncedSource(name: "Second")
        try await database.toggleFavorite(try #require(try await channels(first.id!)["News One HD"]).itemKey)
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: first.id!)).count == 1)
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: second.id!)).isEmpty)

        try await database.deleteSource(id: first.id!)
        #expect(try await firstValue(database.observeFavoriteKeys()).isEmpty)
    }

    @Test func recentsSurviveResyncLatestFirst() async throws {
        let source = try await syncedSource()
        let channels = try await channels(source.id!)
        let start = Date(timeIntervalSince1970: 1_791_970_200)
        try await database.recordPlay(channels["News One HD"]!.itemKey, at: start)
        try await database.recordPlay(channels["Sport 2, Extra"]!.itemKey, at: start.addingTimeInterval(60))
        // Playing one again moves it back to the top rather than adding it twice.
        try await database.recordPlay(channels["News One HD"]!.itemKey, at: start.addingTimeInterval(120))

        try await service.sync(source)

        let recent = try await firstValue(database.observeRecentChannels(sourceID: source.id!))
        #expect(recent.map(\.name) == ["News One HD", "Sport 2, Extra"])
        #expect(try await database.lastPlayedChannel()?.name == "News One HD")
    }

    @Test func keepsOnlyTheLatestRecents() async throws {
        let source = try await syncedSource()
        let start = Date(timeIntervalSince1970: 1_791_970_200)
        for index in 0..<(AppDatabase.recentLimit + 10) {
            try await database.recordPlay(ItemKey(sourceID: source.id!, kind: .channel, stableKey: "key-\(index)"),
                                          at: start.addingTimeInterval(Double(index)))
        }
        let keys = try await database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT stableKey FROM recentItem ORDER BY playedAt DESC")
        }
        #expect(keys.count == AppDatabase.recentLimit)
        #expect(keys.first == "key-\(AppDatabase.recentLimit + 9)")
        #expect(keys.last == "key-10")
    }

    @Test func movieFavoritesAndRecentsSurviveResync() async throws {
        let source = try await database.insertSource(Source(name: "VOD", kind: .m3u, location: "vod.m3u", isLocalFile: true))
        try await service.sync(source)
        let movies = try await firstValue(database.observeMovies(sourceID: source.id!, categoryID: nil, sort: .name))
        let heat = try #require(movies.first { $0.name == "Heat (1995)" })
        let ronin = try #require(movies.first { $0.name == "Ronin - 1998" })
        try await database.toggleFavorite(ronin.itemKey)
        try await database.toggleFavorite(heat.itemKey)
        try await database.recordPlay(heat.itemKey, at: Date(timeIntervalSince1970: 100))
        try await database.recordPlay(ronin.itemKey, at: Date(timeIntervalSince1970: 200))

        try await service.sync(source)

        let favorites = try await firstValue(database.observeFavoriteMovies(sourceID: source.id!))
        #expect(favorites.map(\.name) == ["Ronin - 1998", "Heat (1995)"])
        #expect(favorites.first?.id != ronin.id)
        #expect(try await firstValue(database.observeRecentMovies(sourceID: source.id!)).map(\.name) == ["Ronin - 1998", "Heat (1995)"])
        // Movies and channels are kept apart.
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: source.id!)).isEmpty)
        #expect(try await firstValue(database.observeRecentChannels(sourceID: source.id!)).isEmpty)
        #expect(try await database.lastPlayedChannel() == nil)
    }

    @Test func lastPlayedIsNilWhenItsChannelIsGone() async throws {
        let source = try await syncedSource()
        let channels = try await channels(source.id!)
        try await database.recordPlay(channels["News One HD"]!.itemKey, at: Date(timeIntervalSince1970: 100))
        try await database.recordPlay(ItemKey(sourceID: source.id!, kind: .channel, stableKey: "gone"), at: Date(timeIntervalSince1970: 200))
        #expect(try await database.lastPlayedChannel() == nil)
    }
}
