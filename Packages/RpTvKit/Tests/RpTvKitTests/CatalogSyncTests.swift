// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

struct CatalogSyncTests {
    let database: AppDatabase
    let credentials = InMemoryCredentialStore(["xtream-key": "secret"])
    let service: SourceSyncService

    init() throws {
        database = try AppDatabase.inMemory()
        service = SourceSyncService(
            database: database,
            credentials: credentials,
            playlistDirectory: try Fixture.url("sample.m3u").deletingLastPathComponent(),
            http: StubXtreamServer()
        )
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    @Test func syncsLocalM3UIntoCategoriesAndChannels() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        let count = try await service.sync(source)
        #expect(count == 5)

        let categories = try await firstValue(database.observeLiveCategories(sourceID: source.id!))
        #expect(categories.map(\.category.name) == ["News", "Sports, Live", "Movies", "Uncategorized"])
        #expect(categories.map(\.itemCount) == [1, 1, 1, 2])

        let sports = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: categories[1].id))
        #expect(sports.map(\.name) == ["Sport 2, Extra"])
        #expect(sports[0].userAgent == "CustomAgent/1.0")
        #expect(sports[0].catchupMode == "shift")
        #expect(sports[0].catchupDays == 3)
        #expect(sports[0].canCatchUp)

        let updated = try await database.source(id: source.id!)
        #expect(updated?.lastSyncedAt != nil)
        #expect(updated?.epgURL == "http://epg.example.com/guide.xml.gz")
    }

    @Test func resyncReplacesChannelsAndKeepsHiddenCategories() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE mediaCategory SET isHidden = 1 WHERE name = 'Movies'")
        }

        try await service.sync(source)
        #expect(try await database.channelCount(sourceID: source.id!) == 5)
        let visible = try await firstValue(database.observeLiveCategories(sourceID: source.id!))
        #expect(!visible.map(\.category.name).contains("Movies"))
        let all = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil))
        #expect(all.count == 4)
    }

    @Test(arguments: [("epg/guide.xml", M3UForeignContent.guide), ("epg/guide.xml.gz", .binary)])
    func refusesGuideGivenAsPlaylistAndKeepsCatalog(location: String, expected: M3UForeignContent) async throws {
        var source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)

        source.location = location
        try await database.updateSource(source)
        await #expect(throws: SyncError.notAPlaylist(expected)) { try await service.sync(source) }
        #expect(try await database.channelCount(sourceID: source.id!) == 5)
    }

    @Test func searchesChannelNames() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)
        let results = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil, search: "sport"))
        #expect(results.map(\.name) == ["Sport 2, Extra"])
        let none = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil, search: "100%"))
        #expect(none.isEmpty)
    }

    @Test func recordsSyncErrors() async throws {
        let source = try await database.insertSource(Source(name: "Missing", kind: .m3u, location: "missing.m3u", isLocalFile: true))
        await #expect(throws: (any Error).self) { try await service.sync(source) }
        let updated = try await database.source(id: source.id!)
        #expect(updated?.lastSyncError != nil)
        #expect(updated?.lastSyncedAt == nil)
    }

    @Test func syncsXtreamAndResolvesPlaybackURLs() async throws {
        let source = try await database.insertSource(Source(name: "Xtream", kind: .xtream, location: "http://example.com:8080",
                                                            username: "demo", credentialKey: "xtream-key"))
        #expect(try await service.sync(source) == 5) // two channels, a movie and two series

        let saved = try #require(try await database.source(id: source.id!))
        #expect(saved.liveFormat == "m3u8")
        #expect(saved.serverTimeZone == "Europe/Vilnius")

        let channels = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil))
        #expect(channels.map(\.name) == ["News One", "Sport Two"])
        #expect(channels[0].catchupDays == 7)
        #expect(channels[0].streamURL == nil) // credentials never stored

        let item = try PlaybackResolver(credentials: credentials).item(for: channels[0], in: saved)
        #expect(item.url.absoluteString == "http://example.com:8080/live/demo/secret/101.m3u8")
        #expect(item.isLive)
        #expect(item.enginePreference == .automatic)
    }

    @Test func enginePreferenceSurvivesResyncAndReachesPlayback() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        #expect(source.enginePreference == .automatic)
        try await database.modifySource(id: source.id!) { $0.enginePreference = .ffmpeg }
        try await service.sync(source)

        let saved = try #require(try await database.source(id: source.id!))
        #expect(saved.enginePreference == .ffmpeg)
        #expect(saved.lastSyncedAt != nil)
        let channels = try await firstValue(database.observeChannels(sourceID: source.id!, categoryID: nil))
        #expect(try PlaybackResolver(credentials: credentials).item(for: channels[0], in: saved).enginePreference == .ffmpeg)
    }

    @Test func deletingSourceCascades() async throws {
        let source = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await service.sync(source)
        try await database.deleteSource(id: source.id!)
        #expect(try await database.channelCount(sourceID: source.id!) == 0)
    }
}

struct EngineSelectorTests {
    @Test(arguments: [
        ("http://h/live/1.m3u8", PlayerEngineKind.native),
        ("http://h/movie/1.MP4", .native),
        ("http://h/live/1.ts", .ffmpeg),
        ("http://h/movie/1.mkv", .ffmpeg),
        ("rtmp://h/live/stream", .ffmpeg),
        ("udp://@239.0.0.1:1234", .ffmpeg),
        ("http://h:8080/12345", .native),
    ])
    func picksEngineByURL(url: String, expected: PlayerEngineKind) throws {
        #expect(EngineSelector.engine(for: try #require(URL(string: url))) == expected)
    }

    @Test func honoursForcedPreference() throws {
        let url = try #require(URL(string: "http://h/live/1.ts"))
        #expect(EngineSelector.engine(for: url, preference: .native) == .native)
        #expect(EngineSelector.fallback(after: .native) == .ffmpeg)
        #expect(EngineSelector.fallback(after: .ffmpeg) == nil)
    }
}
