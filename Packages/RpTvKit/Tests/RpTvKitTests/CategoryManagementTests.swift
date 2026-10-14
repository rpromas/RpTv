// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

/// Renaming, reordering, hiding and locking categories, and how locked categories are kept out of lists.
struct CategoryManagementTests {
    let database: AppDatabase

    init() throws {
        database = try AppDatabase.inMemory()
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    /// A catalog with one channel per group, named after it, plus one movie per group.
    private func catalog(_ groups: [String]) -> SourceCatalog {
        SourceCatalog(
            live: LiveCatalog(
                groups: groups.map { CatalogGroup(remoteID: $0, name: $0) },
                items: groups.enumerated().map { index, group in
                    LiveCatalog.Item(channel: Channel(sourceID: 0, stableKey: "c-\(group)", name: "\(group) Channel", sortIndex: index),
                                     groupRemoteID: group)
                }),
            movies: MovieCatalog(
                groups: groups.map { CatalogGroup(remoteID: $0, name: $0) },
                items: groups.enumerated().map { index, group in
                    MovieCatalog.Item(movie: Movie(sourceID: 0, stableKey: "m-\(group)", name: "\(group) Movie", sortIndex: index),
                                      groupRemoteID: group)
                }))
    }

    private func syncedSource(_ groups: [String]) async throws -> Source {
        let source = try await database.insertSource(Source(name: "A", kind: .m3u, location: "http://example.com/a.m3u"))
        try await database.replaceCatalog(sourceID: source.id!, with: catalog(groups))
        return source
    }

    private func liveNames(_ sourceID: Int64) async throws -> [String] {
        try await firstValue(database.observeLiveCategories(sourceID: sourceID)).map(\.category.displayName)
    }

    @Test func customNamesOrderAndHiddenStateSurviveResync() async throws {
        let source = try await syncedSource(["News", "Sports", "Kids", "Music"])
        let id = source.id!
        try await database.renameCategory(sourceID: id, kind: .live, remoteID: "Sports", to: "  Football ")
        try await database.reorderCategories(sourceID: id, kind: .live, remoteIDs: ["Music", "Sports", "News", "Kids"])
        try await database.updateCategory(sourceID: id, kind: .live, remoteID: "Kids") { $0.isHidden = true }
        // Movie categories are set up apart from live ones.
        try await database.renameCategory(sourceID: id, kind: .movie, remoteID: "News", to: "Documentaries")
        #expect(try await liveNames(id) == ["Music", "Football", "News"])

        // The provider renames nothing, drops Music, and adds Weather.
        try await database.replaceCatalog(sourceID: id, with: catalog(["Weather", "News", "Sports", "Kids"]))

        // Weather wasn't placed by the user, so it follows the categories that were.
        #expect(try await liveNames(id) == ["Football", "News", "Weather"])
        let all = try await firstValue(database.observeAllCategories(sourceID: id, kind: .live))
        #expect(all.map(\.category.displayName) == ["Football", "News", "Kids", "Weather"])
        #expect(all.map(\.category.isHidden) == [false, false, true, false])
        #expect(all.map(\.itemCount) == [1, 1, 1, 1])
        #expect(all[0].category.name == "Sports")

        let movieCategories = try await firstValue(database.observeMovieCategories(sourceID: id))
        #expect(movieCategories.map(\.category.displayName) == ["Weather", "Documentaries", "Sports", "Kids"])

        // The hidden category's channel stays out of All Channels after the resync too.
        let channels = try await firstValue(database.observeChannels(sourceID: id, categoryID: nil))
        #expect(!channels.map(\.name).contains("Kids Channel"))
    }

    @Test func renamingToEmptyOrTheProviderNameRestoresIt() async throws {
        let source = try await syncedSource(["News"])
        let id = source.id!
        try await database.renameCategory(sourceID: id, kind: .live, remoteID: "News", to: "Headlines")
        #expect(try await liveNames(id) == ["Headlines"])
        try await database.renameCategory(sourceID: id, kind: .live, remoteID: "News", to: "   ")
        let category = try #require(try await firstValue(database.observeLiveCategories(sourceID: id)).first?.category)
        #expect(category.customName == nil)
        try await database.renameCategory(sourceID: id, kind: .live, remoteID: "News", to: "News")
        #expect(try await firstValue(database.observeLiveCategories(sourceID: id)).first?.category.customName == nil)
    }

    @Test func reorderingAPartialListKeepsTheRestAfter() async throws {
        let source = try await syncedSource(["A", "B", "C", "D"])
        try await database.reorderCategories(sourceID: source.id!, kind: .live, remoteIDs: ["C"])
        #expect(try await liveNames(source.id!) == ["C", "A", "B", "D"])
    }

    @Test func lockedCategoriesSurviveResyncAndStayOutOfLists() async throws {
        let source = try await syncedSource(["News", "Adult"])
        let id = source.id!
        try await database.updateCategory(sourceID: id, kind: .live, remoteID: "Adult") { $0.isLocked = true }
        try await database.updateCategory(sourceID: id, kind: .movie, remoteID: "Adult") { $0.isLocked = true }
        try await database.replaceCatalog(sourceID: id, with: catalog(["News", "Adult"]))

        // Still listed, so it can be unlocked, but marked.
        let categories = try await firstValue(database.observeLiveCategories(sourceID: id))
        #expect(categories.map(\.category.isLocked) == [false, true])
        let adult = try #require(categories[1].category.id)

        let locked = try await firstValue(database.observeChannels(sourceID: id, categoryID: nil))
        #expect(locked.map(\.name) == ["News Channel"])
        // Picking the category itself doesn't get around the lock.
        #expect(try await firstValue(database.observeChannels(sourceID: id, categoryID: adult)).isEmpty)
        let open = try await firstValue(database.observeChannels(sourceID: id, categoryID: nil, includingLocked: true))
        #expect(open.map(\.name) == ["News Channel", "Adult Channel"])

        #expect(try await firstValue(database.observeMovies(sourceID: id, categoryID: nil)).map(\.name) == ["News Movie"])
        #expect(try await firstValue(database.observeMovies(sourceID: id, categoryID: nil, includingLocked: true)).count == 2)
    }

    @Test func lockedItemsStayOutOfSearchFavoritesAndRecents() async throws {
        let source = try await syncedSource(["News", "Adult"])
        let id = source.id!
        try await database.updateCategory(sourceID: id, kind: .live, remoteID: "Adult") { $0.isLocked = true }
        try await database.updateCategory(sourceID: id, kind: .movie, remoteID: "Adult") { $0.isLocked = true }
        let news = ItemKey(sourceID: id, kind: .channel, stableKey: "c-News")
        let adult = ItemKey(sourceID: id, kind: .channel, stableKey: "c-Adult")
        let adultMovie = ItemKey(sourceID: id, kind: .movie, stableKey: "m-Adult")
        for key in [news, adult, adultMovie] {
            try await database.toggleFavorite(key)
        }
        try await database.recordPlay(news, at: Date(timeIntervalSince1970: 1))
        try await database.recordPlay(adultMovie, at: Date(timeIntervalSince1970: 2))
        try await database.recordPlay(adult, at: Date(timeIntervalSince1970: 3))

        let results = try await database.search("channel")
        #expect(results.channels.map(\.channel.name) == ["News Channel"])
        #expect(try await database.search("movie").movies.isEmpty == false)
        #expect(try await database.search("adult").isEmpty)
        #expect(try await database.search("adult", includingLocked: true).channels.map(\.channel.name) == ["Adult Channel"])

        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: id)).map(\.name) == ["News Channel"])
        #expect(try await firstValue(database.observeFavoriteChannels(sourceID: id, includingLocked: true)).count == 2)
        #expect(try await firstValue(database.observeFavoriteMovies(sourceID: id)).isEmpty)
        #expect(try await firstValue(database.observeRecentChannels(sourceID: id)).map(\.name) == ["News Channel"])
        #expect(try await firstValue(database.observeRecentMovies(sourceID: id)).isEmpty)
        #expect(try await firstValue(database.observeRecentMovies(sourceID: id, includingLocked: true)).count == 1)

        // Resuming at launch doesn't open a locked channel.
        #expect(try await database.lastPlayedChannel() == nil)
        #expect(try await database.lastPlayedChannel(includingLocked: true)?.name == "Adult Channel")

        try await database.unlockAllCategories()
        #expect(try await database.lastPlayedChannel()?.name == "Adult Channel")
    }

    @Test func clearingGuidesForgetsProgrammesAndWhenTheyWereFetched() async throws {
        let source = try await syncedSource(["News"])
        try await database.writer.write { db in
            try GuideChannel(sourceID: source.id!, id: "news", name: "News", names: "[]").insert(db)
            var programme = Programme(sourceID: source.id!, epgChannelID: "news", start: .now, stop: .now.addingTimeInterval(3600),
                                      title: "Headlines")
            try programme.insert(db)
            try db.execute(sql: "UPDATE channel SET guideID = 'news'")
        }
        try await database.recordEPGSync(sourceID: source.id!, error: nil)

        try await database.clearGuides()

        #expect(try await database.search("headlines").programmes.isEmpty)
        #expect(try await database.source(id: source.id!)?.lastEPGSyncAt == nil)
        let channel = try #require(try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil)).first)
        #expect(channel.guideID == nil)
    }
}
