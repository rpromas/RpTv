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

        return migrator
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
