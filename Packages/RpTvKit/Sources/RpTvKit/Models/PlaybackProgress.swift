// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// How far the user got into a movie or an episode. Points at the item by `stableKey`, like favorites, so it
/// survives resyncs.
public struct PlaybackProgress: Codable, Sendable, Hashable {
    public var sourceID: Int64
    public var kind: ItemKind
    public var stableKey: String
    /// Seconds from the start.
    public var position: TimeInterval
    /// Seconds, or 0 while unknown.
    public var duration: TimeInterval
    public var updatedAt: Date
    public var isWatched: Bool

    public init(_ key: ItemKey, position: TimeInterval, duration: TimeInterval, updatedAt: Date = .now, isWatched: Bool = false) {
        self.sourceID = key.sourceID
        self.kind = key.kind
        self.stableKey = key.stableKey
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.isWatched = isWatched
    }

    public var key: ItemKey { ItemKey(sourceID: sourceID, kind: kind, stableKey: stableKey) }

    /// Past this share of its length, an item counts as watched.
    public static let watchedThreshold = 0.95
    /// Less than this far in, there's nothing worth resuming.
    public static let minimumResumePosition: TimeInterval = 10

    /// Whether `position` of `duration` is far enough to count as watched.
    public static func isWatched(position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && position >= duration * watchedThreshold
    }

    /// Where playback should pick up, or `nil` to start from the beginning: watched items start over.
    public var resumePosition: TimeInterval? {
        guard !isWatched, position >= Self.minimumResumePosition else { return nil }
        return position
    }

    /// How much of the item has been played, from 0 to 1, or `nil` when the length is unknown.
    public var fraction: Double? {
        guard duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    /// Seconds left, or `nil` when the length is unknown.
    public var remaining: TimeInterval? {
        duration > 0 ? max(duration - position, 0) : nil
    }
}
