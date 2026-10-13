// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Every type decodes leniently (see LossyDecoding.swift). Only the identifiers each type cannot do
// without are required; a missing one fails that element, which `lossyArray` then skips.

public struct XtreamAccount: Decodable, Sendable, Hashable {
    public var user: XtreamUserInfo
    public var server: XtreamServerInfo?

    enum CodingKeys: String, CodingKey {
        case user = "user_info"
        case server = "server_info"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(XtreamUserInfo.self, forKey: .user)
        server = container.lossyObject(XtreamServerInfo.self, .server)
    }
}

public struct XtreamUserInfo: Decodable, Sendable, Hashable {
    public var username: String?
    public var isAuthenticated: Bool
    /// Usually `Active`, `Expired`, `Banned` or `Disabled`.
    public var status: String?
    public var expiresAt: Date?
    public var isTrial: Bool
    public var activeConnections: Int?
    public var maxConnections: Int?
    public var createdAt: Date?
    public var allowedOutputFormats: [String]

    enum CodingKeys: String, CodingKey {
        case username, auth, status
        case expiresAt = "exp_date"
        case isTrial = "is_trial"
        case activeConnections = "active_cons"
        case maxConnections = "max_connections"
        case createdAt = "created_at"
        case allowedOutputFormats = "allowed_output_formats"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = container.lossyString(.username)
        isAuthenticated = container.lossyBool(.auth)
        status = container.lossyString(.status)
        expiresAt = container.lossyUnixDate(.expiresAt)
        isTrial = container.lossyBool(.isTrial)
        activeConnections = container.lossyInt(.activeConnections)
        maxConnections = container.lossyInt(.maxConnections)
        createdAt = container.lossyUnixDate(.createdAt)
        allowedOutputFormats = container.lossyStrings(.allowedOutputFormats)
    }

    public var isActive: Bool { status.map { $0.caseInsensitiveCompare("Active") == .orderedSame } ?? true }
}

public struct XtreamServerInfo: Decodable, Sendable, Hashable {
    public var url: String?
    public var port: String?
    public var httpsPort: String?
    public var serverProtocol: String?
    public var timezone: String?
    public var timestampNow: Date?

    enum CodingKeys: String, CodingKey {
        case url, port, timezone
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case timestampNow = "timestamp_now"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lossyString(.url)
        port = container.lossyString(.port)
        httpsPort = container.lossyString(.httpsPort)
        serverProtocol = container.lossyString(.serverProtocol)
        timezone = container.lossyString(.timezone)
        timestampNow = container.lossyUnixDate(.timestampNow)
    }

    public var timeZone: TimeZone? { timezone.flatMap(TimeZone.init(identifier:)) }
}

public struct XtreamCategory: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var parentID: Int?

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentID = "parent_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lossyString(.id) else {
            throw DecodingError.valueNotFound(String.self, .init(codingPath: [CodingKeys.id], debugDescription: "Missing category_id"))
        }
        self.id = id
        name = container.lossyString(.name) ?? id
        parentID = container.lossyInt(.parentID)
    }
}

public struct XtreamLiveStream: Decodable, Sendable, Hashable {
    public var number: Int?
    public var name: String
    public var streamID: Int
    public var icon: String?
    public var epgChannelID: String?
    public var categoryID: String?
    public var hasArchive: Bool
    public var archiveDays: Int?
    public var directSource: String?

    enum CodingKeys: String, CodingKey {
        case number = "num"
        case name, icon = "stream_icon"
        case streamID = "stream_id"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
        case hasArchive = "tv_archive"
        case archiveDays = "tv_archive_duration"
        case directSource = "direct_source"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let streamID = container.lossyInt(.streamID) else {
            throw DecodingError.valueNotFound(Int.self, .init(codingPath: [CodingKeys.streamID], debugDescription: "Missing stream_id"))
        }
        self.streamID = streamID
        number = container.lossyInt(.number)
        name = container.lossyString(.name) ?? "Channel \(streamID)"
        icon = container.lossyString(.icon)
        epgChannelID = container.lossyString(.epgChannelID)
        categoryID = container.lossyString(.categoryID)
        hasArchive = container.lossyBool(.hasArchive)
        archiveDays = container.lossyInt(.archiveDays)
        directSource = container.lossyString(.directSource)
    }
}

public struct XtreamVODStream: Decodable, Sendable, Hashable {
    public var number: Int?
    public var name: String
    public var streamID: Int
    public var icon: String?
    public var rating: Double?
    public var added: Date?
    public var categoryID: String?
    public var containerExtension: String?
    public var directSource: String?

