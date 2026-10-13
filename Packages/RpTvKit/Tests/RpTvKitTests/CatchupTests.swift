// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

struct CatchupTests {
    /// 2026-10-14 08:00 UTC.
    let start = Date(timeIntervalSince1970: 1_791_964_800)
    /// 2026-10-14 09:00 UTC.
    let end = Date(timeIntervalSince1970: 1_791_968_400)
    /// 2026-10-14 09:30 UTC.
    let now = Date(timeIntervalSince1970: 1_791_970_200)

    private func url(_ streamURL: String, mode: String, source: String? = nil) -> String? {
        Catchup.m3uURL(streamURL: streamURL, mode: mode, source: source, start: start, end: end, now: now)?.absoluteString
    }

    // MARK: - Xtream

    private let credentials = InMemoryCredentialStore(["xtream-key": "secret"])

    private func xtreamSource(timeZone: String?) -> Source {
        Source(id: 1, name: "Xtream", kind: .xtream, location: "http://example.com:8080", username: "demo",
               credentialKey: "xtream-key", serverTimeZone: timeZone)
    }

    private let xtreamChannel = Channel(sourceID: 1, stableKey: "xtream:101", name: "News One", xtreamStreamID: 101,
                                        catchupDays: 7, sortIndex: 0)

    @Test func xtreamUsesTheServerTimeZone() throws {
        let programme = Programme(sourceID: 1, epgChannelID: "news.one", start: start,
                                  stop: start.addingTimeInterval(90 * 60), title: "Midday Report")
        let item = try PlaybackResolver(credentials: credentials)
            .catchupItem(for: xtreamChannel, programme: programme, in: xtreamSource(timeZone: "Europe/Vilnius"), now: now)
        // Vilnius is UTC+3 in October.
        #expect(item.url.absoluteString == "http://example.com:8080/timeshift/demo/secret/90/2026-10-14:11-00/101.ts")
        #expect(!item.isLive)
        #expect(item.id == "xtream:101#catchup")
        #expect(item.title == "News One")
        #expect(item.subtitle == "Midday Report")
    }

