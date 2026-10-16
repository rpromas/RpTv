// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// A category with the number of items it holds.
public struct CategorySummary: Sendable, Hashable, Identifiable {
    public var category: MediaCategory
    public var itemCount: Int

    public var id: Int64? { category.id }
}

/// A category as the provider lists it, before it's saved.
public struct CatalogGroup: Sendable, Hashable {
    public var remoteID: String
    public var name: String

    public init(remoteID: String, name: String) {
        self.remoteID = remoteID
        self.name = name
    }
}

/// The live channels of one source, ready to replace what the database holds.
public struct LiveCatalog: Sendable {
    public struct Item: Sendable {
        /// The channel. Its `sourceID` and `categoryID` are filled in when the catalog is saved.
        public var channel: Channel
        public var groupRemoteID: String?

        public init(channel: Channel, groupRemoteID: String?) {
            self.channel = channel
            self.groupRemoteID = groupRemoteID
        }
    }

    public var groups: [CatalogGroup]
    public var items: [Item]

    public init(groups: [CatalogGroup], items: [Item]) {
        self.groups = groups
        self.items = items
    }
}

/// The movies of one source, ready to replace what the database holds.
public struct MovieCatalog: Sendable {
    public struct Item: Sendable {
        /// The movie. Its `sourceID` and `categoryID` are filled in when the catalog is saved.
        public var movie: Movie
        public var groupRemoteID: String?

        public init(movie: Movie, groupRemoteID: String?) {
            self.movie = movie
            self.groupRemoteID = groupRemoteID
        }
    }

    public var groups: [CatalogGroup]
    public var items: [Item]

    public init(groups: [CatalogGroup], items: [Item]) {
        self.groups = groups
        self.items = items
    }
}

/// The series of one source, ready to replace what the database holds.
public struct SeriesCatalog: Sendable {
    public struct Item: Sendable {
        /// The series. Its `sourceID` and `categoryID` are filled in when the catalog is saved.
        public var series: Series
        public var groupRemoteID: String?
        /// Its episodes, when the catalog lists them (M3U). Their `sourceID` is filled in when saved.
        public var episodes: [Episode]

        public init(series: Series, groupRemoteID: String?, episodes: [Episode] = []) {
            self.series = series
            self.groupRemoteID = groupRemoteID
            self.episodes = episodes
        }
    }

    public var groups: [CatalogGroup]
    public var items: [Item]
    /// Whether the items carry every episode (M3U). Otherwise (Xtream) fetched episodes are kept.
    public var includesEpisodes: Bool

    public init(groups: [CatalogGroup], items: [Item], includesEpisodes: Bool) {
        self.groups = groups
        self.items = items
        self.includesEpisodes = includesEpisodes
    }
}

/// Everything a sync downloaded for one source.
public struct SourceCatalog: Sendable {
    public var live: LiveCatalog
    /// `nil` leaves the movies the database has as they are, for when they couldn't be downloaded.
    public var movies: MovieCatalog?
    /// `nil` leaves the series the database has as they are, for when they couldn't be downloaded.
    public var series: SeriesCatalog?

    public init(live: LiveCatalog, movies: MovieCatalog?, series: SeriesCatalog? = nil) {
        self.live = live
        self.movies = movies
        self.series = series
    }

    public var itemCount: Int { live.items.count + (movies?.items.count ?? 0) + (series?.items.count ?? 0) }
}

// MARK: - Writes

extension AppDatabase {
    public func insertSource(_ source: Source) async throws -> Source {
        try await writer.write { db in
            var source = source
            try source.insert(db)
            return source
        }
    }

    public func updateSource(_ source: Source) async throws {
        try await writer.write { db in try source.update(db) }
    }

    /// Changes some fields of the stored source, leaving the rest (such as sync results) as they are in the database.
    public func modifySource(id: Int64, _ modify: @escaping @Sendable (inout Source) -> Void) async throws {
        try await writer.write { db in
            guard var source = try Source.fetchOne(db, key: id) else { return }
            modify(&source)
            try source.update(db)
        }
    }

    /// Deletes a source and, through cascading foreign keys, everything that belongs to it.
    public func deleteSource(id: Int64) async throws {
        try await writer.write { db in
            try Source.deleteOne(db, key: id)
            for table in [Self.channelSearchTable, Self.movieSearchTable, Self.seriesSearchTable, Self.programmeSearchTable] {
                try Self.rebuildSearchIndex(db, table)
            }
        }
    }

