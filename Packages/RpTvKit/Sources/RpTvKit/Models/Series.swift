// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A TV series. Its seasons and episodes are stored apart (``Season``, ``Episode``), keyed by the series'
/// `stableKey`, so a resync that replaces this row keeps them.
public struct Series: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var sourceID: Int64
    public var categoryID: Int64?
    /// Identifies the series across refreshes. Its seasons and episodes point at it by this key.
    public var stableKey: String
    public var name: String
    public var posterURL: String?
    /// The provider's rating, usually out of 10.
    public var rating: Double?
    /// When the provider last changed the series, for "recently added" sorting.
    public var addedAt: Date?
    public var year: Int?
    /// Xtream series are fetched by id (`get_series_info`). M3U series get their episodes from the playlist.
    public var xtreamSeriesID: Int?
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var backdropURL: String?
    /// A YouTube video id or URL.
    public var trailer: String?
    /// Provider order, the tie-breaker for every sort.
    public var sortIndex: Int
    /// When the seasons and episodes were last fetched from the provider (Xtream only).
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
        year: Int? = nil,
        xtreamSeriesID: Int? = nil,
        plot: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        genre: String? = nil,
        backdropURL: String? = nil,
        trailer: String? = nil,
        sortIndex: Int,
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
        self.year = year
        self.xtreamSeriesID = xtreamSeriesID
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.backdropURL = backdropURL
        self.trailer = trailer
        self.sortIndex = sortIndex
        self.detailsFetchedAt = detailsFetchedAt
    }

    /// Whether opening the series should fetch its episodes: only Xtream series are fetched, and only when
    /// they never were or it was over a week ago.
    public func needsDetails(now: Date = .now) -> Bool {
        guard xtreamSeriesID != nil else { return false }
        guard let fetched = detailsFetchedAt else { return true }
        return now.timeIntervalSince(fetched) > Movie.detailsLifetime
    }

    /// The trailer on YouTube. Providers give either the video id or a full URL.
    public var trailerURL: URL? {
        Movie.trailerURL(trailer)
    }
}

/// The few fields a poster grid needs.
public struct SeriesSummary: Codable, Sendable, Hashable, Identifiable {
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

/// A season's name and artwork. Seasons the provider doesn't describe still exist through their episodes.
public struct Season: Codable, Sendable, Hashable {
    public var sourceID: Int64
    /// The `stableKey` of the series.
    public var seriesKey: String
    public var number: Int
    public var name: String?
    public var posterURL: String?
    public var overview: String?
    public var airDate: String?
    public var episodeCount: Int?

    public init(sourceID: Int64, seriesKey: String, number: Int, name: String? = nil, posterURL: String? = nil,
                overview: String? = nil, airDate: String? = nil, episodeCount: Int? = nil) {
        self.sourceID = sourceID
        self.seriesKey = seriesKey
        self.number = number
        self.name = name
        self.posterURL = posterURL
        self.overview = overview
        self.airDate = airDate
        self.episodeCount = episodeCount
    }
}

/// One episode of a series.
public struct Episode: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var sourceID: Int64
    /// The `stableKey` of the series.
    public var seriesKey: String
    /// Identifies the episode across refreshes, for its watch progress.
    public var stableKey: String
    public var season: Int
    public var number: Int?
    public var title: String
    public var plot: String?
    public var durationSeconds: Int?
    /// A still from the episode.
    public var stillURL: String?
    public var rating: Double?
    public var airDate: String?
    public var containerExtension: String?
    /// Xtream episodes are played by id, because their URLs embed the account password. M3U ones use streamURL.
    public var xtreamEpisodeID: String?
    public var streamURL: String?
    public var userAgent: String?
    public var referrer: String?
    /// Order within the series: by season, then episode number.
    public var sortIndex: Int

    public init(
        id: Int64? = nil,
        sourceID: Int64,
        seriesKey: String,
        stableKey: String,
        season: Int,
        number: Int? = nil,
        title: String,
        plot: String? = nil,
        durationSeconds: Int? = nil,
        stillURL: String? = nil,
        rating: Double? = nil,
        airDate: String? = nil,
        containerExtension: String? = nil,
        xtreamEpisodeID: String? = nil,
        streamURL: String? = nil,
        userAgent: String? = nil,
        referrer: String? = nil,
        sortIndex: Int
    ) {
        self.id = id
        self.sourceID = sourceID
        self.seriesKey = seriesKey
        self.stableKey = stableKey
        self.season = season
        self.number = number
        self.title = title
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.stillURL = stillURL
        self.rating = rating
        self.airDate = airDate
        self.containerExtension = containerExtension
        self.xtreamEpisodeID = xtreamEpisodeID
        self.streamURL = streamURL
        self.userAgent = userAgent
        self.referrer = referrer
        self.sortIndex = sortIndex
    }

    /// "S1 E2", or "S1" when the episode has no number.
    public var code: String {
        number.map { "S\(season) E\($0)" } ?? "S\(season)"
    }
}

/// The parts of an episode name such as "Show S01 E02" or "Show 1x02 - Pilot", as M3U playlists write them.
public struct EpisodeName: Sendable, Hashable {
    public var show: String
    public var season: Int
    public var episode: Int
    /// What follows the episode number, if anything: "Pilot" in "Show S01E01 - Pilot".
    public var title: String?

    public init(show: String, season: Int, episode: Int, title: String? = nil) {
        self.show = show
        self.season = season
        self.episode = episode
        self.title = title
    }

    /// Parses "Show S01 E02", "Show S01E02", "Show - s1e2 - Title", "Show.Name.S01.E02" and "Show 1x02" (with a
    /// two-digit episode, so "4x4" isn't one).
    /// Returns `nil` when there's no season and episode, or no show name before them.
    public init?(parsing name: String) {
        let separators = CharacterSet(charactersIn: " ._-:|–—").union(.whitespaces)
        // Simple word boundaries: Unicode ones don't break at the dot in "Name.S01".
        let match = name.firstMatch(of: #/^(.*?)[\s._\-:|]*\b[Ss](\d{1,3})[\s._\-]*[Ee][Pp]?(\d{1,4})(?!\d)(.*)$/#
            .wordBoundaryKind(.simple))
            .map { ($0.1, $0.2, $0.3, $0.4) }
            ?? name.firstMatch(of: #/^(.*?)[\s._\-:|]+(\d{1,2})[xX](\d{2,3})(?!\d)(.*)$/#)
            .map { ($0.1, $0.2, $0.3, $0.4) }
        guard let (rawShow, season, episode, rest) = match,
              let seasonNumber = Int(season), let episodeNumber = Int(episode) else { return nil }
        var show = rawShow.trimmingCharacters(in: separators)
        // "Show.Name.S01E02": dots stand for spaces.
        if !show.contains(" ") { show = show.replacing(".", with: " ").replacing("_", with: " ") }
        guard !show.isEmpty else { return nil }
        self.show = show
        self.season = seasonNumber
        self.episode = episodeNumber
        title = rest.trimmingCharacters(in: separators).nonEmpty
    }
}