    @Test func xtreamFallsBackToUTCAndRoundsMinutesUp() throws {
        let resolver = PlaybackResolver(credentials: credentials)
        let odd = Programme(sourceID: 1, epgChannelID: "x", start: start, stop: start.addingTimeInterval(61.5 * 60), title: "Odd")
        #expect(try resolver.catchupItem(for: xtreamChannel, programme: odd, in: xtreamSource(timeZone: nil), now: now).url
            .absoluteString == "http://example.com:8080/timeshift/demo/secret/62/2026-10-14:08-00/101.ts")
        let open = Programme(sourceID: 1, epgChannelID: "x", start: start, title: "No end")
        #expect(try resolver.catchupItem(for: xtreamChannel, programme: open, in: xtreamSource(timeZone: "Not/AZone"), now: now)
            .url.absoluteString == "http://example.com:8080/timeshift/demo/secret/60/2026-10-14:08-00/101.ts")
    }

    @Test func refusesChannelsWithoutArchive() {
        var channel = xtreamChannel
        channel.catchupDays = nil
        let programme = Programme(sourceID: 1, epgChannelID: "x", start: start, stop: end, title: "Show")
        #expect(throws: CatchupError.unavailable) {
            try PlaybackResolver(credentials: credentials).catchupItem(for: channel, programme: programme,
                                                                       in: xtreamSource(timeZone: nil), now: now)
        }
    }

    @Test func m3uItemKeepsChannelHeaders() throws {
        let channel = Channel(sourceID: 2, stableKey: "m3u:a", name: "Sport", streamURL: "http://stream.example.com/live/a.m3u8",
                              catchupDays: 3, catchupMode: "shift", userAgent: "Agent/1", sortIndex: 0)
        let source = Source(id: 2, name: "M3U", kind: .m3u, location: "http://example.com/list.m3u")
        let programme = Programme(sourceID: 2, epgChannelID: "a", start: start, stop: end, title: "Match")
        let item = try PlaybackResolver(credentials: credentials).catchupItem(for: channel, programme: programme, in: source, now: now)
        #expect(item.url.absoluteString == "http://stream.example.com/live/a.m3u8?utc=1791964800&lutc=1791970200")
        #expect(item.headers["User-Agent"] == "Agent/1")
        #expect(!item.isLive)
    }

    // MARK: - M3U modes

    @Test func defaultModeFillsTheSourceTemplate() {
        #expect(url("http://stream.example.com/live/a.m3u8", mode: "default",
                    source: "http://archive.example.com/a/{utc}/{utcend}/{duration}.m3u8")
            == "http://archive.example.com/a/1791964800/1791968400/3600.m3u8")
        #expect(url("http://stream.example.com/live/a.m3u8", mode: "default") == nil)
    }

    @Test func appendModeAddsTheSourceToTheStreamURL() {
        #expect(url("http://stream.example.com/live/a.m3u8", mode: "append", source: "?start={utc}&end={utcend}")
            == "http://stream.example.com/live/a.m3u8?start=1791964800&end=1791968400")
        #expect(url("http://stream.example.com/live/a.m3u8?token=t", mode: "append", source: "?utc={utc}")
            == "http://stream.example.com/live/a.m3u8?token=t&utc=1791964800")
        #expect(url("http://stream.example.com/live/a.m3u8", mode: "append") == nil)
    }

    @Test func shiftModeAddsUTCParameters() {
        #expect(url("http://stream.example.com/live/a.m3u8", mode: "shift")
            == "http://stream.example.com/live/a.m3u8?utc=1791964800&lutc=1791970200")
        #expect(url("http://stream.example.com/live/a.m3u8?token=t", mode: "timeshift")
            == "http://stream.example.com/live/a.m3u8?token=t&utc=1791964800&lutc=1791970200")
    }

    @Test func flussonicModeRewritesThePath() {
        #expect(url("http://fs.example.com/news/index.m3u8?token=abc", mode: "flussonic")
            == "http://fs.example.com/news/index-1791964800-3600.m3u8?token=abc")
        #expect(url("https://fs.example.com:8443/tv/news/video.m3u8", mode: "flussonic-hls")
            == "https://fs.example.com:8443/tv/news/video-1791964800-3600.m3u8")
        #expect(url("http://fs.example.com/news/mpegts?token=abc", mode: "fs")
            == "http://fs.example.com/news/timeshift_abs-1791964800.ts?token=abc")
        #expect(url("http://fs.example.com/index.m3u8", mode: "flussonic") == nil)
        #expect(url("http://fs.example.com/news/stream.mp4", mode: "flussonic") == nil)
    }

    @Test func unknownModeBuildsNothing() {
        #expect(url("http://stream.example.com/live/a.m3u8", mode: "vod", source: "{utc}") == nil)
    }

    // MARK: - Templates

    @Test(arguments: [
        ("{utc}|{start}|${start}", "1791964800|1791964800|1791964800"),
        ("{utcend}|{end}|${end}", "1791968400|1791968400|1791968400"),
        ("{lutc}|{now}|${now}|{timestamp}|${timestamp}", "1791970200|1791970200|1791970200|1791970200|1791970200"),
        ("{duration}|{duration:60}|{offset}|{offset:60}", "3600|60|5400|90"),
        ("{Y}-{m}-{d}T{H}:{M}:{S}", "2026-10-14T08:00:00"),
        ("{utc:Y-m-d}/{end:H-M}/{lutc:YmdHMS}", "2026-10-14/09-00/20261014093000"),
        ("{unknown}/{duration:x}/plain", "{unknown}/{duration:x}/plain"),
    ])
    func expandsPlaceholders(template: String, expected: String) {
        #expect(Catchup.expand(template, start: start, end: end, now: now) == expected)
    }

    // MARK: - Availability

    private func m3uChannel(mode: String?, source: String? = nil, days: Int? = 3) -> Channel {
        Channel(sourceID: 2, stableKey: "m3u:a", name: "A", streamURL: "http://stream.example.com/live/a.m3u8",
                catchupDays: days, catchupMode: mode, catchupSource: source, sortIndex: 0)
    }

    private func programme(startingHoursAgo hours: Double) -> Programme {
        let start = now.addingTimeInterval(-hours * 3600)
        return Programme(sourceID: 2, epgChannelID: "a", start: start, stop: start.addingTimeInterval(3600), title: "Show")
    }

    @Test func playableOnlyWithinTheArchiveWindow() {
        let channel = m3uChannel(mode: "shift")
        #expect(channel.canCatchUp)
        #expect(channel.isCatchupPlayable(programme(startingHoursAgo: 24), now: now))
        #expect(channel.isCatchupPlayable(programme(startingHoursAgo: 0.5), now: now)) // on air: watch from start
        #expect(channel.isCatchupPlayable(programme(startingHoursAgo: 72), now: now))
        #expect(!channel.isCatchupPlayable(programme(startingHoursAgo: 73), now: now))
        #expect(!channel.isCatchupPlayable(programme(startingHoursAgo: -1), now: now)) // not started
    }

    @Test func needsAModeTheAppKnows() {
        #expect(!m3uChannel(mode: nil).canCatchUp)
        #expect(!m3uChannel(mode: "vod").canCatchUp)
        #expect(!m3uChannel(mode: "default").canCatchUp)
        #expect(m3uChannel(mode: "default", source: "http://archive.example.com/{utc}").canCatchUp)
        #expect(!m3uChannel(mode: "shift", days: nil).canCatchUp)
        #expect(!m3uChannel(mode: "shift", days: 0).canCatchUp)
        #expect(!m3uChannel(mode: nil).isCatchupPlayable(programme(startingHoursAgo: 1), now: now))
    }
}