    public func recordSync(sourceID: Int64, error: String?, at date: Date = .now) async throws {
        try await writer.write { db in
            guard var source = try Source.fetchOne(db, key: sourceID) else { return }
            if error == nil { source.lastSyncedAt = date }
            source.lastSyncError = error
            try source.update(db)
        }
    }

    /// Atomically swaps a source's live channels for `catalog`. See ``replaceCatalog(sourceID:with:)``.
    public func replaceLiveCatalog(sourceID: Int64, with catalog: LiveCatalog) async throws {
        try await writer.write { db in try Self.replaceLiveCatalog(db, sourceID: sourceID, with: catalog) }
    }

    /// Atomically swaps a source's catalog for `catalog`.
    ///
    /// The user's category changes, guide overrides and cached details carry over, and channels are matched to
    /// the stored guide. Progress, favorites and recents key on `stableKey`, so they're untouched.
    public func replaceCatalog(sourceID: Int64, with catalog: SourceCatalog) async throws {
        try await writer.write { db in
            try Self.replaceLiveCatalog(db, sourceID: sourceID, with: catalog.live)
            if let movies = catalog.movies {
                try Self.replaceMovieCatalog(db, sourceID: sourceID, with: movies)
            }
            if let series = catalog.series {
                try Self.replaceSeriesCatalog(db, sourceID: sourceID, with: series)
            }
        }
    }

    private static func replaceLiveCatalog(_ db: Database, sourceID: Int64, with catalog: LiveCatalog) throws {
        let overrides = try Dictionary(
            Row.fetchAll(db, sql: "SELECT stableKey, epgOverride FROM channel WHERE sourceID = ? AND epgOverride IS NOT NULL",
                         arguments: [sourceID]).map { ($0["stableKey"] as String, $0["epgOverride"] as String) },
            uniquingKeysWith: { first, _ in first })

        try Channel.filter(Column("sourceID") == sourceID).deleteAll(db)
        let categoryIDs = try replaceCategories(db, sourceID: sourceID, kind: .live, with: catalog.groups)

        for item in catalog.items {
            var channel = item.channel
            channel.sourceID = sourceID
            channel.categoryID = item.groupRemoteID.flatMap { categoryIDs[$0] }
            channel.epgOverride = overrides[channel.stableKey]
            channel.guideID = nil
            try channel.insert(db)
        }

        try resolveGuideIDs(db, sourceID: sourceID)
        try rebuildSearchIndex(db, channelSearchTable)
    }

    private static func replaceMovieCatalog(_ db: Database, sourceID: Int64, with catalog: MovieCatalog) throws {
        // Details are fetched on open, so carry them over.
        let cached = try Dictionary(
            Movie.filter(Column("sourceID") == sourceID && Column("detailsFetchedAt") != nil).fetchAll(db)
                .map { ($0.stableKey, $0) },
            uniquingKeysWith: { first, _ in first })

        try Movie.filter(Column("sourceID") == sourceID).deleteAll(db)
        let categoryIDs = try replaceCategories(db, sourceID: sourceID, kind: .movie, with: catalog.groups)

        for item in catalog.items {
            var movie = item.movie
            movie.sourceID = sourceID
            movie.categoryID = item.groupRemoteID.flatMap { categoryIDs[$0] }
            if let details = cached[movie.stableKey] { movie.keepDetails(of: details) }
            try movie.insert(db)
        }
        try rebuildSearchIndex(db, movieSearchTable)
    }

