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

/// Everything a sync downloaded for one source.
public struct SourceCatalog: Sendable {
    public var live: LiveCatalog
    /// `nil` leaves the movies the database has as they are, for when they couldn't be downloaded.
    public var movies: MovieCatalog?

    public init(live: LiveCatalog, movies: MovieCatalog?) {
        self.live = live
        self.movies = movies
    }

    public var itemCount: Int { live.items.count + (movies?.items.count ?? 0) }
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
        _ = try await writer.write { db in try Source.deleteOne(db, key: id) }
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

    /// Atomically swaps a source's catalog for `catalog`. Readers keep seeing the old catalog until the
    /// transaction commits. Categories the user hid stay hidden, guide overrides stay on their channels,
    /// channels are matched to the guide the source already has, and movies keep their cached details.
    public func replaceCatalog(sourceID: Int64, with catalog: SourceCatalog) async throws {
        try await writer.write { db in
            try Self.replaceLiveCatalog(db, sourceID: sourceID, with: catalog.live)
            if let movies = catalog.movies {
                try Self.replaceMovieCatalog(db, sourceID: sourceID, with: movies)
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
    }

    private static func replaceMovieCatalog(_ db: Database, sourceID: Int64, with catalog: MovieCatalog) throws {
        // Details are only fetched when a movie is opened, so they're carried over rather than lost on every sync.
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
    }

    /// Replaces a source's categories of one kind, keeping the ones the user hid hidden.
    /// Returns the new category ids by remote id.
    private static func replaceCategories(_ db: Database, sourceID: Int64, kind: MediaCategory.Kind,
                                          with groups: [CatalogGroup]) throws -> [String: Int64] {
        let existing = MediaCategory.filter(Column("sourceID") == sourceID && Column("kind") == kind)
        let hiddenRemoteIDs = try Set(String.fetchAll(db, existing.filter(Column("isHidden") == true).select(Column("remoteID"))))
        try existing.deleteAll(db)

        var categoryIDs: [String: Int64] = [:]
        for (index, group) in groups.enumerated() where categoryIDs[group.remoteID] == nil {
            var category = MediaCategory(sourceID: sourceID, kind: kind, remoteID: group.remoteID, name: group.name,
                                         sortIndex: index, isHidden: hiddenRemoteIDs.contains(group.remoteID))
            try category.insert(db)
            categoryIDs[group.remoteID] = category.id
        }
        return categoryIDs
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

    /// Visible live categories of a source, each with its channel count. Empty categories are skipped.
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
                ORDER BY mediaCategory.sortIndex
                """, arguments: [sourceID, kind])
            return try rows.map { CategorySummary(category: try MediaCategory(row: $0), itemCount: $0["itemCount"]) }
        }
    }

    /// Channels of a source, optionally narrowed to one category and to names containing `search`.
    /// Channels in hidden categories are left out unless a category is picked explicitly.
    public func observeChannels(sourceID: Int64, categoryID: Int64?, search: String = "") -> AsyncThrowingStream<[Channel], Error> {
        observe { db in
            var request = Channel.filter(Column("sourceID") == sourceID)
            if let categoryID {
                request = request.filter(Column("categoryID") == categoryID)
            } else {
                let hidden = MediaCategory.filter(Column("isHidden") == true).select(Column("id"))
                request = request.filter(Column("categoryID") == nil || !hidden.contains(Column("categoryID")))
            }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                request = request.filter(Column("name").like("%\(Self.escapeLike(query))%", escape: "\\"))
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

    static func escapeLike(_ text: String) -> String {
        text.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
    }
}
