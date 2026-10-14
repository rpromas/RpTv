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
    /// How much of a live stream to buffer before playing, or `nil` for the engine's default.
    public var liveBuffer: TimeInterval?
    /// Language codes (`en`, `fr`…) of the audio and subtitle tracks to pick when the stream has them.
    /// No subtitle language means subtitles stay off.
    public var audioLanguage: String?
    public var subtitleLanguage: String?

    public init(
        id: String,
        url: URL,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        headers: [String: String] = [:],
        isLive: Bool,
        startPosition: TimeInterval? = nil,
        enginePreference: EnginePreference = .automatic,
        liveBuffer: TimeInterval? = nil,
        audioLanguage: String? = nil,
        subtitleLanguage: String? = nil
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
        self.liveBuffer = liveBuffer
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
    }
}

/// The user's playback settings, applied to every item the resolver builds.
public struct PlaybackPreferences: Sendable, Hashable {
    /// The engine for sources left on ``EnginePreference/automatic``.
    public var engine: EnginePreference
    public var liveBuffer: TimeInterval?
    public var audioLanguage: String?
    public var subtitleLanguage: String?

    public init(engine: EnginePreference = .automatic, liveBuffer: TimeInterval? = nil,
                audioLanguage: String? = nil, subtitleLanguage: String? = nil) {
        self.engine = engine
        self.liveBuffer = liveBuffer
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
    }
}

/// Matches the language tags streams give their tracks against the user's preferred language.
public enum TrackLanguage {
    /// Whether a track's language tag (`fr`, `fra`, `fre`, `fr-CA`…) names the same language as `language`.
    public static func matches(_ tag: String?, _ language: String) -> Bool {
        guard let tag, let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
              let wanted = alpha2(language) else { return false }
        return alpha2(String(code)) == wanted
    }

    /// The language's name in the user's language ("French" for `fre`), or `nil` when the tag isn't a known
    /// language.
    public static func displayName(_ tag: String?) -> String? {
        guard let tag, let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
              let alpha2 = alpha2(String(code)) else { return nil }
        return Locale.current.localizedString(forLanguageCode: alpha2)
    }

    /// The two-letter code of a two- or three-letter one, or the code itself when there's none.
    static func alpha2(_ code: String) -> String? {
        var code = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return nil }
        code = bibliographic[code] ?? code
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }

    /// ISO 639-2 bibliographic codes, which MPEG-TS streams often use, and their terminology twins, which
    /// `Locale` knows.
    private static let bibliographic = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]
}

/// Builds playback items for catalog entries, adding credentials and per-source headers.
public struct PlaybackResolver: Sendable {
    private let credentials: any CredentialStore
    public var preferences: PlaybackPreferences

    public init(credentials: any CredentialStore, preferences: PlaybackPreferences = PlaybackPreferences()) {
        self.credentials = credentials
        self.preferences = preferences
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

    /// A movie, from `startPosition` seconds in. Not live, so the player shows a scrubber.
    public func item(for movie: Movie, in source: Source, startPosition: TimeInterval? = nil) throws -> PlaybackItem {
        let url: URL
        if let streamID = movie.xtreamStreamID {
            url = try SourceSyncService.xtreamCredentials(for: source, in: credentials)
                .movieURL(streamID: streamID, containerExtension: movie.containerExtension)
        } else {
            guard let streamURL = movie.streamURL.flatMap(URL.init(string:)) else { throw SyncError.invalidLocation }
            url = streamURL
        }
        var headers = source.httpHeaders
        if let userAgent = movie.userAgent { headers["User-Agent"] = userAgent }
        if let referrer = movie.referrer { headers["Referer"] = referrer }
        return PlaybackItem(
            id: movie.stableKey,
            url: url,
            title: movie.name,
            subtitle: movie.year.map(String.init),
            artworkURL: movie.posterURL.flatMap(URL.init(string:)),
            headers: headers,
            isLive: false,
            startPosition: startPosition,
            enginePreference: enginePreference(for: source),
            audioLanguage: preferences.audioLanguage,
            subtitleLanguage: preferences.subtitleLanguage
        )
    }

    /// An episode of `series`, from `startPosition` seconds in. Not live.
    public func item(for episode: Episode, of series: Series, in source: Source,
                     startPosition: TimeInterval? = nil) throws -> PlaybackItem {
        let url: URL
        if let episodeID = episode.xtreamEpisodeID {
            url = try SourceSyncService.xtreamCredentials(for: source, in: credentials)
                .episodeURL(episodeID: episodeID, containerExtension: episode.containerExtension)
        } else {
            guard let streamURL = episode.streamURL.flatMap(URL.init(string:)) else { throw SyncError.invalidLocation }
            url = streamURL
        }
        var headers = source.httpHeaders
        if let userAgent = episode.userAgent { headers["User-Agent"] = userAgent }
        if let referrer = episode.referrer { headers["Referer"] = referrer }
        return PlaybackItem(
            id: episode.stableKey,
            url: url,
            title: series.name,
            subtitle: "\(episode.code) · \(episode.title)",
            artworkURL: (series.posterURL ?? episode.stillURL).flatMap(URL.init(string:)),
            headers: headers,
            isLive: false,
            startPosition: startPosition,
            enginePreference: enginePreference(for: source),
            audioLanguage: preferences.audioLanguage,
            subtitleLanguage: preferences.subtitleLanguage
        )
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
            enginePreference: enginePreference(for: source),
            liveBuffer: isLive ? preferences.liveBuffer : nil,
            audioLanguage: preferences.audioLanguage,
            subtitleLanguage: preferences.subtitleLanguage
        )
    }

    /// The source's own engine, or the app's default when the source leaves it to the app.
    private func enginePreference(for source: Source) -> EnginePreference {
        source.enginePreference == .automatic ? preferences.engine : source.enginePreference
    }
}
