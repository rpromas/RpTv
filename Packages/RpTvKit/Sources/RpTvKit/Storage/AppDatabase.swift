// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// The app's SQLite database: schema, migrations, and the reads and writes the app needs.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the on-disk database. WAL mode lets the UI keep reading while a sync writes.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.label = "RpTv"
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    /// An empty database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: Source.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("location", .text).notNull()
                t.column("isLocalFile", .boolean).notNull().defaults(to: false)
                t.column("username", .text)
                t.column("credentialKey", .text)
                t.column("epgURL", .text)
                t.column("userAgent", .text)
                t.column("referrer", .text)
                t.column("liveFormat", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("lastSyncedAt", .datetime)
                t.column("lastSyncError", .text)
            }

            try db.create(table: MediaCategory.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("remoteID", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sortIndex", .integer).notNull()
                t.column("isHidden", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "mediaCategory_source_kind", on: MediaCategory.databaseTableName,
                          columns: ["sourceID", "kind", "sortIndex"])

            try db.create(table: Channel.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("categoryID", .integer).references(MediaCategory.databaseTableName, onDelete: .setNull)
                t.column("stableKey", .text).notNull()
                t.column("name", .text).notNull()
                t.column("number", .integer)
                t.column("logoURL", .text)
                t.column("streamURL", .text)
                t.column("xtreamStreamID", .integer)
                t.column("epgChannelID", .text)
                t.column("catchupDays", .integer)
                t.column("userAgent", .text)
                t.column("referrer", .text)
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(index: "channel_source_category", on: Channel.databaseTableName,
                          columns: ["sourceID", "categoryID", "sortIndex"])
            try db.create(index: "channel_categoryID", on: Channel.databaseTableName, columns: ["categoryID"])
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: Source.databaseTableName) { t in
                t.add(column: "enginePreference", .text).notNull().defaults(to: EnginePreference.automatic.rawValue)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: Source.databaseTableName) { t in
                t.add(column: "lastEPGSyncAt", .datetime)
                t.add(column: "lastEPGSyncError", .text)
            }
            try db.alter(table: Channel.databaseTableName) { t in
                t.add(column: "epgOverride", .text)
                t.add(column: "guideID", .text)
            }

            try db.create(table: GuideChannel.databaseTableName) { t in
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("names", .text).notNull()
                t.column("iconURL", .text)
                t.primaryKey(["sourceID", "id"])
            }

            // Times are stored as Unix seconds so range queries stay cheap.
            try db.create(table: Programme.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("epgChannelID", .text).notNull()
                t.column("start", .integer).notNull()
                t.column("stop", .integer)
                t.column("title", .text).notNull()
                t.column("summary", .text)
                t.column("category", .text)
                t.column("iconURL", .text)
            }
            try db.create(index: "programme_source_channel_start", on: Programme.databaseTableName,
                          columns: ["sourceID", "epgChannelID", "start"])
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: Source.databaseTableName) { t in
                t.add(column: "serverTimeZone", .text)
            }
            try db.alter(table: Channel.databaseTableName) { t in
                t.add(column: "catchupMode", .text)
                t.add(column: "catchupSource", .text)
            }
        }

        migrator.registerMigration("v5") { db in
            try db.create(table: Movie.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("categoryID", .integer).references(MediaCategory.databaseTableName, onDelete: .setNull)
                t.column("stableKey", .text).notNull()
                t.column("name", .text).notNull()
                t.column("posterURL", .text)
                t.column("rating", .double)
                t.column("addedAt", .datetime)
                t.column("containerExtension", .text)
                t.column("xtreamStreamID", .integer)
                t.column("streamURL", .text)
                t.column("year", .integer)
                t.column("userAgent", .text)
                t.column("referrer", .text)
                t.column("sortIndex", .integer).notNull()
                t.column("plot", .text)
                t.column("cast", .text)
                t.column("director", .text)
                t.column("genre", .text)
                t.column("durationSeconds", .integer)
                t.column("backdropURL", .text)
                t.column("trailer", .text)
                t.column("detailsFetchedAt", .datetime)
            }
            try db.create(index: "movie_source_category", on: Movie.databaseTableName,
                          columns: ["sourceID", "categoryID", "sortIndex"])
            try db.create(index: "movie_categoryID", on: Movie.databaseTableName, columns: ["categoryID"])
            try db.create(index: "movie_source_stableKey", on: Movie.databaseTableName, columns: ["sourceID", "stableKey"])
        }

        migrator.registerMigration("v6") { db in
            // Favorites and history point at items by stableKey, not id: a sync deletes and reinserts a
            // source's rows, and these must survive that.
            try db.create(table: Favorite.databaseTableName) { t in
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("stableKey", .text).notNull()
                t.column("sortIndex", .integer).notNull()
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["sourceID", "kind", "stableKey"])
            }
            try db.create(table: RecentItem.databaseTableName) { t in
                t.column("sourceID", .integer).notNull().references(Source.databaseTableName, onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("stableKey", .text).notNull()
                t.column("playedAt", .datetime).notNull()
                t.primaryKey(["sourceID", "kind", "stableKey"])
            }
            try db.create(index: "recentItem_playedAt", on: RecentItem.databaseTableName, columns: ["playedAt"])
            try db.create(index: "channel_source_stableKey", on: Channel.databaseTableName, columns: ["sourceID", "stableKey"])
            // Finds the channel a programme search result is on.
            try db.create(index: "channel_source_guideID", on: Channel.databaseTableName, columns: ["sourceID", "guideID"])

            // Full-text indexes over channel and movie names and programme titles, with diacritics folded so "cafe"
            // finds "Café". They read their text from the tables (external content), and are rebuilt after
            // each bulk write rather than kept in step by triggers: with triggers, resyncing 100,000 channels
            // took seven times longer, and the index they left behind made searches slower.
            try db.create(virtualTable: Self.channelSearchTable, using: FTS5()) { t in
                t.content = Channel.databaseTableName
                t.contentRowID = "id"
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("name")
            }
            try db.create(virtualTable: Self.programmeSearchTable, using: FTS5()) { t in
                t.content = Programme.databaseTableName
                t.contentRowID = "id"
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
            }
            try db.create(virtualTable: Self.movieSearchTable, using: FTS5()) { t in
                t.content = Movie.databaseTableName
                t.contentRowID = "id"
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("name")
            }
            for table in [Self.channelSearchTable, Self.movieSearchTable, Self.programmeSearchTable] {
                try rebuildSearchIndex(db, table)
            }
        }

        migrator.registerMigration("v7") { db in
            // The user's changes to categories. A sync replaces the rows, and carries these over by remoteID.
            try db.alter(table: MediaCategory.databaseTableName) { t in
                t.add(column: "customName", .text)
                t.add(column: "customSortIndex", .integer)
                t.add(column: "isLocked", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: Source.databaseTableName) { t in
                t.add(column: "accountExpiresAt", .datetime)
            }
        }

        return migrator
    }

    static let channelSearchTable = "channelSearch"
    static let movieSearchTable = "movieSearch"
    static let programmeSearchTable = "programmeSearch"

    /// Re-reads the indexed text of every row. Call after any write that adds, removes or renames
    /// channels, movies or programmes. Rebuilding 100,000 channels takes about a quarter of a second.
    static func rebuildSearchIndex(_ db: Database, _ table: String) throws {
        try db.execute(sql: "INSERT INTO \(table)(\(table)) VALUES('rebuild')")
    }
}

// MARK: - Record conformances

extension Source: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "source"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Source.Kind: DatabaseValueConvertible {}

extension EnginePreference: DatabaseValueConvertible {}

extension MediaCategory: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "mediaCategory"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension MediaCategory.Kind: DatabaseValueConvertible {}

extension Channel: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "channel"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Movie: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "movie"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension MovieSummary: FetchableRecord {
    static let columns = ["id", "sourceID", "stableKey", "name", "posterURL", "rating", "year"].map { Column($0) }
}

extension ItemKind: DatabaseValueConvertible {}

extension Favorite: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "favorite"
}

extension RecentItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recentItem"
}

extension GuideChannel: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "epgChannel"
}

extension Programme: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "programme"

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
