// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Matches playlist channels to guide channels: the user's override first, then the playlist's
/// `tvg-id` / `epg_channel_id` (ignoring case), then the channel name against the guide's display names.
struct GuideMatcher {
    /// What matching needs to know about a playlist channel.
    struct Target: Sendable {
        var epgChannelID: String?
        var epgOverride: String? = nil
        var name: String
        /// Days of past programmes to keep for the guide channel this matches.
        var retentionDays = 1
    }

    /// Lowercased id → the guide's own spelling of it.
    private var ids: [String: String] = [:]
    /// Normalized display name → guide id. The first guide channel to claim a name keeps it.
    private var names: [String: String] = [:]

    init() {}

    init(channels: some Sequence<GuideChannel>) {
        for channel in channels {
            add(id: channel.id, displayNames: channel.names.split(separator: "\n").map(String.init))
        }
    }

    mutating func add(id: String, displayNames: [String]) {
        ids[id.lowercased()] = ids[id.lowercased()] ?? id
        for name in displayNames {
            let key = Self.normalize(name)
            if !key.isEmpty, names[key] == nil { names[key] = id }
        }
    }

    /// The guide id for `target`, or `nil` when the guide doesn't list it.
    func guideID(for target: Target) -> String? {
        if let override = target.epgOverride { return override }
        if let id = target.epgChannelID, let match = ids[id.lowercased()] { return match }
        return names[Self.normalize(target.name)]
    }

    private static let qualitySuffixes: Set<Substring> = ["hd", "fhd", "uhd", "sd", "4k"]

    /// Lowercases, drops accents, punctuation and spaces, and strips trailing quality tags such as
    /// "HD" or "FHD", so "Movie Max FHD" and "movie-max" compare equal.
    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var words = folded.split { !$0.isLetter && !$0.isNumber }
        while words.count > 1, let last = words.last, qualitySuffixes.contains(last) { words.removeLast() }
        return words.joined()
    }
}

/// Decides, while a guide streams in, which programmes to store and how many past days to keep.
///
/// Ids the playlist names are known up front; name matches are added as `<channel>` elements arrive.
struct GuideWantedSet {
    /// Lowercased guide id → days of past programmes to keep.
    private var wanted: [String: Int] = [:]
    /// Normalized names of playlist channels that aren't matched by id → days to keep.
    private var pendingNames: [String: Int] = [:]

    init(targets: [GuideMatcher.Target]) {
        for target in targets {
            if let override = target.epgOverride {
                keep(override, days: target.retentionDays)
            } else {
                if let id = target.epgChannelID { keep(id, days: target.retentionDays) }
                let name = GuideMatcher.normalize(target.name)
                if !name.isEmpty { pendingNames[name] = max(pendingNames[name] ?? 0, target.retentionDays) }
            }
        }
    }

    mutating func add(_ channel: XMLTVChannel) {
        for name in channel.displayNames {
            if let days = pendingNames[GuideMatcher.normalize(name)] { keep(channel.id, days: days) }
        }
    }

    /// Days of past programmes to keep for guide channel `id`, or `nil` when no playlist channel wants it.
    func retentionDays(for id: String) -> Int? {
        wanted[id.lowercased()]
    }

    private mutating func keep(_ id: String, days: Int) {
        wanted[id.lowercased()] = max(wanted[id.lowercased()] ?? 0, days)
    }
}
