// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

struct SourceExportTests {
    private let sources = [
        Source(id: 1, name: "Home", kind: .xtream, location: "http://example.com:8080", username: "demo",
               credentialKey: "key-1", userAgent: "Agent/1", referrer: "http://ref.example.com", enginePreference: .vlc),
        Source(id: 2, name: "Playlist", kind: .m3u, location: "http://example.com/list.m3u", epgURL: "http://example.com/guide.xml"),
        Source(id: 3, name: "File", kind: .m3u, location: "ABC.m3u", isLocalFile: true),
    ]

    @Test func leavesOutPasswordsKeysAndImportedFiles() throws {
        let data = try SourceExport(sources: sources).encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("key-1"))
        #expect(!json.contains("credentialKey"))
        #expect(!json.contains("password"))
        #expect(!json.contains("ABC.m3u"))
        #expect(json.contains("\"version\" : 1"))
    }

    @Test func roundTrips() throws {
        let decoded = try SourceExport.decode(SourceExport(sources: sources).encoded())
        #expect(decoded.sources.map(\.name) == ["Home", "Playlist"])
        #expect(decoded.sources.map(\.needsPassword) == [true, false])

        let xtream = decoded.sources[0].makeSource(credentialKey: "new-key")
        #expect(xtream.kind == .xtream)
        #expect(xtream.location == "http://example.com:8080")
        #expect(xtream.username == "demo")
        #expect(xtream.credentialKey == "new-key")
        #expect(xtream.httpHeaders == ["User-Agent": "Agent/1", "Referer": "http://ref.example.com"])
        #expect(xtream.enginePreference == .vlc)
        #expect(xtream.id == nil)
        #expect(decoded.sources[1].makeSource().epgURL == "http://example.com/guide.xml")
    }

    @Test func rejectsOtherFilesAndNewerVersions() {
        #expect(throws: SourceExportError.unreadable) { try SourceExport.decode(Data("[1, 2]".utf8)) }
        #expect(throws: SourceExportError.newerVersion) {
            try SourceExport.decode(Data(#"{"version": 99, "sources": []}"#.utf8))
        }
    }
}

struct AccountExpiryTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(expiringIn days: Double?) -> Source {
        Source(name: "A", kind: .xtream, location: "http://example.com",
               accountExpiresAt: days.map { now.addingTimeInterval($0 * 86400) })
    }

    @Test func warnsOnlyInTheLastWeek() {
        #expect(source(expiringIn: nil).daysUntilExpiry(now: now, calendar: calendar) == nil)
        #expect(source(expiringIn: 30).daysUntilExpiry(now: now, calendar: calendar) == nil)
        #expect(source(expiringIn: 7).daysUntilExpiry(now: now, calendar: calendar) == 7)
        #expect(source(expiringIn: 1).daysUntilExpiry(now: now, calendar: calendar) == 1)
        #expect(source(expiringIn: -2).daysUntilExpiry(now: now, calendar: calendar) == -2)
    }

    @Test func syncStoresTheExpiryDate() async throws {
        let database = try AppDatabase.inMemory()
        let service = SourceSyncService(database: database, credentials: InMemoryCredentialStore(["key": "secret"]),
                                        playlistDirectory: URL.temporaryDirectory, http: StubXtreamServer())
        let source = try await database.insertSource(Source(name: "X", kind: .xtream, location: "http://example.com:8080",
                                                            username: "demo", credentialKey: "key"))
        try await service.sync(source)
        #expect(try await database.source(id: source.id!)?.accountExpiresAt == Date(timeIntervalSince1970: 1924992000))

        let status = try await service.accountStatus(of: source)
        #expect(status.user.maxConnections == 2)
    }
}

struct PlaybackPreferencesTests {
    @Test(arguments: [
        ("fr", "fr", true), ("fra", "fr", true), ("fre", "fr", true), ("fr-CA", "fr", true), ("FR_ca", "fr", true),
        ("ger", "de", true), ("deu", "de", true), ("eng", "en", true), ("en", "de", false), ("und", "en", false),
        ("", "en", false),
    ])
    func matchesTrackLanguages(tag: String, language: String, matches: Bool) {
        #expect(TrackLanguage.matches(tag, language) == matches)
    }

    @Test func appliesTheDefaultEngineAndPreferences() throws {
        let preferences = PlaybackPreferences(engine: .vlc, liveBuffer: 5, audioLanguage: "fr", subtitleLanguage: "en")
        let resolver = PlaybackResolver(credentials: InMemoryCredentialStore(), preferences: preferences)
        let channel = Channel(sourceID: 1, stableKey: "c", name: "C", streamURL: "http://example.com/c.m3u8", sortIndex: 0)

        let item = try resolver.item(for: channel, in: Source(id: 1, name: "A", kind: .m3u, location: "http://example.com"))
        #expect(item.enginePreference == .vlc)
        #expect(item.liveBuffer == 5)
        #expect(item.audioLanguage == "fr")
        #expect(item.subtitleLanguage == "en")

        // A source's own choice wins over the default.
        let native = Source(id: 1, name: "A", kind: .m3u, location: "http://example.com", enginePreference: .native)
        #expect(try resolver.item(for: channel, in: native).enginePreference == .native)

        let movie = Movie(sourceID: 1, stableKey: "m", name: "M", streamURL: "http://example.com/m.mp4", sortIndex: 0)
        let movieItem = try resolver.item(for: movie, in: native)
        #expect(movieItem.liveBuffer == nil)
        #expect(movieItem.audioLanguage == "fr")
    }
}
