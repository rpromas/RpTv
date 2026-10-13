// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

// MARK: - Writes

extension AppDatabase {
    /// Programmes that ended longer ago than this are dropped on import.
    static let guideRetention: TimeInterval = 24 * 3600

    /// Replaces a source's guide with the XMLTV file at `file`, in one transaction: if parsing fails,
    /// the previous guide stays. Only programmes of guide channels that some channel of the source
    /// matches are stored. Returns how many programmes were stored.
    @discardableResult
    public func importGuide(sourceID: Int64, file: URL, now: Date = .now) async throws -> Int {
        try await writer.write { db in
            let targets = try Self.matchTargets(db, sourceID: sourceID).map(\.target)
            var wanted = GuideWantedSet(targets: targets)

            try db.execute(sql: "DELETE FROM programme WHERE sourceID = ?", arguments: [sourceID])
            try db.execute(sql: "DELETE FROM epgChannel WHERE sourceID = ?", arguments: [sourceID])

            let insertChannel = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO epgChannel (sourceID, id, name, names, iconURL) VALUES (?, ?, ?, ?, ?)
                """)
            let insertProgramme = try db.cachedStatement(sql: """
                INSERT INTO programme (sourceID, epgChannelID, start, stop, title, summary, category, iconURL)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let cutoff = now.addingTimeInterval(-Self.guideRetention)
            var count = 0
            // Programmes are stored under the channel id as the guide declares it, whatever its case.
            var declaredIDs: [String: String] = [:]
            // Guides list a channel's programmes together, so remember the last lookup.
            var lastChannel: String?
            var lastID = ""
            var lastWanted = false

            try XMLTVParser.parse(file) { channel in
                wanted.add(channel)
                declaredIDs[channel.id.lowercased()] = declaredIDs[channel.id.lowercased()] ?? channel.id
                lastChannel = nil
                try insertChannel.execute(arguments: [
                    sourceID, channel.id, channel.displayNames.first ?? channel.id,
                    channel.displayNames.joined(separator: "\n"), channel.iconURL,
                ])
            } programme: { programme in
                if programme.channel != lastChannel {
                    lastChannel = programme.channel
                    lastID = declaredIDs[programme.channel.lowercased()] ?? programme.channel
                    lastWanted = wanted.contains(programme.channel)
                }
                guard lastWanted else { return }
                if let stop = programme.stop, stop < cutoff { return }
                try insertProgramme.execute(arguments: [
                    sourceID, lastID, Int64(programme.start.timeIntervalSince1970),
                    programme.stop.map { Int64($0.timeIntervalSince1970) },
                    programme.title, programme.summary, programme.category, programme.iconURL,
                ])
                count += 1
            }

            // A programme without a stop time runs until the next one on its channel.
            try db.execute(sql: """
                UPDATE programme SET stop = (
                    SELECT MIN(next.start) FROM programme next
                    WHERE next.sourceID = programme.sourceID AND next.epgChannelID = programme.epgChannelID
                      AND next.start > programme.start)
                WHERE sourceID = ? AND stop IS NULL
                """, arguments: [sourceID])
            try db.execute(sql: "DELETE FROM programme WHERE sourceID = ? AND stop < ?",
                           arguments: [sourceID, Int64(cutoff.timeIntervalSince1970)])
            count -= db.changesCount

            try Self.resolveGuideIDs(db, sourceID: sourceID)
            return count
        }
    }

    public func recordEPGSync(sourceID: Int64, error: String?, at date: Date = .now) async throws {
        try await writer.write { db in
            guard var source = try Source.fetchOne(db, key: sourceID) else { return }
            if error == nil { source.lastEPGSyncAt = date }
            source.lastEPGSyncError = error
            try source.update(db)
        }
    }

    /// Points each channel of the source at the guide channel it matches (see `GuideMatcher`).
    static func resolveGuideIDs(_ db: Database, sourceID: Int64) throws {
        var matcher = GuideMatcher(channels: try GuideChannel.filter(Column("sourceID") == sourceID).fetchAll(db))
        // Some guides have programmes for channels they never declare; those can still match by id.
        let programmeChannels = try String.fetchAll(db, sql: "SELECT DISTINCT epgChannelID FROM programme WHERE sourceID = ?",
                                                    arguments: [sourceID])
        for id in programmeChannels { matcher.add(id: id, displayNames: []) }

        let update = try db.cachedStatement(sql: "UPDATE channel SET guideID = ? WHERE id = ?")
        for (channelID, target, current) in try matchTargets(db, sourceID: sourceID) {
            let guideID = matcher.guideID(for: target)
            if guideID != current { try update.execute(arguments: [guideID, channelID]) }
        }
    }

    private static func matchTargets(_ db: Database, sourceID: Int64) throws -> [(id: Int64, target: GuideMatcher.Target, guideID: String?)] {
        try Row.fetchAll(db, sql: "SELECT id, epgChannelID, epgOverride, name, guideID FROM channel WHERE sourceID = ?",
                         arguments: [sourceID]).map { row in
            (row["id"], GuideMatcher.Target(epgChannelID: row["epgChannelID"], epgOverride: row["epgOverride"], name: row["name"]), row["guideID"])
        }
    }
}

// MARK: - Reads

extension AppDatabase {
    /// What's on now and next for each of `channelIDs` at `date`, keyed by channel id. Channels
    /// without guide data are left out. One query serves a whole list. A programme with no known
    /// end counts as lasting an hour. Re-subscribe as time passes: the stream only updates when
    /// the database changes.
    public func observeNowNext(channelIDs: [Int64], at date: Date) -> AsyncThrowingStream<[Int64: NowNext], Error> {
        let now = Int64(date.timeIntervalSince1970)
        let horizon = now + 12 * 3600
        let ids = "[" + channelIDs.map(String.init).joined(separator: ",") + "]"
        return observe { db in
            guard !channelIDs.isEmpty else { return [:] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT channel.id AS channelID, programme.*,
                           ROW_NUMBER() OVER (PARTITION BY channel.id ORDER BY programme.start) AS rank
                    FROM channel
                    JOIN programme ON programme.sourceID = channel.sourceID AND programme.epgChannelID = channel.guideID
                    WHERE channel.id IN (SELECT value FROM json_each(?))
                      AND programme.start < ? AND COALESCE(programme.stop, programme.start + 3600) > ?
                )
                WHERE rank <= 2
                ORDER BY channelID, rank
                """, arguments: [ids, horizon, now])
            var result: [Int64: NowNext] = [:]
            for row in rows {
                let channelID: Int64 = row["channelID"]
                let programme = try Programme(row: row)
                var entry = result[channelID] ?? NowNext()
                if entry.now == nil, entry.next == nil, programme.start <= date {
                    entry.now = programme
                } else if entry.next == nil {
                    entry.next = programme
                }
                result[channelID] = entry
            }
            return result
        }
    }
}
