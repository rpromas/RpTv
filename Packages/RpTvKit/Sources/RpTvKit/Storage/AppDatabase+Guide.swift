// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

// MARK: - Writes

extension AppDatabase {
    /// Programmes that ended over a day ago are dropped on import, unless a channel matched to their
    /// guide channel has a catch-up archive: then they're kept as many days as it reaches back, up to this.
    static let maxGuideRetentionDays = 7

    /// Replaces a source's guide with the XMLTV file at `file`, in one transaction: if parsing fails,
    /// the previous guide stays. Only programmes of guide channels that some channel of the source
    /// matches are stored, and only as far back as those channels' catch-up reaches (at least a day).
    /// Returns how many programmes were stored.
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
            var count = 0
            // Programmes are stored under the channel id as the guide declares it, whatever its case.
            var declaredIDs: [String: String] = [:]
            // Guides list a channel's programmes together, so remember the last lookup.
            var lastChannel: String?
            var lastID = ""
            var lastCutoff: Date?
            /// Declared id → days kept, for the clean-up below.
            var keptDays: [String: Int] = [:]

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
                    let days = wanted.retentionDays(for: programme.channel)
                    lastCutoff = days.map { now.addingTimeInterval(-Double($0) * 86_400) }
                    if let days { keptDays[lastID] = days }
                }
                guard let lastCutoff else { return }
                if let stop = programme.stop, stop < lastCutoff { return }
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
            for (days, ids) in Dictionary(grouping: keptDays.keys, by: { keptDays[$0]! }) {
                let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86_400
                try db.execute(sql: """
                    DELETE FROM programme
                    WHERE sourceID = ? AND stop < ? AND epgChannelID IN (SELECT value FROM json_each(?))
                    """, arguments: [sourceID, cutoff, Self.jsonArray(ids)])
                count -= db.changesCount
            }

            try Self.resolveGuideIDs(db, sourceID: sourceID)
            try Self.rebuildSearchIndex(db, Self.programmeSearchTable)
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
        try Row.fetchAll(db, sql: "SELECT id, epgChannelID, epgOverride, name, catchupDays, guideID FROM channel WHERE sourceID = ?",
                         arguments: [sourceID]).map { row in
            let catchupDays: Int? = row["catchupDays"]
            let target = GuideMatcher.Target(epgChannelID: row["epgChannelID"], epgOverride: row["epgOverride"], name: row["name"],
                                             retentionDays: min(max(catchupDays ?? 1, 1), maxGuideRetentionDays))
            return (row["id"], target, row["guideID"])
        }
    }

    /// `strings` as a JSON array, for `json_each`.
    static func jsonArray(_ strings: some Sequence<String>) -> String {
        String(decoding: try! JSONEncoder().encode(Array(strings)), as: UTF8.self)
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

extension AppDatabase {
    /// The guide grid's programmes for the guide channels `guideIDs` that overlap `window`, keyed by guide id
    /// and ordered by start. Only what a grid cell shows is loaded; ``programme(id:)`` has the rest.
    public func observeGuide(sourceID: Int64, guideIDs: Set<String>, window: DateInterval)
        -> AsyncThrowingStream<[String: [GuideSlot]], Error> {
        let ids = Self.jsonArray(guideIDs)
        let from = Int64(window.start.timeIntervalSince1970)
        let to = Int64(window.end.timeIntervalSince1970)
        return observe { db in
            guard !guideIDs.isEmpty else { return [:] }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, epgChannelID, start, stop, title, category FROM programme
                WHERE sourceID = ? AND epgChannelID IN (SELECT value FROM json_each(?))
                  AND start < ? AND COALESCE(stop, start + 3600) > ?
                ORDER BY epgChannelID, start
                """, arguments: [sourceID, ids, to, from])
            var result: [String: [GuideSlot]] = [:]
            while let row = try rows.next() {
                let stop: Int64? = row["stop"]
                result[row["epgChannelID"] as String, default: []].append(GuideSlot(
                    id: row["id"],
                    start: Date(timeIntervalSince1970: TimeInterval(row["start"] as Int64)),
                    stop: stop.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    title: row["title"],
                    category: row["category"]))
            }
            return result
        }
    }

    /// From the earliest start to the latest end of the programmes of `guideIDs`, or nil when there are none.
    /// A programme with no known end counts as lasting an hour.
    public func observeGuideRange(sourceID: Int64, guideIDs: Set<String>) -> AsyncThrowingStream<DateInterval?, Error> {
        let ids = Self.jsonArray(guideIDs)
        return observe { db in
            guard !guideIDs.isEmpty,
                  let row = try Row.fetchOne(db, sql: """
                      SELECT MIN(start) AS first, MAX(COALESCE(stop, start + 3600)) AS last FROM programme
                      WHERE sourceID = ? AND epgChannelID IN (SELECT value FROM json_each(?))
                      """, arguments: [sourceID, ids]),
                  let first = row["first"] as Int64?, let last = row["last"] as Int64?
            else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: TimeInterval(first)),
                                end: Date(timeIntervalSince1970: TimeInterval(max(last, first))))
        }
    }

    public func programme(id: Int64) async throws -> Programme? {
        try await reader.read { db in try Programme.fetchOne(db, key: id) }
    }

    public func channel(sourceID: Int64, stableKey: String) async throws -> Channel? {
        try await reader.read { db in
            try Channel.filter(Column("sourceID") == sourceID && Column("stableKey") == stableKey).fetchOne(db)
        }
    }
}
