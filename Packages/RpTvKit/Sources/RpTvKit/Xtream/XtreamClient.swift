// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum XtreamError: LocalizedError, Equatable {
    case invalidServer
    case unauthorized
    case accountInactive(status: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "The server address isn't valid."
        case .unauthorized: "The username or password is incorrect."
        case .accountInactive(let status): "The account isn't active (status: \(status))."
        case .invalidResponse: "The server didn't return valid Xtream data. Check the server address."
        }
    }
}

/// Client for the Xtream Codes `player_api.php` API.
public struct XtreamClient: Sendable {
    public let credentials: XtreamCredentials
    private let http: any HTTPClient
    private let headers: [String: String]

    public init(credentials: XtreamCredentials, http: any HTTPClient = URLSession.shared, headers: [String: String] = [:]) {
        self.credentials = credentials
        self.http = http
        self.headers = headers
    }

    /// Logs in and checks that the account is usable.
    public func authenticate() async throws -> XtreamAccount {
        let account: XtreamAccount
        do {
            account = try await get(XtreamAccount.self, action: nil)
        } catch HTTPError.status(let code) where [401, 403, 884].contains(code) {
            throw XtreamError.unauthorized
        }
        guard account.user.isAuthenticated else { throw XtreamError.unauthorized }
        guard account.user.isActive else { throw XtreamError.accountInactive(status: account.user.status ?? "unknown") }
        return account
    }

    public func liveCategories() async throws -> [XtreamCategory] {
        try await list(XtreamCategory.self, action: "get_live_categories")
    }

    public func liveStreams() async throws -> [XtreamLiveStream] {
        try await list(XtreamLiveStream.self, action: "get_live_streams")
    }

    public func vodCategories() async throws -> [XtreamCategory] {
        try await list(XtreamCategory.self, action: "get_vod_categories")
    }

    public func vodStreams() async throws -> [XtreamVODStream] {
        try await list(XtreamVODStream.self, action: "get_vod_streams")
    }

    public func vodInfo(streamID: Int) async throws -> XtreamVODInfo {
        try await get(XtreamVODInfo.self, action: "get_vod_info", parameters: ["vod_id": String(streamID)])
    }

    public func seriesCategories() async throws -> [XtreamCategory] {
        try await list(XtreamCategory.self, action: "get_series_categories")
    }

    public func series() async throws -> [XtreamSeries] {
        try await list(XtreamSeries.self, action: "get_series")
    }

    public func seriesInfo(seriesID: Int) async throws -> XtreamSeriesInfo {
        try await get(XtreamSeriesInfo.self, action: "get_series_info", parameters: ["series_id": String(seriesID)])
    }

    public func shortEPG(streamID: Int, limit: Int = 4) async throws -> [XtreamEPGListing] {
        try await get(XtreamEPGResponse.self, action: "get_short_epg",
                      parameters: ["stream_id": String(streamID), "limit": String(limit)]).listings
    }

    // MARK: - Transport

    private func list<T: Decodable>(_ type: T.Type, action: String) async throws -> [T] {
        let data = try await fetch(action: action, parameters: [:])
        // An empty result is sometimes `{}` or `null` rather than `[]`.
        if let items = try? JSONDecoder().decode([Lossy<T>].self, from: data) {
            return items.compactMap(\.value)
        }
        if let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
           object is NSNull || (object as? [String: Any])?.isEmpty == true {
            return []
        }
        throw XtreamError.invalidResponse
    }

    private func get<T: Decodable>(_ type: T.Type, action: String?, parameters: [String: String] = [:]) async throws -> T {
        let data = try await fetch(action: action, parameters: parameters)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw XtreamError.invalidResponse
        }
    }

    private func fetch(action: String?, parameters: [String: String]) async throws -> Data {
        let request = URLRequest(url: credentials.apiURL(action: action, parameters: parameters), headers: headers)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw HTTPError.status(response.statusCode) }
        return data
    }
}
