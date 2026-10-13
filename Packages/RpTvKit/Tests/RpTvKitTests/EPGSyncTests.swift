// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import Synchronization
import Testing
@testable import RpTvKit

/// Serves a fixture for every download, copied to a temp file the caller then owns, and records requests.
final class StubDownloader: HTTPDownloader {
    struct Failure: LocalizedError {
        var url: URL
        var errorDescription: String? { "Could not connect to \(url.absoluteString)" }
    }

    let fixture: String
    let statusCode: Int
    let fails: Bool
    private let log = Mutex<[URLRequest]>([])

    init(fixture: String = "epg/guide.xml.gz", statusCode: Int = 200, fails: Bool = false) {
        self.fixture = fixture
        self.statusCode = statusCode
        self.fails = fails
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let url = try #require(request.url)
        if fails { throw Failure(url: url) }
        let file = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: Fixture.url(fixture), to: file)
        return (file, HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }
}

struct EPGSyncTests {
    let database: AppDatabase
    let credentials = InMemoryCredentialStore(["xtream-key": "secret"])
    let catalogService: SourceSyncService
    /// 2026-10-14 09:30 UTC, in the middle of the fixture guide.
    let now = Date(timeIntervalSince1970: 1_791_970_200)

    init() throws {
        database = try AppDatabase.inMemory()
        catalogService = SourceSyncService(
            database: database,
            credentials: credentials,
            playlistDirectory: try Fixture.url("sample.m3u").deletingLastPathComponent(),
            http: StubXtreamServer()
        )
    }

    private func service(_ downloader: StubDownloader) -> EPGSyncService {
        EPGSyncService(database: database, credentials: credentials, downloader: downloader)
    }

    private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T {
        for try await value in stream { return value }
        throw CancellationError()
    }

    private func syncedM3USource() async throws -> Source {
        let inserted = try await database.insertSource(Source(name: "Local", kind: .m3u, location: "sample.m3u", isLocalFile: true))
        try await catalogService.sync(inserted)
        return try #require(try await database.source(id: inserted.id!))
    }

