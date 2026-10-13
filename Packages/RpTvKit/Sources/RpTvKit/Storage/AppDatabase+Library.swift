// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

// Favorites and recently watched items. Both point at items by `ItemKey`, so they outlive the rows a sync
// replaces. One whose item has left the catalog stays stored, and shows up again if a later sync brings it back.

// MARK: - Writes

extension AppDatabase {
    /// How many recently played items are kept, across all sources and kinds.
    public static let recentLimit = 50

    /// Stars the item, or unstars it if it's starred. A new favorite goes to the end of the list.
    /// Returns whether the item is now a favorite.
    @discardableResult
    public func toggleFavorite(_ key: ItemKey, at date: Date = .now) async throws -> Bool {
        try await writer.write { db in
            if try Favorite.deleteOne(db, key: Self.primaryKey(key)) { return false }
            let last = try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM favorite WHERE sourceID = ? AND kind = ?",
                                        arguments: [key.sourceID, key.kind])
            try Favorite(key, sortIndex: (last ?? -1) + 1, addedAt: date).insert(db)
            return true
        }
    }

    /// Puts a source's favorites of one kind in the order of `stableKeys`. Favorites missing from it
    /// (such as ones whose item isn't in the catalog right now) keep their order, after those.
    public func reorderFavorites(sourceID: Int64, kind: ItemKind, stableKeys: [String]) async throws {
        try await writer.write { db in
            let favorites = try Favorite
                .filter(Column("sourceID") == sourceID && Column("kind") == kind)
                .order(Column("sortIndex"))
                .fetchAll(db)
            let position = Dictionary(stableKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = favorites.enumerated().sorted { a, b in
                (position[a.element.stableKey] ?? stableKeys.count + a.offset) < (position[b.element.stableKey] ?? stableKeys.count + b.offset)
            }
            for (index, entry) in ordered.enumerated() where entry.element.sortIndex != index {
                var favorite = entry.element
                favorite.sortIndex = index
                try favorite.update(db)
            }
        }
    }

    /// Notes that the item was played, moving it to the top of the recent list, and forgets the oldest
    /// items beyond ``recentLimit``.
    public func recordPlay(_ key: ItemKey, at date: Date = .now) async throws {
        try await writer.write { db in
            try RecentItem(key, playedAt: date).upsert(db)
            try db.execute(sql: """
                DELETE FROM recentItem WHERE rowid NOT IN (
                    SELECT rowid FROM recentItem ORDER BY playedAt DESC LIMIT ?)
                """, arguments: [Self.recentLimit])
        }
    }

    private static func primaryKey(_ key: ItemKey) -> [String: any DatabaseValueConvertible] {
        ["sourceID": key.sourceID, "kind": key.kind, "stableKey": key.stableKey]
    }
}

// MARK: - Reads

extension AppDatabase {
    /// Every favorite of every source, for marking starred items wherever they're listed.
    public func observeFavoriteKeys() -> AsyncThrowingStream<Set<ItemKey>, Error> {
        observe { db in Set(try Favorite.fetchAll(db).map(\.key)) }
    }

    /// A source's favorite channels, in the user's order. Favorites whose channel the catalog doesn't
    /// have right now are left out.
    public func observeFavoriteChannels(sourceID: Int64) -> AsyncThrowingStream<[Channel], Error> {
        observe { db in try Channel.fetchAll(db, Self.libraryItems(.favorites, kind: .channel, sourceID: sourceID)) }
    }

    /// A source's recently played channels, the latest first.
    public func observeRecentChannels(sourceID: Int64) -> AsyncThrowingStream<[Channel], Error> {
        observe { db in try Channel.fetchAll(db, Self.libraryItems(.recent, kind: .channel, sourceID: sourceID)) }
    }

    /// A source's favorite movies, in the user's order, for a poster grid.
    public func observeFavoriteMovies(sourceID: Int64) -> AsyncThrowingStream<[MovieSummary], Error> {
        observe { db in try MovieSummary.fetchAll(db, Self.libraryItems(.favorites, kind: .movie, sourceID: sourceID)) }
    }

    /// A source's recently played movies, the latest first, for a poster grid.
    public func observeRecentMovies(sourceID: Int64) -> AsyncThrowingStream<[MovieSummary], Error> {
        observe { db in try MovieSummary.fetchAll(db, Self.libraryItems(.recent, kind: .movie, sourceID: sourceID)) }
    }

    private enum Library {
        case favorites
        case recent
    }

    /// The rows a source's favorites or recents of one kind point at, in list order. When a catalog lists
    /// a stableKey twice, the first row stands for it.
    private static func libraryItems(_ library: Library, kind: ItemKind, sourceID: Int64) -> SQLRequest<Row> {
        let (list, order) = switch library {
        case .favorites: ("favorite", "favorite.sortIndex")
        case .recent: ("recentItem", "recentItem.playedAt DESC")
        }
        let table = kind == .movie ? Movie.databaseTableName : Channel.databaseTableName
        let columns = kind == .movie ? "movie.id, movie.sourceID, movie.stableKey, movie.name, movie.posterURL, movie.rating, movie.year"
            : "channel.*"
        return SQLRequest(sql: """
            SELECT \(columns) FROM \(list)
            JOIN \(table) ON \(table).id = (
                SELECT MIN(id) FROM \(table) WHERE sourceID = \(list).sourceID AND stableKey = \(list).stableKey)
            WHERE \(list).sourceID = ? AND \(list).kind = ?
            ORDER BY \(order)
            """, arguments: [sourceID, kind])
    }

    /// The channel played last, of any source, or nil when it has left the catalog.
    public func lastPlayedChannel() async throws -> Channel? {
        try await reader.read { db in
            try Channel.fetchOne(db, sql: """
                SELECT channel.* FROM (
                    SELECT * FROM recentItem WHERE kind = ? ORDER BY playedAt DESC LIMIT 1) AS last
                JOIN channel ON channel.id = (
                    SELECT MIN(id) FROM channel WHERE sourceID = last.sourceID AND stableKey = last.stableKey)
                """, arguments: [ItemKind.channel])
        }
    }
}
