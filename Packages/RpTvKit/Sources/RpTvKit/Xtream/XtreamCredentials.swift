// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// An Xtream Codes account plus the URL scheme the API uses for streams.
public struct XtreamCredentials: Sendable, Hashable {
    /// Server root without a trailing slash, e.g. `http://example.com:8080`.
    public let server: URL
    public let username: String
    public let password: String

    public init(server: URL, username: String, password: String) {
        self.server = server
        self.username = username
        self.password = password
    }

    /// Accepts what users actually type: a bare host, a URL with a trailing slash, or a URL ending in
    /// `player_api.php` or `get.php`. Returns `nil` when no host can be found.
    public init?(server rawServer: String, username: String, password: String) {
        guard let server = Self.normalizeServer(rawServer) else { return nil }
        self.init(server: server, username: username, password: password)
    }

    /// Extracts an account from an Xtream playlist link such as
    /// `http://host:8080/get.php?username=u&password=p&type=m3u_plus`.
    public init?(playlistURL: String) {
        guard let components = URLComponents(string: playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let items = components.queryItems,
              let username = items.first(where: { $0.name == "username" })?.value.nonEmpty,
              let password = items.first(where: { $0.name == "password" })?.value.nonEmpty
        else { return nil }
        self.init(server: playlistURL, username: username, password: password)
    }

    static func normalizeServer(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        var path = components.path
        for suffix in ["player_api.php", "get.php", "xmltv.php"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    // MARK: - URLs

    func apiURL(action: String?, parameters: [String: String] = [:]) -> URL {
        var components = URLComponents(url: server.appending(component: "player_api.php"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        items += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!
    }

    public var xmltvURL: URL {
        var components = URLComponents(url: server.appending(component: "xmltv.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        return components.url!
    }

    public func liveURL(streamID: Int, format: String = "m3u8") -> URL {
        server.appending(components: "live", username, password, "\(streamID).\(format)")
    }

    public func movieURL(streamID: Int, containerExtension: String?) -> URL {
        server.appending(components: "movie", username, password, "\(streamID).\(containerExtension ?? "mp4")")
    }

    public func episodeURL(episodeID: String, containerExtension: String?) -> URL {
        server.appending(components: "series", username, password, "\(episodeID).\(containerExtension ?? "mp4")")
    }

    /// Catch-up URL for a programme that started at `start` and lasts `durationMinutes`.
    /// Xtream expects the start time in the server's time zone, formatted `yyyy-MM-dd:HH-mm`.
    public func timeshiftURL(streamID: Int, start: Date, durationMinutes: Int, serverTimeZone: TimeZone) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = serverTimeZone
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        return server.appending(components: "timeshift", username, password, "\(durationMinutes)",
                                formatter.string(from: start), "\(streamID).ts")
    }
}
