// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

/// Serves Xtream fixtures keyed by the `action` query parameter (`auth` when there is none).
struct StubXtreamServer: HTTPClient {
    var overrides: [String: String] = [:]
    var statusCode = 200

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = items.first { $0.name == "action" }?.value ?? "auth"
        let fixture = overrides[action] ?? action
        let data = try Fixture.data("xtream/\(fixture).json")
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

enum Fixture {
    static func url(_ path: String) throws -> URL {
        let name = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        return try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }
}

struct XtreamCredentialsTests {
    @Test(arguments: [
        ("example.com:8080", "http://example.com:8080"),
        ("http://example.com:8080/", "http://example.com:8080"),
        ("https://example.com/player_api.php", "https://example.com"),
        ("  http://example.com:8080/get.php?username=a&password=b ", "http://example.com:8080"),
        ("http://example.com/panel/", "http://example.com/panel"),
    ])
    func normalizesServer(input: String, expected: String) {
        #expect(XtreamCredentials.normalizeServer(input)?.absoluteString == expected)
    }

    @Test func rejectsEmptyServer() {
        #expect(XtreamCredentials.normalizeServer("   ") == nil)
    }

    @Test func extractsAccountFromPlaylistLink() throws {
        let credentials = try #require(XtreamCredentials(playlistURL: "http://example.com:8080/get.php?username=demo&password=secret&type=m3u_plus&output=ts"))
        #expect(credentials.server.absoluteString == "http://example.com:8080")
        #expect(credentials.username == "demo")
        #expect(credentials.password == "secret")
        #expect(XtreamCredentials(playlistURL: "http://example.com/playlist.m3u") == nil)
    }

    @Test func buildsStreamURLs() throws {
        let credentials = try #require(XtreamCredentials(server: "http://example.com:8080", username: "demo", password: "p/ss"))
        #expect(credentials.liveURL(streamID: 101).absoluteString == "http://example.com:8080/live/demo/p%2Fss/101.m3u8")
        #expect(credentials.movieURL(streamID: 5, containerExtension: "mkv").absoluteString == "http://example.com:8080/movie/demo/p%2Fss/5.mkv")
        #expect(credentials.episodeURL(episodeID: "9", containerExtension: nil).absoluteString == "http://example.com:8080/series/demo/p%2Fss/9.mp4")
        #expect(credentials.apiURL(action: "get_vod_info", parameters: ["vod_id": "5"]).absoluteString
            == "http://example.com:8080/player_api.php?username=demo&password=p/ss&action=get_vod_info&vod_id=5")
    }

    @Test func buildsTimeshiftURLInServerTimeZone() throws {
        let credentials = try #require(XtreamCredentials(server: "http://example.com", username: "u", password: "p"))
        let start = Date(timeIntervalSince1970: 1792051200) // 2026-10-15 08:00 UTC
        let url = credentials.timeshiftURL(streamID: 101, start: start, durationMinutes: 60,
                                           serverTimeZone: TimeZone(identifier: "Europe/Vilnius")!)
        #expect(url.absoluteString == "http://example.com/timeshift/u/p/60/2026-10-15:11-00/101.ts")
    }
}

struct XtreamClientTests {
    private func client(_ server: StubXtreamServer = StubXtreamServer()) -> XtreamClient {
        XtreamClient(credentials: XtreamCredentials(server: "http://example.com:8080", username: "demo", password: "secret")!, http: server)
    }

    @Test func authenticatesAndDecodesAccount() async throws {
        let account = try await client().authenticate()
        #expect(account.user.isAuthenticated)
        #expect(account.user.maxConnections == 2)
        #expect(account.user.activeConnections == 0)
        #expect(account.user.expiresAt == Date(timeIntervalSince1970: 1924992000))
        #expect(account.user.allowedOutputFormats == ["m3u8", "ts", "rtmp"])
        #expect(account.server?.timeZone?.identifier == "Europe/Vilnius")
    }

