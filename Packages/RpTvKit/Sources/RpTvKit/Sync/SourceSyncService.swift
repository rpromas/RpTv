// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Where a sync is, for progress UI.
public enum SyncPhase: Sendable, Equatable {
    case connecting
    case downloading(itemCount: Int)
    case saving(itemCount: Int)
    case finished(itemCount: Int)
}

public enum SyncError: LocalizedError, Equatable {
    case missingPassword
    case invalidLocation
    case emptyPlaylist

    public var errorDescription: String? {
        switch self {
        case .missingPassword: "The saved password for this account is missing. Edit the source and enter it again."
        case .invalidLocation: "The playlist address isn't valid."
        case .emptyPlaylist: "The playlist doesn't contain any channels, movies or series."
        }
    }
}

/// Downloads a source's catalog and stores it.
public struct SourceSyncService: Sendable {
    private let database: AppDatabase
    private let credentials: any CredentialStore
    private let http: any HTTPClient
    private let session: URLSession
    /// Where imported M3U files are kept.
    public let playlistDirectory: URL

    public init(
        database: AppDatabase,
        credentials: any CredentialStore,
        playlistDirectory: URL,
        session: URLSession = .shared,
        http: (any HTTPClient)? = nil
    ) {
        self.database = database
        self.credentials = credentials
        self.playlistDirectory = playlistDirectory
        self.session = session
        self.http = http ?? session
    }

    /// Refreshes a source and returns how many channels, movies and series it now has. Records the outcome on the source.
    @discardableResult
    public func sync(_ source: Source, progress: @escaping @Sendable (SyncPhase) -> Void = { _ in }) async throws -> Int {
        guard let sourceID = source.id else { preconditionFailure("Sync requires a saved source") }
        progress(.connecting)
        do {
            let catalog: SourceCatalog
            switch source.kind {
            case .m3u: catalog = try await loadM3U(source, progress: progress)
            case .xtream: catalog = try await loadXtream(source, progress: progress)
            }
            progress(.saving(itemCount: catalog.itemCount))
            try await database.replaceCatalog(sourceID: sourceID, with: catalog)
            try await database.recordSync(sourceID: sourceID, error: nil)
            progress(.finished(itemCount: catalog.itemCount))
            return catalog.itemCount
        } catch {
            if !(error is CancellationError) {
                try? await database.recordSync(sourceID: sourceID, error: error.localizedDescription)
            }
            throw error
        }
    }

    /// Fetches a movie's details from the provider and caches them, if they're missing or over a week old.
    /// Only Xtream movies have details; for the others this does nothing.
    public func refreshDetails(of movie: Movie, in source: Source, now: Date = .now) async throws {
        guard movie.needsDetails(now: now), let streamID = movie.xtreamStreamID, source.kind == .xtream else { return }
        let client = XtreamClient(credentials: try xtreamCredentials(for: source), http: http, headers: source.httpHeaders)
        let info = try await client.vodInfo(streamID: streamID)
        try await database.saveMovieDetails(sourceID: movie.sourceID, stableKey: movie.stableKey, details: info, fetchedAt: now)
    }

    /// Fetches a series' seasons and episodes from the provider and caches them, if they're missing or over a week
    /// old. Only Xtream series are fetched; M3U ones got their episodes from the playlist.
    public func refreshDetails(of series: Series, in source: Source, now: Date = .now) async throws {
        guard series.needsDetails(now: now), let seriesID = series.xtreamSeriesID, source.kind == .xtream else { return }
        let client = XtreamClient(credentials: try xtreamCredentials(for: source), http: http, headers: source.httpHeaders)
        let info = try await client.seriesInfo(seriesID: seriesID)
        try await database.saveSeriesDetails(sourceID: series.sourceID, stableKey: series.stableKey, info: info, fetchedAt: now)
    }

    /// The Xtream account's status from the server, even when it has expired or been disabled. Also stores its
    /// expiry date on the source.
    public func accountStatus(of source: Source) async throws -> XtreamAccount {
        let client = XtreamClient(credentials: try xtreamCredentials(for: source), http: http, headers: source.httpHeaders)
        let account = try await client.accountInfo()
        if let id = source.id {
            let expiresAt = account.user.expiresAt
            try await database.modifySource(id: id) { $0.accountExpiresAt = expiresAt }
        }
        return account
    }

