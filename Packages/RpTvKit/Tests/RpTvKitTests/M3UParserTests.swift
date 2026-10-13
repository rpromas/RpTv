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
