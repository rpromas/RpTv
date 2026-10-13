// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Everything a player needs to start a stream.
public struct PlaybackItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    public var title: String
    public var subtitle: String?
    public var artworkURL: URL?
    public var headers: [String: String]
    public var isLive: Bool
    public var startPosition: TimeInterval?
    /// The engine the user wants for this item's source.
    public var enginePreference: EnginePreference

    public init(
        id: String,
        url: URL,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        isLive: Bool,
        startPosition: TimeInterval? = nil,
        enginePreference: EnginePreference = .automatic
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.headers = headers
        self.isLive = isLive
        self.startPosition = startPosition
        self.enginePreference = enginePreference
    }
}

/// Builds playback items for catalog entries, adding credentials and per-source headers.
public struct PlaybackResolver: Sendable {
    private let credentials: any CredentialStore

    public init(credentials: any CredentialStore) {
        self.credentials = credentials
    }

    public func item(for channel: Channel, in source: Source) throws -> PlaybackItem {
        let url: URL
        if let streamID = channel.xtreamStreamID {
            url = try SourceSyncService.xtreamCredentials(for: source, in: credentials)
                .liveURL(streamID: streamID, format: source.liveFormat ?? "m3u8")
        } else {
            guard let streamURL = channel.streamURL.flatMap(URL.init(string:)) else { throw SyncError.invalidLocation }
            url = streamURL
        }
        return makeItem(id: channel.stableKey, url: url, channel: channel, source: source, isLive: true)
    }

    /// The archive of `programme` on `channel`, from its start. A programme with no known end counts as
    /// lasting an hour. Throws ``CatchupError/unavailable`` when the channel has no usable archive.
    public func catchupItem(for channel: Channel, programme: Programme, in source: Source,
                            now: Date = .now) throws -> PlaybackItem {
        guard channel.canCatchUp else { throw CatchupError.unavailable }
        let end = programme.stop ?? programme.start.addingTimeInterval(3600)
        let url: URL
        if let streamID = channel.xtreamStreamID {
            let minutes = Int((end.timeIntervalSince(programme.start) / 60).rounded(.up))
            url = try SourceSyncService.xtreamCredentials(for: source, in: credentials).timeshiftURL(
                streamID: streamID, start: programme.start, durationMinutes: max(minutes, 1),
                serverTimeZone: source.serverTimeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt)
        } else {
            guard let streamURL = channel.streamURL, let mode = channel.catchupMode,
                  let built = Catchup.m3uURL(streamURL: streamURL, mode: mode, source: channel.catchupSource,
                                             start: programme.start, end: end, now: now)
            else { throw CatchupError.unavailable }
            url = built
        }
        var item = makeItem(id: channel.stableKey + "#catchup", url: url, channel: channel, source: source, isLive: false)
        item.subtitle = programme.title
        return item
    }

    private func makeItem(id: String, url: URL, channel: Channel, source: Source, isLive: Bool) -> PlaybackItem {
        var headers = source.httpHeaders
        if let userAgent = channel.userAgent { headers["User-Agent"] = userAgent }
        if let referrer = channel.referrer { headers["Referer"] = referrer }

        return PlaybackItem(
            id: id,
            url: url,
            title: channel.name,
            artworkURL: channel.logoURL.flatMap(URL.init(string:)),
            headers: headers,
            isLive: isLive,
            enginePreference: source.enginePreference
        )
    }
}