    @Test func rejectsWrongCredentials() async {
        await #expect(throws: XtreamError.unauthorized) {
            try await client(StubXtreamServer(overrides: ["auth": "auth_failed"])).authenticate()
        }
        await #expect(throws: XtreamError.unauthorized) {
            try await client(StubXtreamServer(statusCode: 403)).authenticate()
        }
    }

    @Test func rejectsExpiredAccount() async {
        await #expect(throws: XtreamError.accountInactive(status: "Expired")) {
            try await client(StubXtreamServer(overrides: ["auth": "auth_expired"])).authenticate()
        }
    }

    @Test func describesExpiredAccount() async throws {
        let account = try await client(StubXtreamServer(overrides: ["auth": "auth_expired"])).accountInfo()
        #expect(account.user.status == "Expired")
        #expect(!account.user.isActive)
        await #expect(throws: XtreamError.unauthorized) {
            try await client(StubXtreamServer(overrides: ["auth": "auth_failed"])).accountInfo()
        }
    }

    @Test func decodesCategoriesSkippingBrokenEntries() async throws {
        let categories = try await client().liveCategories()
        #expect(categories.map(\.id) == ["1", "2"])
        #expect(categories.map(\.name) == ["News", "Sports"])
    }

    @Test func treatsEmptyObjectAsEmptyList() async throws {
        #expect(try await client().vodCategories().isEmpty)
    }

    @Test func decodesLiveStreamsWithMixedTypes() async throws {
        let streams = try await client().liveStreams()
        #expect(streams.count == 2)
        #expect(streams[0].streamID == 101)
        #expect(streams[0].hasArchive)
        #expect(streams[0].archiveDays == 7)
        #expect(streams[0].epgChannelID == "news.one")
        #expect(streams[1].streamID == 102)
        #expect(streams[1].number == 2)
        #expect(streams[1].categoryID == "2")
        #expect(streams[1].icon == nil)
        #expect(streams[1].epgChannelID == nil)
        #expect(!streams[1].hasArchive)
    }

    @Test func decodesVODStreamsAndInfo() async throws {
        let movie = try #require(try await client().vodStreams().first)
        #expect(movie.streamID == 501)
        #expect(movie.rating == 7.4)
        #expect(movie.containerExtension == "mkv")

        let info = try await client().vodInfo(streamID: 501)
        let details = try #require(info.details)
        #expect(details.cover == "http://img.example.com/big.jpg")
        #expect(details.cast == "Actor One, Actor Two")
        #expect(details.plot == "A plot.")
        #expect(details.durationSeconds == 8160)
        #expect(details.backdrops == ["http://img.example.com/bd1.jpg"])
        #expect(info.containerExtension == "mkv")
    }

    @Test func treatsEmptyInfoArrayAsMissing() async throws {
        let info = try await client(StubXtreamServer(overrides: ["get_vod_info": "get_vod_info_empty"])).vodInfo(streamID: 502)
        #expect(info.details == nil)
        #expect(info.streamID == 502)
    }

    @Test func decodesSeriesInfoKeyedBySeason() async throws {
        let info = try await client().seriesInfo(seriesID: 1)
        #expect(info.details?.name == "A Show")
        #expect(info.details?.cover == "http://img.example.com/show.jpg")
        #expect(info.details?.backdrops == ["http://img.example.com/bd.jpg"])
        #expect(info.seasons.map(\.number) == [1])
        #expect(info.episodes.map(\.id) == ["9001", "9002", "9003"])
        #expect(info.episodes[0].season == 1) // inferred from the dictionary key
        #expect(info.episodes[1].durationSeconds == 2700)
        #expect(info.episodes[2].plot == nil) // `info: []`
    }

    @Test func decodesSeriesInfoAsNestedArrays() async throws {
        let info = try await client(StubXtreamServer(overrides: ["get_series_info": "get_series_info_array"])).seriesInfo(seriesID: 2)
        #expect(info.details == nil)
        #expect(info.episodes.map(\.id) == ["7001"])
    }

    @Test func decodesBase64ShortEPG() async throws {
        let listings = try await client().shortEPG(streamID: 101)
        #expect(listings.map(\.title) == ["Morning News", "Plain Title"])
        #expect(listings[0].description == "Today's headlines")
        #expect(listings[0].end.timeIntervalSince(listings[0].start) == 3600)
    }
}