    private static func replaceSeriesCatalog(_ db: Database, sourceID: Int64, with catalog: SeriesCatalog) throws {
        let cached = try Dictionary(
            Series.filter(Column("sourceID") == sourceID && Column("detailsFetchedAt") != nil).fetchAll(db)
                .map { ($0.stableKey, $0) },
            uniquingKeysWith: { first, _ in first })

        try Series.filter(Column("sourceID") == sourceID).deleteAll(db)
        let categoryIDs = try replaceCategories(db, sourceID: sourceID, kind: .series, with: catalog.groups)

        for item in catalog.items {
            var series = item.series
            series.sourceID = sourceID
            series.categoryID = item.groupRemoteID.flatMap { categoryIDs[$0] }
            if let details = cached[series.stableKey] { series.keepDetails(of: details) }
            try series.insert(db)
        }

        if catalog.includesEpisodes {
            try Season.filter(Column("sourceID") == sourceID).deleteAll(db)
            try Episode.filter(Column("sourceID") == sourceID).deleteAll(db)
            for item in catalog.items {
                for var episode in item.episodes {
                    episode.sourceID = sourceID
                    try episode.insert(db)
                }
            }
        } else {
            // Episodes fetched earlier stay, unless their series has left the catalog.
            for table in [Season.databaseTableName, Episode.databaseTableName] {
                try db.execute(sql: """
                    DELETE FROM \(table) WHERE sourceID = ?
                    AND seriesKey NOT IN (SELECT stableKey FROM series WHERE sourceID = ?)
                    """, arguments: [sourceID, sourceID])
            }
        }
        try rebuildSearchIndex(db, seriesSearchTable)
    }

    /// Replaces a source's categories of one kind, carrying the user's changes over by remote id.
    ///
    /// - Returns: The new category ids by remote id.
    private static func replaceCategories(_ db: Database, sourceID: Int64, kind: MediaCategory.Kind,
                                          with groups: [CatalogGroup]) throws -> [String: Int64] {
        let existing = MediaCategory.filter(Column("sourceID") == sourceID && Column("kind") == kind)
        let previous = try Dictionary(existing.fetchAll(db).map { ($0.remoteID, $0) }, uniquingKeysWith: { first, _ in first })
        try existing.deleteAll(db)

        var categoryIDs: [String: Int64] = [:]
        for (index, group) in groups.enumerated() where categoryIDs[group.remoteID] == nil {
            var category = MediaCategory(sourceID: sourceID, kind: kind, remoteID: group.remoteID, name: group.name, sortIndex: index)
            if let old = previous[group.remoteID] {
                category.isHidden = old.isHidden
                category.isLocked = old.isLocked
                category.customName = old.customName
                category.customSortIndex = old.customSortIndex
            }
            try category.insert(db)
            categoryIDs[group.remoteID] = category.id
        }
        return categoryIDs
    }
}

// MARK: - Categories

extension AppDatabase {
    /// Changes one category, found by its remote id so a sync that ran meanwhile doesn't lose the change.
    public func updateCategory(sourceID: Int64, kind: MediaCategory.Kind, remoteID: String,
                               _ modify: @escaping @Sendable (inout MediaCategory) -> Void) async throws {
        try await writer.write { db in
            guard var category = try MediaCategory
                .filter(Column("sourceID") == sourceID && Column("kind") == kind && Column("remoteID") == remoteID)
                .fetchOne(db) else { return }
            modify(&category)
            try category.update(db)
        }
    }

    /// Gives a category the user's name. An empty name, or the provider's, goes back to the provider's.
    public func renameCategory(sourceID: Int64, kind: MediaCategory.Kind, remoteID: String, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await updateCategory(sourceID: sourceID, kind: kind, remoteID: remoteID) { category in
            category.customName = trimmed.isEmpty || trimmed == category.name ? nil : trimmed
        }
    }

