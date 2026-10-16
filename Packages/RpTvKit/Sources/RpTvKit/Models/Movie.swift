// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A movie (video on demand).
public struct Movie: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var sourceID: Int64
    public var categoryID: Int64?
    /// Identifies the movie across refreshes.
    public var stableKey: String
    public var name: String
    public var posterURL: String?
    /// The provider's rating, usually out of 10.
    public var rating: Double?
    /// When the provider added the movie, for "recently added" sorting.
    public var addedAt: Date?
    /// The file type of the stream (`mp4`, `mkv`, …), which Xtream URLs end with.
    public var containerExtension: String?
    /// Xtream movies are played by id, since their URLs embed the password. M3U movies use ``streamURL``.
    public var xtreamStreamID: Int?
    public var streamURL: String?
    public var year: Int?
    public var userAgent: String?
    public var referrer: String?
    /// Provider order, the tie-breaker for every sort.
    public var sortIndex: Int

    // Details, fetched when the movie is opened (Xtream `get_vod_info`) and cached.
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var durationSeconds: Int?
    public var backdropURL: String?
    /// A YouTube video id or URL.
    public var trailer: String?
    public var detailsFetchedAt: Date?

    public init(
        id: Int64? = nil,
        sourceID: Int64,
        categoryID: Int64? = nil,
        stableKey: String,
        name: String,
        posterURL: String? = nil,
        rating: Double? = nil,
        addedAt: Date? = nil,
        containerExtension: String? = nil,
        xtreamStreamID: Int? = nil,
        streamURL: String? = nil,
        year: Int? = nil,
        userAgent: String? = nil,
        referrer: String? = nil,
        sortIndex: Int,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        durationSeconds: Int? = nil,
        backdropURL: String? = nil,
        trailer: String? = nil,
        detailsFetchedAt: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.categoryID = categoryID
        self.stableKey = stableKey
        self.name = name
        self.posterURL = posterURL
        self.rating = rating
        self.addedAt = addedAt
        self.containerExtension = containerExtension
        self.xtreamStreamID = xtreamStreamID
        self.streamURL = streamURL
        self.year = year
        self.userAgent = userAgent
        self.referrer = referrer
        self.sortIndex = sortIndex
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.durationSeconds = durationSeconds
        self.backdropURL = backdropURL
        self.trailer = trailer
        self.detailsFetchedAt = detailsFetchedAt
    }

    /// How long cached details are kept before they're fetched again.
    public static let detailsLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Whether opening the movie should fetch its details: Xtream only, when missing or stale.
    public func needsDetails(now: Date = .now) -> Bool {
        guard xtreamStreamID != nil else { return false }
        guard let fetched = detailsFetchedAt else { return true }
        return now.timeIntervalSince(fetched) > Self.detailsLifetime
    }

    /// The trailer on YouTube. Providers give either the video id or a full URL.
    public var trailerURL: URL? { Self.trailerURL(trailer) }

    static func trailerURL(_ trailer: String?) -> URL? {
        guard let trailer = trailer?.trimmingCharacters(in: .whitespacesAndNewlines), !trailer.isEmpty else { return nil }
        if trailer.contains("://") { return URL(string: trailer) }
        guard trailer.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(trailer)")
    }

    /// A year in a title such as "Heat (1995)" or "Heat - 1995", or `nil`.
    static func year(inTitle title: String) -> Int? {
        guard let match = title.firstMatch(of: #/(?:\(|\[|-\s*)((?:19|20)\d{2})(?:\)|\]|\s*$)/#) else { return nil }
        return Int(match.1)
    }

    /// The year at the start of a release date such as "1999-03-31".
    static func year(inReleaseDate date: String?) -> Int? {
        guard let date, let match = date.firstMatch(of: #/^((?:18|19|20)\d{2})/#) else { return nil }
        return Int(match.1)
    }
}

/// The few fields a poster grid needs, so large grids stay cheap and saving details doesn't refetch them.
public struct MovieSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var sourceID: Int64
    public var stableKey: String
    public var name: String
    public var posterURL: String?
    public var rating: Double?
    public var year: Int?

    public init(id: Int64, sourceID: Int64, stableKey: String, name: String, posterURL: String? = nil,
                rating: Double? = nil, year: Int? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.stableKey = stableKey
        self.name = name
        self.posterURL = posterURL
        self.rating = rating
        self.year = year
    }
}

/// How the movie grid is ordered.
public enum MovieSort: String, Sendable, CaseIterable, Codable {
    /// Newest first.
    case added
    /// A to Z.
    case name
    /// Best rated first.
    case rating
}
