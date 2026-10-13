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
        case .emptyPlaylist: "The playlist doesn't contain any channels."
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

    /// Refreshes a source and returns how many channels it now has. Records the outcome on the source.
    @discardableResult
    public func sync(_ source: Source, progress: @escaping @Sendable (SyncPhase) -> Void = { _ in }) async throws -> Int {
        guard let sourceID = source.id else { preconditionFailure("Sync requires a saved source") }
        progress(.connecting)
        do {
            let catalog: LiveCatalog
            switch source.kind {
            case .m3u: catalog = try await loadM3U(source, progress: progress)
            case .xtream: catalog = try await loadXtream(source, progress: progress)
            }
            progress(.saving(itemCount: catalog.items.count))
            try await database.replaceLiveCatalog(sourceID: sourceID, with: catalog)
            try await database.recordSync(sourceID: sourceID, error: nil)
            progress(.finished(itemCount: catalog.items.count))
            return catalog.items.count
        } catch {
            if !(error is CancellationError) {
                try? await database.recordSync(sourceID: sourceID, error: error.localizedDescription)
            }
            throw error
        }
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

    private func loadM3U(_ source: Source, progress: @escaping @Sendable (SyncPhase) -> Void) async throws -> LiveCatalog {
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

    private func loadXtream(_ source: Source, progress: @escaping @Sendable (SyncPhase) -> Void) async throws -> LiveCatalog {
        let client = XtreamClient(credentials: try xtreamCredentials(for: source), http: http, headers: source.httpHeaders)
        let account = try await client.authenticate()

        if source.liveFormat == nil, var updated = try await database.source(id: source.id!) {
            let formats = account.user.allowedOutputFormats
            updated.liveFormat = formats.isEmpty || formats.contains("m3u8") ? "m3u8" : "ts"
            try await database.updateSource(updated)
        }

        async let categories = client.liveCategories()
        async let streams = client.liveStreams()
        let (liveCategories, liveStreams) = try await (categories, streams)
        progress(.downloading(itemCount: liveStreams.count))
        return Self.xtreamCatalog(categories: liveCategories, streams: liveStreams)
    }

    static func xtreamCatalog(categories: [XtreamCategory], streams: [XtreamLiveStream]) -> LiveCatalog {
        let groups = categories.map { LiveCatalog.Group(remoteID: $0.id, name: $0.name) }
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

/// Turns M3U entries into a catalog, creating a category per `group-title` in order of first appearance.
struct M3UCatalogBuilder {
    static let ungroupedID = ""

    private(set) var groups: [LiveCatalog.Group] = []
    private var knownGroups: Set<String> = []
    private var items: [LiveCatalog.Item] = []

    var count: Int { items.count }

    mutating func add(_ entry: M3UEntry) {
        let groupID = entry.group ?? Self.ungroupedID
        if knownGroups.insert(groupID).inserted {
            groups.append(LiveCatalog.Group(remoteID: groupID, name: entry.group ?? "Uncategorized"))
        }
        let channel = Channel(
            sourceID: 0,
            stableKey: "m3u:\(entry.tvgID ?? "")|\(entry.name)|\(groupID)",
            name: entry.name,
            number: entry.channelNumber,
            logoURL: entry.logo,
            streamURL: entry.url,
            epgChannelID: entry.tvgID,
            catchupDays: entry.catchupDays,
            userAgent: entry.userAgent,
            referrer: entry.referrer,
            sortIndex: items.count
        )
        items.append(LiveCatalog.Item(channel: channel, groupRemoteID: groupID))
    }

    var catalog: LiveCatalog { LiveCatalog(groups: groups, items: items) }
}