    enum CodingKeys: String, CodingKey {
        case number = "num"
        case name, rating, added
        case streamID = "stream_id"
        case icon = "stream_icon"
        case categoryID = "category_id"
        case containerExtension = "container_extension"
        case directSource = "direct_source"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let streamID = container.lossyInt(.streamID) else {
            throw DecodingError.valueNotFound(Int.self, .init(codingPath: [CodingKeys.streamID], debugDescription: "Missing stream_id"))
        }
        self.streamID = streamID
        number = container.lossyInt(.number)
        name = container.lossyString(.name) ?? "Movie \(streamID)"
        icon = container.lossyString(.icon)
        rating = container.lossyDouble(.rating)
        added = container.lossyUnixDate(.added)
        categoryID = container.lossyString(.categoryID)
        containerExtension = container.lossyString(.containerExtension)
        directSource = container.lossyString(.directSource)
    }
}

public struct XtreamVODInfo: Decodable, Sendable, Hashable {
    public var details: XtreamMediaDetails?
    public var streamID: Int?
    public var containerExtension: String?

    enum CodingKeys: String, CodingKey {
        case details = "info"
        case movieData = "movie_data"
    }

    enum MovieDataKeys: String, CodingKey {
        case streamID = "stream_id"
        case containerExtension = "container_extension"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        details = container.lossyObject(XtreamMediaDetails.self, .details)
        if let movieData = try? container.nestedContainer(keyedBy: MovieDataKeys.self, forKey: .movieData) {
            streamID = movieData.lossyInt(.streamID)
            containerExtension = movieData.lossyString(.containerExtension)
        }
    }
}

/// Descriptive metadata from `get_vod_info` and `get_series_info`, which use slightly different keys.
public struct XtreamMediaDetails: Decodable, Sendable, Hashable {
    public var name: String?
    public var originalName: String?
    public var cover: String?
    public var backdrops: [String]
    public var releaseDate: String?
    public var youtubeTrailer: String?
    public var director: String?
    public var cast: String?
    public var plot: String?
    public var genre: String?
    public var durationSeconds: Int?
    public var rating: Double?
    public var tmdbID: String?

    enum CodingKeys: String, CodingKey {
        case name, director, cast, actors, plot, description, genre, rating
        case originalName = "o_name"
        case cover
        case coverBig = "cover_big"
        case movieImage = "movie_image"
        case backdrops = "backdrop_path"
        case releaseDate = "releasedate"
        case releaseDateCamel = "releaseDate"
        case releaseDateAlt = "release_date"
        case youtubeTrailer = "youtube_trailer"
        case durationSeconds = "duration_secs"
        case tmdbID = "tmdb_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lossyString(.name)
        originalName = container.lossyString(.originalName)
        cover = container.lossyString(.coverBig) ?? container.lossyString(.movieImage) ?? container.lossyString(.cover)
        backdrops = container.lossyStrings(.backdrops)
        releaseDate = container.lossyString(.releaseDate) ?? container.lossyString(.releaseDateCamel)
            ?? container.lossyString(.releaseDateAlt)
        youtubeTrailer = container.lossyString(.youtubeTrailer)
        director = container.lossyString(.director)
        cast = container.lossyString(.cast) ?? container.lossyString(.actors)
        plot = container.lossyString(.plot) ?? container.lossyString(.description)
        genre = container.lossyString(.genre)
        durationSeconds = container.lossyInt(.durationSeconds)
        rating = container.lossyDouble(.rating)
        tmdbID = container.lossyString(.tmdbID)
    }
}

public struct XtreamSeries: Decodable, Sendable, Hashable {
    public var number: Int?
    public var name: String
    public var seriesID: Int
    public var cover: String?
    public var plot: String?
    public var cast: String?
    public var director: String?
    public var genre: String?
    public var releaseDate: String?
    public var lastModified: Date?
    public var rating: Double?
    public var backdrops: [String]
    public var youtubeTrailer: String?
    public var categoryID: String?

    enum CodingKeys: String, CodingKey {
        case number = "num"
        case name, cover, plot, cast, director, genre, rating
        case seriesID = "series_id"
        case releaseDate
        case releaseDateAlt = "release_date"
        case lastModified = "last_modified"
        case backdrops = "backdrop_path"
        case youtubeTrailer = "youtube_trailer"
        case categoryID = "category_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let seriesID = container.lossyInt(.seriesID) else {
            throw DecodingError.valueNotFound(Int.self, .init(codingPath: [CodingKeys.seriesID], debugDescription: "Missing series_id"))
        }
        self.seriesID = seriesID
        number = container.lossyInt(.number)
        name = container.lossyString(.name) ?? "Series \(seriesID)"
        cover = container.lossyString(.cover)
        plot = container.lossyString(.plot)
        cast = container.lossyString(.cast)
        director = container.lossyString(.director)
        genre = container.lossyString(.genre)
        releaseDate = container.lossyString(.releaseDate) ?? container.lossyString(.releaseDateAlt)
        lastModified = container.lossyUnixDate(.lastModified)
        rating = container.lossyDouble(.rating)
        backdrops = container.lossyStrings(.backdrops)
        youtubeTrailer = container.lossyString(.youtubeTrailer)
        categoryID = container.lossyString(.categoryID)
    }
}