    /// Orders a source's categories of one kind by `remoteIDs`; the rest follow in their current order.
    public func reorderCategories(sourceID: Int64, kind: MediaCategory.Kind, remoteIDs: [String]) async throws {
        try await writer.write { db in
            let categories = try MediaCategory
                .filter(Column("sourceID") == sourceID && Column("kind") == kind)
                .order(Self.categoryOrder)
                .fetchAll(db)
            let position = Dictionary(remoteIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = categories.enumerated().sorted { a, b in
                (position[a.element.remoteID] ?? remoteIDs.count + a.offset) < (position[b.element.remoteID] ?? remoteIDs.count + b.offset)
            }
            for (index, entry) in ordered.enumerated() where entry.element.customSortIndex != index {
                var category = entry.element
                category.customSortIndex = index
                try category.update(db)
            }
        }
    }

    /// Unlocks every category of every source, for when parental controls are turned off.
    public func unlockAllCategories() async throws {
        try await writer.write { db in
            _ = try MediaCategory.filter(Column("isLocked") == true).updateAll(db, Column("isLocked").set(to: false))
        }
    }

    /// The user's order, then the provider's for categories the user hasn't placed.
    static var categoryOrder: [any SQLOrderingTerm] {
        [Column("customSortIndex") == nil, Column("customSortIndex"), Column("sortIndex")]
    }

    /// Every category of one kind, hidden ones included, in the user's order, with item counts.
    public func observeAllCategories(sourceID: Int64, kind: MediaCategory.Kind) -> AsyncThrowingStream<[CategorySummary], Error> {
        let itemTable = switch kind {
        case .live: Channel.databaseTableName
        case .movie: Movie.databaseTableName
        case .series: Series.databaseTableName
        }
        return observe { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT mediaCategory.*, (SELECT COUNT(*) FROM \(itemTable) WHERE categoryID = mediaCategory.id) AS itemCount
                FROM mediaCategory
                WHERE sourceID = ? AND kind = ?
                ORDER BY customSortIndex IS NULL, customSortIndex, sortIndex
                """, arguments: [sourceID, kind])
            return try rows.map { CategorySummary(category: try MediaCategory(row: $0), itemCount: $0["itemCount"]) }
        }
    }

    /// Ids of the categories the user locked.
    static var lockedCategoryIDs: QueryInterfaceRequest<MediaCategory> {
        MediaCategory.filter(Column("isLocked") == true).select(Column("id"))
    }
}

// MARK: - Reads

extension AppDatabase {
    public func source(id: Int64) async throws -> Source? {
        try await reader.read { db in try Source.fetchOne(db, key: id) }
    }

    public func observeSources() -> AsyncThrowingStream<[Source], Error> {
        observe { db in try Source.order(Column("createdAt")).fetchAll(db) }
    }

    /// Visible, non-empty live categories of a source, in the user's order, with channel counts. Locked ones
    /// are included so they can be unlocked.
    public func observeLiveCategories(sourceID: Int64) -> AsyncThrowingStream<[CategorySummary], Error> {
        observeCategories(sourceID: sourceID, kind: .live, itemTable: Channel.databaseTableName)
    }

    /// Visible categories of one kind, each with the number of items in `itemTable`. Empty categories are skipped.
    func observeCategories(sourceID: Int64, kind: MediaCategory.Kind, itemTable: String) -> AsyncThrowingStream<[CategorySummary], Error> {
        observe { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT mediaCategory.*, COUNT(item.id) AS itemCount
                FROM mediaCategory
                JOIN \(itemTable) AS item ON item.categoryID = mediaCategory.id
                WHERE mediaCategory.sourceID = ? AND mediaCategory.kind = ? AND mediaCategory.isHidden = 0
                GROUP BY mediaCategory.id
                ORDER BY mediaCategory.customSortIndex IS NULL, mediaCategory.customSortIndex, mediaCategory.sortIndex
                """, arguments: [sourceID, kind])
            return try rows.map { CategorySummary(category: try MediaCategory(row: $0), itemCount: $0["itemCount"]) }
        }
    }

    /// Channels of a source, optionally narrowed to a category and by `search` (word prefixes, ignoring case
    /// and diacritics). Hidden categories are left out unless picked; locked ones unless `includingLocked`.
    public func observeChannels(sourceID: Int64, categoryID: Int64?, search: String = "",
                                includingLocked: Bool = false) -> AsyncThrowingStream<[Channel], Error> {
        observe { db in
            var request = Channel.filter(Column("sourceID") == sourceID)
            if let categoryID {
                request = request.filter(Column("categoryID") == categoryID)
            } else {
                let hidden = MediaCategory.filter(Column("isHidden") == true).select(Column("id"))
                request = request.filter(Column("categoryID") == nil || !hidden.contains(Column("categoryID")))
            }
            if !includingLocked {
                request = request.filter(Column("categoryID") == nil || !Self.lockedCategoryIDs.contains(Column("categoryID")))
            }
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Text with no words in it, like "%", matches nothing.
                guard let pattern = Self.searchPattern(search) else { return [] }
                request = request.filter(sql: "id IN (SELECT rowid FROM channelSearch WHERE channelSearch MATCH ?)",
                                         arguments: [pattern])
            }
            return try request.order(Column("sortIndex")).fetchAll(db)
        }
    }

    public func channelCount(sourceID: Int64) async throws -> Int {
        try await reader.read { db in try Channel.filter(Column("sourceID") == sourceID).fetchCount(db) }
    }

    func observe<T: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncThrowingStream<T, Error> {
        let values = ValueObservation.tracking(fetch).removeDuplicates().values(in: reader)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