    public func xtreamCredentials(for source: Source) throws -> XtreamCredentials {
        try Self.xtreamCredentials(for: source, in: credentials)
    }

    static func xtreamCredentials(for source: Source, in credentials: any CredentialStore) throws -> XtreamCredentials {
        guard let key = source.credentialKey, let password = try credentials.password(for: key) else {
            throw SyncError.missingPassword
        }
        guard let server = XtreamCredentials.normalizeServer(source.location) else { throw XtreamError.invalidServer }
        return XtreamCredentials(server: server, username: source.username ?? "", password: password)
    }

    // MARK: - M3U

    private func loadM3U(_ source: Source, progress: @escaping @Sendable (SyncPhase) -> Void) async throws -> SourceCatalog {
        var parser = M3UParser()
        var builder = M3UCatalogBuilder()

        func consume(_ line: String) {
            if let entry = parser.consume(line) {
                builder.add(entry)
                if builder.count.isMultiple(of: 1000) { progress(.downloading(itemCount: builder.count)) }
            }
        }

        if source.isLocalFile {
            for try await line in playlistDirectory.appending(component: source.location).lines {
                consume(line)
            }
        } else {
            guard let url = URL(string: source.location), url.scheme != nil else { throw SyncError.invalidLocation }
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, headers: source.httpHeaders))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw HTTPError.status(http.statusCode)
            }
            for try await line in bytes.lines {
                consume(line)
            }
        }

        guard builder.count > 0 else { throw SyncError.emptyPlaylist }

        // Remember the guide the playlist advertises unless the user set one.
        if source.epgURL == nil, let epgURL = parser.header.epgURLs.first, var updated = try await database.source(id: source.id!) {
            updated.epgURL = epgURL
            try await database.updateSource(updated)
        }
        return builder.catalog
    }

    // MARK: - Xtream

    private func loadXtream(_ source: Source, progress: @escaping @Sendable (SyncPhase) -> Void) async throws -> SourceCatalog {
        let client = XtreamClient(credentials: try xtreamCredentials(for: source), http: http, headers: source.httpHeaders)
        let account = try await client.authenticate()

        let formats = account.user.allowedOutputFormats
        let timeZone = account.server?.timezone
        let expiresAt = account.user.expiresAt
        try await database.modifySource(id: source.id!) { updated in
            if updated.liveFormat == nil {
                updated.liveFormat = formats.isEmpty || formats.contains("m3u8") ? "m3u8" : "ts"
            }
            // Catch-up URLs need it, and a server can move zones, so it's refreshed every time.
            updated.serverTimeZone = timeZone
            updated.accountExpiresAt = expiresAt
        }

        async let categories = client.liveCategories()
        async let streams = client.liveStreams()
        async let movies = Self.xtreamMovies(client)
        async let series = Self.xtreamSeries(client)
        let (liveCategories, liveStreams) = try await (categories, streams)
        progress(.downloading(itemCount: liveStreams.count))
        let movieCatalog = await movies
        progress(.downloading(itemCount: liveStreams.count + (movieCatalog?.items.count ?? 0)))
        let seriesCatalog = await series
        let catalog = SourceCatalog(live: Self.xtreamCatalog(categories: liveCategories, streams: liveStreams),
                                    movies: movieCatalog, series: seriesCatalog)
        progress(.downloading(itemCount: catalog.itemCount))
        return catalog
    }

    /// The account's series, or `nil` when they couldn't be downloaded, like ``xtreamMovies(_:)``.
    private static func xtreamSeries(_ client: XtreamClient) async -> SeriesCatalog? {
        async let categories = client.seriesCategories()
        async let series = client.series()
        guard let (seriesCategories, seriesList) = try? await (categories, series) else { return nil }
        return xtreamSeriesCatalog(categories: seriesCategories, series: seriesList)
    }

    static func xtreamSeriesCatalog(categories: [XtreamCategory], series: [XtreamSeries]) -> SeriesCatalog {
        let groups = categories.map { CatalogGroup(remoteID: $0.id, name: $0.name) }
        let items = series.enumerated().map { index, series in
            SeriesCatalog.Item(
                series: Series(
                    sourceID: 0,
                    stableKey: "xtream-series:\(series.seriesID)",
                    name: series.name,
                    posterURL: series.cover,
                    rating: series.rating.flatMap { $0 > 0 ? $0 : nil },
                    addedAt: series.lastModified,
                    year: Movie.year(inReleaseDate: series.releaseDate) ?? Movie.year(inTitle: series.name),
                    xtreamSeriesID: series.seriesID,
                    plot: series.plot,
                    cast: series.cast,
                    director: series.director,
                    genre: series.genre,
                    backdropURL: series.backdrops.first,
                    trailer: series.youtubeTrailer,
                    sortIndex: index
                ),
                groupRemoteID: series.categoryID
            )
        }
        return SeriesCatalog(groups: groups, items: items, includesEpisodes: false)
    }

    /// The account's movies, or `nil` when they couldn't be downloaded. Some accounts have live TV only and
    /// their servers fail the movie calls, which mustn't stop the channels from updating.
    private static func xtreamMovies(_ client: XtreamClient) async -> MovieCatalog? {
        async let categories = client.vodCategories()
        async let streams = client.vodStreams()
        guard let (vodCategories, vodStreams) = try? await (categories, streams) else { return nil }
        return xtreamMovieCatalog(categories: vodCategories, streams: vodStreams)
    }

    static func xtreamMovieCatalog(categories: [XtreamCategory], streams: [XtreamVODStream]) -> MovieCatalog {
        let groups = categories.map { CatalogGroup(remoteID: $0.id, name: $0.name) }
        let items = streams.enumerated().map { index, stream in
            MovieCatalog.Item(
                movie: Movie(
                    sourceID: 0,
                    stableKey: "xtream-movie:\(stream.streamID)",
                    name: stream.name,
                    posterURL: stream.icon,
                    rating: stream.rating.flatMap { $0 > 0 ? $0 : nil },
                    addedAt: stream.added,
                    containerExtension: stream.containerExtension,
                    xtreamStreamID: stream.streamID,
                    year: stream.year ?? Movie.year(inTitle: stream.name),
                    sortIndex: index
                ),
                groupRemoteID: stream.categoryID
            )
        }
        return MovieCatalog(groups: groups, items: items)
    }

    static func xtreamCatalog(categories: [XtreamCategory], streams: [XtreamLiveStream]) -> LiveCatalog {
        let groups = categories.map { CatalogGroup(remoteID: $0.id, name: $0.name) }
        let items = streams.enumerated().map { index, stream in
            LiveCatalog.Item(
                channel: Channel(
                    sourceID: 0,
                    stableKey: "xtream:\(stream.streamID)",
                    name: stream.name,
                    number: stream.number,
                    logoURL: stream.icon,
                    xtreamStreamID: stream.streamID,
                    epgChannelID: stream.epgChannelID,
                    catchupDays: stream.hasArchive ? stream.archiveDays : nil,
                    sortIndex: index
                ),
                groupRemoteID: stream.categoryID
            )
        }
        return LiveCatalog(groups: groups, items: items)
    }
}