public struct XtreamSeriesInfo: Decodable, Sendable, Hashable {
    public var details: XtreamMediaDetails?
    public var seasons: [XtreamSeason]
    /// All episodes, ordered by season then episode number.
    public var episodes: [XtreamEpisode]

    enum CodingKeys: String, CodingKey {
        case details = "info"
        case seasons, episodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        details = container.lossyObject(XtreamMediaDetails.self, .details)
        seasons = container.lossyArray(XtreamSeason.self, .seasons)

        // Episodes come as `{"1": [...], "2": [...]}`, as `[[...], [...]]`, or as `[]`.
        var episodes: [XtreamEpisode] = []
        if let bySeason = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .episodes) {
            for key in bySeason.allKeys {
                let seasonNumber = Int(key.stringValue)
                for var episode in bySeason.lossyArray(XtreamEpisode.self, key) {
                    episode.season = episode.season ?? seasonNumber
                    episodes.append(episode)
                }
            }
        } else if let nested = try? container.decodeIfPresent([[Lossy<XtreamEpisode>]].self, forKey: .episodes) {
            episodes = nested.flatMap { $0.compactMap(\.value) }
        }
        self.episodes = episodes.sorted {
            ($0.season ?? 0, $0.episodeNumber ?? 0) < ($1.season ?? 0, $1.episodeNumber ?? 0)
        }
    }
}

public struct XtreamSeason: Decodable, Sendable, Hashable {
    public var number: Int
    public var name: String?
    public var episodeCount: Int?
    public var cover: String?
    public var airDate: String?
    public var overview: String?

    enum CodingKeys: String, CodingKey {
        case number = "season_number"
        case name, cover, overview
        case episodeCount = "episode_count"
        case airDate = "air_date"
        case coverBig = "cover_big"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let number = container.lossyInt(.number) else {
            throw DecodingError.valueNotFound(Int.self, .init(codingPath: [CodingKeys.number], debugDescription: "Missing season_number"))
        }
        self.number = number
        name = container.lossyString(.name)
        episodeCount = container.lossyInt(.episodeCount)
        cover = container.lossyString(.coverBig) ?? container.lossyString(.cover)
        airDate = container.lossyString(.airDate)
        overview = container.lossyString(.overview)
    }
}

public struct XtreamEpisode: Decodable, Sendable, Hashable {
    public var id: String
    public var episodeNumber: Int?
    public var title: String
    public var containerExtension: String?
    public var season: Int?
    public var plot: String?
    public var durationSeconds: Int?
    public var image: String?
    public var rating: Double?
    public var releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, season, info
        case episodeNumber = "episode_num"
        case containerExtension = "container_extension"
    }

    enum InfoKeys: String, CodingKey {
        case plot, rating
        case durationSeconds = "duration_secs"
        case image = "movie_image"
        case releaseDate = "releasedate"
        case airDate = "air_date"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lossyString(.id) else {
            throw DecodingError.valueNotFound(String.self, .init(codingPath: [CodingKeys.id], debugDescription: "Missing episode id"))
        }
        self.id = id
        episodeNumber = container.lossyInt(.episodeNumber)
        title = container.lossyString(.title) ?? "Episode \(episodeNumber.map(String.init) ?? id)"
        containerExtension = container.lossyString(.containerExtension)
        season = container.lossyInt(.season)
        if let info = try? container.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = info.lossyString(.plot)
            durationSeconds = info.lossyInt(.durationSeconds)
            image = info.lossyString(.image)
            rating = info.lossyDouble(.rating)
            releaseDate = info.lossyString(.releaseDate) ?? info.lossyString(.airDate)
        }
    }
}

/// A programme from `get_short_epg`. Titles and descriptions arrive base64 encoded.
public struct XtreamEPGListing: Decodable, Sendable, Hashable {
    public var epgID: String?
    public var title: String
    public var description: String?
    public var start: Date
    public var end: Date

    enum CodingKeys: String, CodingKey {
        case title, description
        case epgID = "epg_id"
        case start = "start_timestamp"
        case end = "stop_timestamp"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = container.lossyUnixDate(.start), let end = container.lossyUnixDate(.end) else {
            throw DecodingError.valueNotFound(Date.self, .init(codingPath: [CodingKeys.start], debugDescription: "Missing timestamps"))
        }
        self.start = start
        self.end = end
        epgID = container.lossyString(.epgID)
        title = Self.decodeBase64(container.lossyString(.title)) ?? ""
        description = Self.decodeBase64(container.lossyString(.description))
    }

    static func decodeBase64(_ text: String?) -> String? {
        guard let text else { return nil }
        if let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) {
            return decoded.nonEmpty
        }
        return text.nonEmpty
    }
}

struct XtreamEPGResponse: Decodable {
    var listings: [XtreamEPGListing]

    enum CodingKeys: String, CodingKey {
        case listings = "epg_listings"
    }

    init(from decoder: Decoder) throws {
        listings = try decoder.container(keyedBy: CodingKeys.self).lossyArray(XtreamEPGListing.self, .listings)
    }
}