    private func channels(_ sourceID: Int64) async throws -> [String: Channel] {
        let channels = try await firstValue(database.observeChannels(sourceID: sourceID, categoryID: nil))
        return Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0) })
    }

    private func programmes(_ sourceID: Int64) async throws -> [Programme] {
        try await database.reader.read { db in
            try Programme.filter(Column("sourceID") == sourceID).order(Column("epgChannelID"), Column("start")).fetchAll(db)
        }
    }

    @Test func importsOnlyMatchedProgrammesAndMatchesChannels() async throws {
        let source = try await syncedM3USource()
        let downloader = StubDownloader()
        let count = try await service(downloader).sync(source, now: now)

        #expect(downloader.requests.map(\.url?.absoluteString) == ["http://epg.example.com/guide.xml.gz"])
        #expect(count == 7)
        let stored = try await programmes(source.id!)
        #expect(stored.count == 7)
        #expect(Set(stored.map(\.epgChannelID)) == ["news.one", "Sport.Two", "logo.channel"])
        // Unknown channels and programmes that ended over a day ago are dropped.
        #expect(!stored.contains { ["Unwatched Show", "Orphan Show", "Old News"].contains($0.title) })
        #expect(try await database.reader.read { db in try GuideChannel.fetchCount(db) } == 4)

        // A missing stop runs until the next programme; the channel's last one stays open.
        let talk = try #require(stored.first { $0.title == "Afternoon Talk" })
        #expect(talk.stop == Date(timeIntervalSince1970: 1_791_979_200)) // 12:00 UTC
        #expect(stored.first { $0.title == "Late Highlights" }?.stop == nil)

        let channels = try await channels(source.id!)
        #expect(channels["News One HD"]?.guideID == "news.one")
        #expect(channels["Sport 2, Extra"]?.guideID == "Sport.Two") // tvg-id differs in case
        #expect(channels["Unquoted Logo"]?.guideID == "logo.channel") // matched by name
        #expect(channels["Name From Attr"]?.guideID == nil)

        let saved = try #require(try await database.source(id: source.id!))
        #expect(saved.lastEPGSyncAt == now)
        #expect(saved.lastEPGSyncError == nil)
        #expect(!EPGSyncService.isStale(saved, now: now.addingTimeInterval(11 * 3600)))
        #expect(EPGSyncService.isStale(saved, now: now.addingTimeInterval(12 * 3600)))
    }

    @Test func plainGuideImportsTheSame() async throws {
        let source = try await syncedM3USource()
        #expect(try await service(StubDownloader(fixture: "epg/guide.xml")).sync(source, now: now) == 7)
    }

    @Test func observesNowAndNext() async throws {
        let source = try await syncedM3USource()
        try await service(StubDownloader()).sync(source, now: now)
        let channels = try await channels(source.id!)

        let nowNext = try await firstValue(database.observeNowNext(channelIDs: channels.values.compactMap(\.id), at: now))
        #expect(nowNext.count == 3)

        let news = try #require(nowNext[channels["News One HD"]!.id!])
        #expect(news.now?.title == "Midday Report")
        #expect(news.now?.progress(at: now) == 0.5)
        #expect(news.next?.title == "Afternoon Talk")

        let sport = try #require(nowNext[channels["Sport 2, Extra"]!.id!])
        #expect(sport.now?.title == "Late Highlights")
        #expect(sport.now?.progress(at: now) == nil)
        #expect(sport.next == nil)

        #expect(nowNext[channels["Unquoted Logo"]!.id!]?.now?.title == "Logo Movie")
        #expect(nowNext[channels["Name From Attr"]!.id!] == nil)

        // Before anything airs, the first programme is "next".
        let early = try await firstValue(database.observeNowNext(channelIDs: [channels["News One HD"]!.id!],
                                                                 at: now.addingTimeInterval(-2 * 3600)))
        #expect(early.values.first?.now == nil)
        #expect(early.values.first?.next?.title == "Morning Bulletin")
        #expect(try await firstValue(database.observeNowNext(channelIDs: [], at: now)).isEmpty)
    }

    @Test func observesGuideSlotsInAWindow() async throws {
        let source = try await syncedM3USource()
        try await service(StubDownloader()).sync(source, now: now)
        let nine = Date(timeIntervalSince1970: 1_791_968_400) // 09:00 UTC

        let slots = try await firstValue(database.observeGuide(
            sourceID: source.id!, guideIDs: ["news.one", "Sport.Two"],
            window: DateInterval(start: nine, duration: 3600)))
        #expect(slots.keys.sorted() == ["Sport.Two", "news.one"])
        // Programmes that only touch the window's edges are left out.
        #expect(slots["news.one"]?.map(\.title) == ["Midday Report"])
        #expect(slots["Sport.Two"]?.map(\.title) == ["Match of the Day", "Late Highlights"])
        #expect(slots["Sport.Two"]?.last?.stop == nil)

        let id = try #require(slots["news.one"]?.first?.id)
        #expect(try await database.programme(id: id)?.title == "Midday Report")
        #expect(try await firstValue(database.observeGuide(sourceID: source.id!, guideIDs: [],
                                                           window: DateInterval(start: nine, duration: 3600))).isEmpty)
    }

    @Test func observesGuideRange() async throws {
        let source = try await syncedM3USource()
        try await service(StubDownloader()).sync(source, now: now)
        let range = try await firstValue(database.observeGuideRange(sourceID: source.id!, guideIDs: ["news.one", "Sport.Two"]))
        #expect(range?.start == Date(timeIntervalSince1970: 1_791_963_000)) // Match of the Day, 07:30
        #expect(range?.end == Date(timeIntervalSince1970: 1_791_982_800)) // Evening News ends 13:00
        #expect(try await firstValue(database.observeGuideRange(sourceID: source.id!, guideIDs: ["nothing"])) == nil)
    }

    @Test func keepsPastProgrammesForCatchupChannels() async throws {
        let source = try await database.insertSource(Source(name: "Custom", kind: .m3u, location: "http://example.com/list.m3u",
                                                            epgURL: "http://epg.example.com/guide.xml"))
        func importGuide(catchupDays: Int?) async throws -> [String] {
            let catalog = LiveCatalog(groups: [], items: [
                LiveCatalog.Item(channel: Channel(sourceID: 0, stableKey: "news", name: "News", epgChannelID: "news.one",
                                                  catchupDays: catchupDays, catchupMode: "shift", sortIndex: 0),
                                 groupRemoteID: nil),
            ])
            try await database.replaceLiveCatalog(sourceID: source.id!, with: catalog)
            try await service(StubDownloader()).sync(source, now: now)
            return try await programmes(source.id!).map(\.title)
        }
        // Old News ended 24.5 hours before `now`.
        #expect(try await !importGuide(catchupDays: nil).contains("Old News"))
        #expect(try await importGuide(catchupDays: 2).contains("Old News"))
        #expect(try await importGuide(catchupDays: 30).count == 5)
    }

    @Test func findsChannelsByStableKey() async throws {
        let source = try await syncedM3USource()
        let channel = try await database.channel(sourceID: source.id!, stableKey: "m3u:news.one|News One HD|News")
        #expect(channel?.name == "News One HD")
        #expect(try await database.channel(sourceID: source.id!, stableKey: "missing") == nil)
    }

    @Test func catalogResyncKeepsMatchesAndOverrides() async throws {
        let source = try await syncedM3USource()
        let epg = service(StubDownloader())
        try await epg.sync(source, now: now)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE channel SET epgOverride = 'unknown.channel' WHERE name = 'Name From Attr'")
        }

        try await catalogService.sync(source)
        var channels = try await channels(source.id!)
        #expect(channels["News One HD"]?.guideID == "news.one")
        #expect(channels["Unquoted Logo"]?.guideID == "logo.channel")
        #expect(channels["Name From Attr"]?.epgOverride == "unknown.channel")
        #expect(channels["Name From Attr"]?.guideID == "unknown.channel")

        // The next guide sync stores the overridden channel's programmes too.
        try await epg.sync(source, now: now)
        channels = try await self.channels(source.id!)
        let nowNext = try await firstValue(database.observeNowNext(channelIDs: [channels["Name From Attr"]!.id!], at: now))
        #expect(nowNext.values.first?.now?.title == "Unwatched Show")
    }

    @Test func matchesProgrammesOfUndeclaredChannelsByID() async throws {
        let source = try await database.insertSource(Source(name: "Custom", kind: .m3u, location: "http://example.com/list.m3u",
                                                            epgURL: "http://epg.example.com/guide.xml"))
        let catalog = LiveCatalog(groups: [], items: [
            LiveCatalog.Item(channel: Channel(sourceID: 0, stableKey: "a", name: "Orphan", epgChannelID: "UNDECLARED.channel",
                                              sortIndex: 0), groupRemoteID: nil),
        ])
        try await database.replaceLiveCatalog(sourceID: source.id!, with: catalog)
        #expect(try await service(StubDownloader()).sync(source, now: now) == 1)
        #expect(try await channels(source.id!)["Orphan"]?.guideID == "undeclared.channel")
    }

    @Test func failedSyncKeepsPreviousGuide() async throws {
        let source = try await syncedM3USource()
        try await service(StubDownloader()).sync(source, now: now)

        let later = now.addingTimeInterval(3600)
        await #expect(throws: HTTPError.status(404)) {
            try await service(StubDownloader(statusCode: 404)).sync(source, now: later)
        }
        await #expect(throws: XMLTVError.self) {
            try await service(StubDownloader(fixture: "sample.m3u")).sync(source, now: later)
        }
        #expect(try await programmes(source.id!).count == 7)
        let saved = try #require(try await database.source(id: source.id!))
        #expect(saved.lastEPGSyncAt == now)
        #expect(saved.lastEPGSyncError != nil)
    }

    @Test func skipsSourcesWithoutGuide() async throws {
        let source = try await database.insertSource(Source(name: "No guide", kind: .m3u, location: "http://example.com/list.m3u"))
        let downloader = StubDownloader()
        #expect(!EPGSyncService.hasGuide(source))
        #expect(try await service(downloader).sync(source, now: now) == 0)
        #expect(downloader.requests.isEmpty)
    }

    @Test func xtreamGuideURLIsBuiltAtSyncTime() async throws {
        let inserted = try await database.insertSource(Source(name: "Xtream", kind: .xtream, location: "http://example.com:8080",
                                                              username: "demo", credentialKey: "xtream-key"))
        try await catalogService.sync(inserted)
        let source = try #require(try await database.source(id: inserted.id!))
        #expect(EPGSyncService.hasGuide(source))

        let downloader = StubDownloader()
        try await service(downloader).sync(source, now: now)
        #expect(downloader.requests.map(\.url?.absoluteString) == ["http://example.com:8080/xmltv.php?username=demo&password=secret"])

        let channels = try await channels(source.id!)
        #expect(channels["News One"]?.guideID == "news.one")
        #expect(channels["Sport Two"]?.guideID == "Sport.Two") // no epg_channel_id: matched by name

        // A user-entered guide URL takes precedence.
        try await database.modifySource(id: source.id!) { $0.epgURL = "http://epg.example.com/custom.xml" }
        let overridden = try #require(try await database.source(id: source.id!))
        let other = StubDownloader()
        try await service(other).sync(overridden, now: now)
        #expect(other.requests.map(\.url?.absoluteString) == ["http://epg.example.com/custom.xml"])
    }

    @Test func noCredentialsAreStoredInTheDatabase() async throws {
        let inserted = try await database.insertSource(Source(name: "Xtream", kind: .xtream, location: "http://example.com:8080",
                                                              username: "demo", credentialKey: "xtream-key"))
        try await catalogService.sync(inserted)
        let source = try #require(try await database.source(id: inserted.id!))
        try await service(StubDownloader()).sync(source, now: now)
        // A failure whose message contains the guide URL must not leak it either.
        await #expect(throws: StubDownloader.Failure.self) {
            try await service(StubDownloader(fails: true)).sync(source, now: now)
        }
        #expect(try await database.source(id: source.id!)?.lastEPGSyncError?.contains("xmltv.php") == true)

        let texts = try await database.reader.read { db in
            var texts: [String] = []
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            for table in tables {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table.quotedDatabaseIdentifier)") {
                    for (_, value) in row {
                        if case .string(let text) = value.storage { texts.append(text) }
                    }
                }
            }
            return texts
        }
        #expect(!texts.isEmpty)
        #expect(texts.filter { $0.contains("secret") } == [])
    }
}