/// Turns M3U entries into a catalog: channels, movies and series, each with a category per `group-title` in order
/// of first appearance. Episodes are gathered into series by the show name in their titles ("Show S01 E02"),
/// within their group.
struct M3UCatalogBuilder {
    static let ungroupedID = ""

    private var liveGroups = GroupList()
    private var movieGroups = GroupList()
    private var seriesGroups = GroupList()
    private var channels: [LiveCatalog.Item] = []
    private var movies: [MovieCatalog.Item] = []
    private var series: [SeriesCatalog.Item] = []
    /// Index in `series` by stableKey.
    private var seriesIndex: [String: Int] = [:]
    private var episodeKeys: Set<String> = []
    private var episodeCount = 0

    var count: Int { channels.count + movies.count + episodeCount }

    mutating func add(_ entry: M3UEntry) {
        let groupID = entry.group ?? Self.ungroupedID
        let groupName = entry.group ?? "Uncategorized"
        var kind = entry.contentKind
        let episodeName = kind == .episode ? entry.episodeName : nil
        if kind == .episode, episodeName == nil { kind = .movie }
        switch kind {
        case .episode:
            guard let episodeName else { return }
            seriesGroups.add(groupID, name: groupName)
            addEpisode(entry, named: episodeName, groupID: groupID)
        case .live:
            liveGroups.add(groupID, name: groupName)
            let channel = Channel(
                sourceID: 0,
                stableKey: "m3u:\(entry.tvgID ?? "")|\(entry.name)|\(groupID)",
                name: entry.name,
                number: entry.channelNumber,
                logoURL: entry.logo,
                streamURL: entry.url,
                epgChannelID: entry.tvgID,
                catchupDays: entry.catchupDays,
                catchupMode: entry.catchupMode,
                catchupSource: entry.catchupSource,
                userAgent: entry.userAgent,
                referrer: entry.referrer,
                sortIndex: channels.count
            )
            channels.append(LiveCatalog.Item(channel: channel, groupRemoteID: groupID))
        case .movie:
            movieGroups.add(groupID, name: groupName)
            let fileExtension = ((URLComponents(string: entry.url)?.path ?? "") as NSString).pathExtension.lowercased()
            let movie = Movie(
                sourceID: 0,
                stableKey: "m3u-movie:\(entry.name)|\(groupID)",
                name: entry.name,
                posterURL: entry.logo,
                containerExtension: fileExtension.isEmpty ? nil : fileExtension,
                streamURL: entry.url,
                year: Movie.year(inTitle: entry.name),
                userAgent: entry.userAgent,
                referrer: entry.referrer,
                sortIndex: movies.count
            )
            movies.append(MovieCatalog.Item(movie: movie, groupRemoteID: groupID))
        }
    }

