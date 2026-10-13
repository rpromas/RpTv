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

/// The live channels of one source, ready to replace what the database holds.
public struct LiveCatalog: Sendable {
    public struct Group: Sendable, Hashable {
        public var remoteID: String
        public var name: String

        public init(remoteID: String, name: String) {
            self.remoteID = remoteID
            self.name = name
        }
    }

    public struct Item: Sendable {
        /// The channel. Its `sourceID` and `categoryID` are filled in when the catalog is saved.
        public var channel: Channel
        public var groupRemoteID: String?

        public init(channel: Channel, groupRemoteID: String?) {
            self.channel = channel
            self.groupRemoteID = groupRemoteID
        }
    }

    public var groups: [Group]
    public var items: [Item]

    public init(groups: [Group], items: [Item]) {
        self.groups = groups
        self.items = items
    }
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

    /// Atomically swaps a source's live channels for `catalog`. Readers keep seeing the old catalog until
    /// the transaction commits. Categories the user hid stay hidden.
    public func replaceLiveCatalog(sourceID: Int64, with catalog: LiveCatalog) async throws {
        try await writer.write { db in
            let liveCategories = MediaCategory
                .filter(Column("sourceID") == sourceID && Column("kind") == MediaCategory.Kind.live)
            let hiddenRemoteIDs = try Set(String.fetchAll(db, liveCategories.filter(Column("isHidden") == true).select(Column("remoteID"))))

            try Channel.filter(Column("sourceID") == sourceID).deleteAll(db)
            try liveCategories.deleteAll(db)

            var categoryIDs: [String: Int64] = [:]
            for (index, group) in catalog.groups.enumerated() where categoryIDs[group.remoteID] == nil {
                var category = MediaCategory(sourceID: sourceID, kind: .live, remoteID: group.remoteID, name: group.name,
                                             sortIndex: index, isHidden: hiddenRemoteIDs.contains(group.remoteID))
                try category.insert(db)
                categoryIDs[group.remoteID] = category.id
            }

            for item in catalog.items {
                var channel = item.channel
                channel.sourceID = sourceID
                channel.categoryID = item.groupRemoteID.flatMap { categoryIDs[$0] }
                try channel.insert(db)
            }
        }
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
        observe { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT mediaCategory.*, COUNT(channel.id) AS itemCount
                FROM mediaCategory
                JOIN channel ON channel.categoryID = mediaCategory.id
                WHERE mediaCategory.sourceID = ? AND mediaCategory.kind = ? AND mediaCategory.isHidden = 0
                GROUP BY mediaCategory.id
                ORDER BY mediaCategory.sortIndex
                """, arguments: [sourceID, MediaCategory.Kind.live])
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

    private func observe<T: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncThrowingStream<T, Error> {
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
