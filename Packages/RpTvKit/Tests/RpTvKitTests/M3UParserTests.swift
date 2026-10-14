// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

struct M3UParserTests {
    private func loadSample() throws -> (header: M3UHeader, entries: [M3UEntry]) {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "m3u", subdirectory: "Fixtures"))
        return M3UParser.parse(try String(contentsOf: url, encoding: .utf8))
    }

    @Test func parsesHeaderEPGURLsAcrossBOMAndCRLF() throws {
        let (header, _) = try loadSample()
        #expect(header.epgURLs == [
            "http://epg.example.com/guide.xml.gz",
            "http://epg2.example.com/g.xml",
            "http://epg3.example.com/a.xml",
        ])
    }

    @Test func parsesEveryEntry() throws {
        let (_, entries) = try loadSample()
        #expect(entries.map(\.name) == ["News One HD", "Sport 2, Extra", "Unquoted Logo", "Name From Attr", "bare-entry"])
    }

    @Test func parsesQuotedAttributes() throws {
        let entry = try loadSample().entries[0]
        #expect(entry.tvgID == "news.one")
        #expect(entry.tvgName == "News One")
        #expect(entry.logo == "http://logo.example.com/n1.png")
        #expect(entry.group == "News")
        #expect(entry.url == "http://stream.example.com/live/news1.m3u8")
        #expect(entry.duration == -1)
    }

    @Test func keepsCommasInsideQuotedGroupAndTitle() throws {
        let entry = try loadSample().entries[1]
        #expect(entry.group == "Sports, Live")
        #expect(entry.name == "Sport 2, Extra")
        #expect(entry.channelNumber == 7)
        #expect(entry.catchupDays == 3)
        #expect(entry.catchupMode == "shift")
        #expect(entry.catchupSource == nil)
    }

    @Test func readsCatchupFromEntryOrPlaylistHeader() {
        let (_, entries) = M3UParser.parse("""
            #EXTM3U catchup="append" catchup-source="?utc={utc}" catchup-days="5"
            #EXTINF:-1,From Header
            http://stream.example.com/a.m3u8
            #EXTINF:-1 catchup="flussonic" catchup-days="2",Own Mode
            http://stream.example.com/b/index.m3u8
            #EXTINF:-1 catchup-type="Default" catchup-source="http://archive.example.com/{utc}",Own Source
            http://stream.example.com/c.m3u8
            """)
        #expect(entries.map(\.catchupMode) == ["append", "flussonic", "default"])
        #expect(entries.map(\.catchupSource) == ["?utc={utc}", "?utc={utc}", "http://archive.example.com/{utc}"])
        #expect(entries.map(\.catchupDays) == [5, 2, 5])
    }

    @Test func catchupModeWithoutDaysMeansAWeek() {
        let (_, entries) = M3UParser.parse("""
            #EXTM3U
            #EXTINF:-1 catchup="shift",Shifted
            http://stream.example.com/a.m3u8
            #EXTINF:-1,Plain
            http://stream.example.com/b.m3u8
            """)
        #expect(entries[0].catchupDays == 7)
        #expect(entries[1].catchupMode == nil)
        #expect(entries[1].catchupDays == nil)
    }

    @Test func readsVLCOptionHeaders() throws {
        let entries = try loadSample().entries
        #expect(entries[1].userAgent == "CustomAgent/1.0")
        #expect(entries[1].referrer == "http://ref.example.com/")
        // Options apply to one entry only.
        #expect(entries[2].userAgent == nil)
    }

    @Test func handlesUnquotedAttributesAndEXTGRP() throws {
        let entry = try loadSample().entries[2]
        #expect(entry.logo == "http://logo.example.com/plain.png")
        #expect(entry.group == "Movies")
        #expect(entry.duration == 0)
    }

    @Test func fallsBackToTvgNameThenURLForNames() throws {
        let entries = try loadSample().entries
        #expect(entries[3].name == "Name From Attr")
        #expect(entries[4].name == "bare-entry")
        #expect(entries[4].attributes.isEmpty)
    }

    @Test func ignoresLinesThatArentURLs() {
        let (_, entries) = M3UParser.parse("""
            #EXTM3U
            #EXTINF:-1,Stray Text
            not a url
            /local/path.ts
            #EXTINF:-1,Multicast
            udp://@239.0.0.1:1234
            """)
        #expect(entries.map(\.name) == ["Multicast"])
        #expect(entries.map(\.url) == ["udp://@239.0.0.1:1234"])
    }

    @Test(arguments: [
        ("<?xml version=\"1.0\"?>\n<tv>\n<icon src=\"http://logo.example.com/a.png\"/>\n</tv>", M3UForeignContent.guide),
        ("<tv generator-info-name=\"x\">\n</tv>", .guide),
        ("\n<!DOCTYPE html>\n<html><a href=\"http://example.com/x\">x</a></html>", .webPage),
        ("\u{1F}\u{FFFD}\u{8}\nhttp://stream.example.com/a.ts", .binary),
    ])
    func recognizesFilesThatArentPlaylists(text: String, expected: M3UForeignContent) {
        var parser = M3UParser()
        var entries: [M3UEntry] = []
        text.enumerateLines { line, _ in
            if let entry = parser.consume(line) { entries.append(entry) }
        }
        #expect(parser.foreignContent == expected)
        #expect(entries.isEmpty)
    }

    @Test func playlistsArentForeign() throws {
        var parser = M3UParser()
        _ = parser.consume("\u{FEFF}#EXTM3U")
        _ = parser.consume("#EXTINF:-1,A")
        _ = parser.consume("http://stream.example.com/a.ts")
        #expect(parser.foreignContent == nil)
    }

    @Test func parsesLargePlaylistQuickly() {
        var text = "#EXTM3U\n"
        for index in 0..<50_000 {
            text += "#EXTINF:-1 tvg-id=\"ch\(index)\" tvg-logo=\"http://logo/\(index).png\" group-title=\"Group \(index % 40)\",Channel \(index)\n"
            text += "http://stream.example.com/live/\(index).ts\n"
        }
        let clock = ContinuousClock()
        var result: (header: M3UHeader, entries: [M3UEntry])!
        let elapsed = clock.measure { result = M3UParser.parse(text) }
        #expect(result.entries.count == 50_000)
        #expect(result.entries.last?.tvgID == "ch49999")
        #expect(elapsed < .seconds(10), "Parsing 50k entries took \(elapsed)")
    }
}