    private mutating func addEpisode(_ entry: M3UEntry, named name: EpisodeName, groupID: String) {
        let seriesKey = "m3u-series:\(name.show)|\(groupID)"
        let index: Int
        if let existing = seriesIndex[seriesKey] {
            index = existing
        } else {
            index = series.count
            seriesIndex[seriesKey] = index
            series.append(SeriesCatalog.Item(
                series: Series(sourceID: 0, stableKey: seriesKey, name: name.show, posterURL: entry.logo,
                               year: Movie.year(inTitle: name.show), sortIndex: index),
                groupRemoteID: groupID))
        }
        // The same episode listed twice (say, in two qualities) gets a key of its own.
        var stableKey = "m3u-episode:\(name.show)|\(groupID)|\(name.season)x\(name.episode)"
        var duplicate = 1
        while !episodeKeys.insert(stableKey).inserted {
            duplicate += 1
            stableKey = "m3u-episode:\(name.show)|\(groupID)|\(name.season)x\(name.episode)#\(duplicate)"
        }
        let fileExtension = ((URLComponents(string: entry.url)?.path ?? "") as NSString).pathExtension.lowercased()
        series[index].episodes.append(Episode(
            sourceID: 0,
            seriesKey: seriesKey,
            stableKey: stableKey,
            season: name.season,
            number: name.episode,
            title: name.title ?? "Episode \(name.episode)",
            durationSeconds: entry.duration.flatMap { $0 > 0 ? $0 : nil },
            stillURL: entry.logo,
            containerExtension: fileExtension.isEmpty ? nil : fileExtension,
            streamURL: entry.url,
            userAgent: entry.userAgent,
            referrer: entry.referrer,
            sortIndex: 0
        ))
        episodeCount += 1
    }

    var catalog: SourceCatalog {
        // Playlists don't always list episodes in order.
        let series = series.map { item in
            var item = item
            item.episodes = item.episodes.enumerated()
                .sorted { ($0.element.season, $0.element.number ?? 0, $0.offset) < ($1.element.season, $1.element.number ?? 0, $1.offset) }
                .enumerated()
                .map { index, entry in
                    var episode = entry.element
                    episode.sortIndex = index
                    return episode
                }
            return item
        }
        return SourceCatalog(live: LiveCatalog(groups: liveGroups.groups, items: channels),
                             movies: MovieCatalog(groups: movieGroups.groups, items: movies),
                             series: SeriesCatalog(groups: seriesGroups.groups, items: series, includesEpisodes: true))
    }

    private struct GroupList {
        private(set) var groups: [CatalogGroup] = []
        private var known: Set<String> = []

        mutating func add(_ id: String, name: String) {
            if known.insert(id).inserted { groups.append(CatalogGroup(remoteID: id, name: name)) }
        }
    }
}
