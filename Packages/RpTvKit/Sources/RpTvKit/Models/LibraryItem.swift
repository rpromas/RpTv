// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What a favorite, a recently watched entry or watch progress points at.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case channel
    case movie
    case series
    /// Only progress points at episodes: favorites and recents name the series.
    case episode
}

/// Names a channel, movie, series or episode in a way that survives resyncs: a sync deletes and reinserts rows,
/// so their ids change, but the `stableKey` doesn't.
public struct ItemKey: Codable, Sendable, Hashable {
    public var sourceID: Int64
    public var kind: ItemKind
    public var stableKey: String

    public init(sourceID: Int64, kind: ItemKind, stableKey: String) {
        self.sourceID = sourceID
        self.kind = kind
        self.stableKey = stableKey
    }
}

extension Channel {
    public var itemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .channel, stableKey: stableKey)
    }
}

extension Movie {
    public var itemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .movie, stableKey: stableKey)
    }
}

extension MovieSummary {
    public var itemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .movie, stableKey: stableKey)
    }
}

extension Series {
    public var itemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .series, stableKey: stableKey)
    }
}

extension SeriesSummary {
    public var itemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .series, stableKey: stableKey)
    }
}

extension Episode {
    public var itemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .episode, stableKey: stableKey)
    }

    /// The series the episode belongs to.
    public var seriesItemKey: ItemKey {
        ItemKey(sourceID: sourceID, kind: .series, stableKey: seriesKey)
    }
}

/// An item the user starred. Favorites are listed in the order the user put them in.
public struct Favorite: Codable, Sendable, Hashable {
    public var sourceID: Int64
    public var kind: ItemKind
    public var stableKey: String
    public var sortIndex: Int
    public var addedAt: Date

    public init(_ key: ItemKey, sortIndex: Int, addedAt: Date = .now) {
        self.sourceID = key.sourceID
        self.kind = key.kind
        self.stableKey = key.stableKey
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }

    public var key: ItemKey { ItemKey(sourceID: sourceID, kind: kind, stableKey: stableKey) }
}

/// An item the user played, and when they last did.
public struct RecentItem: Codable, Sendable, Hashable {
    public var sourceID: Int64
    public var kind: ItemKind
    public var stableKey: String
    public var playedAt: Date

    public init(_ key: ItemKey, playedAt: Date = .now) {
        self.sourceID = key.sourceID
        self.kind = key.kind
        self.stableKey = key.stableKey
        self.playedAt = playedAt
    }

    public var key: ItemKey { ItemKey(sourceID: sourceID, kind: kind, stableKey: stableKey) }
}
