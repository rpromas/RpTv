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
            guard let key = source.credentialKey, let password = try credentials.password(for: key) else {
                throw SyncError.missingPassword
            }
            guard let server = XtreamCredentials.normalizeServer(source.location) else { throw XtreamError.invalidServer }
            url = XtreamCredentials(server: server, username: source.username ?? "", password: password)
                .liveURL(streamID: streamID, format: source.liveFormat ?? "m3u8")
        } else {
            guard let streamURL = channel.streamURL.flatMap(URL.init(string:)) else { throw SyncError.invalidLocation }
            url = streamURL
        }

        var headers = source.httpHeaders
        if let userAgent = channel.userAgent { headers["User-Agent"] = userAgent }
        if let referrer = channel.referrer { headers["Referer"] = referrer }

        return PlaybackItem(
            id: channel.stableKey,
            url: url,
            title: channel.name,
            artworkURL: channel.logoURL.flatMap(URL.init(string:)),
            headers: headers,
            isLive: true,
            enginePreference: source.enginePreference
        )
    }
}
