// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

private func utc(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

struct XMLTVDateTests {
    @Test(arguments: [
        ("20261013120000 +0200", "2026-10-13T10:00:00Z"),
        ("20261013120000 -0530", "2026-10-13T17:30:00Z"),
        ("20261013120000 +02:00", "2026-10-13T10:00:00Z"),
        ("20261013120000+0000", "2026-10-13T12:00:00Z"),
        ("20261013120000", "2026-10-13T12:00:00Z"),
        ("202610131205", "2026-10-13T12:05:00Z"),
        ("2026101312", "2026-10-13T12:00:00Z"),
        ("20240229235959 +0000", "2024-02-29T23:59:59Z"),
        ("20270101003000 +0100", "2026-12-31T23:30:00Z"),
    ])
    func parsesTimestamps(text: String, expected: String) {
        #expect(XMLTVDate.parse(text) == utc(expected))
    }

    @Test(arguments: ["", "garbage", "2026", "20261313120000", "20261013250000", "2026-10-13 12:00"])
    func rejectsInvalidTimestamps(text: String) {
        #expect(XMLTVDate.parse(text) == nil)
    }
}

struct XMLTVParserTests {
    private func parse(_ file: URL) throws -> (channels: [XMLTVChannel], programmes: [XMLTVProgramme]) {
        var channels: [XMLTVChannel] = []
        var programmes: [XMLTVProgramme] = []
        try XMLTVParser.parse(file) { channels.append($0) } programme: { programmes.append($0) }
        return (channels, programmes)
    }

    @Test func parsesChannelsAndProgrammes() throws {
        let (channels, programmes) = try parse(Fixture.url("epg/guide.xml"))

        #expect(channels.map(\.id) == ["news.one", "Sport.Two", "logo.channel", "unknown.channel"])
        #expect(channels[0].displayNames == ["News One", "Nouvelles Un"])
        #expect(channels[0].iconURL == "http://logo.example.com/news-one.png")

        // Programmes without a valid start are skipped.
        #expect(programmes.count == 10)
        let bulletin = try #require(programmes.first { $0.title == "Morning Bulletin" })
        #expect(bulletin.channel == "news.one")
        #expect(bulletin.start == utc("2026-10-14T08:00:00Z"))
        #expect(bulletin.stop == utc("2026-10-14T09:00:00Z"))
        #expect(bulletin.summary == "The headlines & the weather.")
        #expect(bulletin.category == "News")
        #expect(bulletin.iconURL == "http://img.example.com/bulletin.jpg")

        let talk = try #require(programmes.first { $0.title == "Afternoon Talk" })
        #expect(talk.start == utc("2026-10-14T10:00:00Z"))
        #expect(talk.stop == nil)
        #expect(programmes.first { $0.title == "Midday Report" }?.start == utc("2026-10-14T09:00:00Z"))
    }

    @Test func gzippedGuideParsesTheSame() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appending(component: "download.tmp")
        try FileManager.default.copyItem(at: Fixture.url("epg/guide.xml.gz"), to: copy)

        #expect(try GzipInflater.isGzip(copy))
        let inflated = try GzipInflater.inflateIfNeeded(copy)
        #expect(inflated != copy)

        let plain = try parse(Fixture.url("epg/guide.xml"))
        let unzipped = try parse(inflated)
        #expect(unzipped.channels == plain.channels)
        #expect(unzipped.programmes == plain.programmes)

        let plainFile = try Fixture.url("epg/guide.xml")
        #expect(try GzipInflater.inflateIfNeeded(plainFile) == plainFile)
    }

    @Test func rejectsCorruptGzip() throws {
        let file = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).gz")
        defer { try? FileManager.default.removeItem(at: file) }
        try (Data([0x1F, 0x8B, 0x08, 0x00]) + Data(repeating: 0x42, count: 64)).write(to: file)
        #expect(throws: GzipError.corrupt) { try GzipInflater.inflateIfNeeded(file) }
    }

    @Test func keepsWhatWasReadBeforeBrokenXML() throws {
        let file = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
            <tv><programme start="20261014080000" channel="a"><title>One</title></programme>
            <programme start="20261014090000" channel="a"><title>Two & broken</title></programme></tv>
            """.write(to: file, atomically: true, encoding: .utf8)
        #expect(try parse(file).programmes.map(\.title) == ["One"])

        try "not xml at all".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: XMLTVError.self) { try parse(file) }
    }

    @Test func rethrowsCallbackErrors() throws {
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try XMLTVParser.parse(Fixture.url("epg/guide.xml")) { _ in throw Stop() } programme: { _ in }
        }
    }

    @Test func parsesHundredThousandProgrammesQuickly() throws {
        let file = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        var chunk = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        for channel in 0..<500 {
            chunk += "<channel id=\"ch\(channel).example\"><display-name>Channel \(channel)</display-name></channel>\n"
        }
        for channel in 0..<500 {
            for slot in 0..<200 {
                let hour = String(format: "%02d", slot % 24)
                chunk += """
                    <programme start="202610\(14 + slot / 24)\(hour)0000 +0000" stop="202610\(14 + slot / 24)\(hour)5900 +0000" \
                    channel="ch\(channel).example"><title lang="en">Show \(slot)</title>\
                    <desc lang="en">Episode \(slot) of a synthetic series on channel \(channel).</desc>\
                    <category lang="en">Synthetic</category></programme>\n
                    """
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            chunk = ""
        }
        try handle.write(contentsOf: Data("</tv>\n".utf8))
        try handle.close()

        var count = 0
        let elapsed = try ContinuousClock().measure {
            try XMLTVParser.parse(file) { _ in } programme: { _ in count += 1 }
        }
        #expect(count == 100_000)
        #expect(elapsed < .seconds(10))
    }
}

struct GuideMatcherTests {
    @Test(arguments: [
        ("News One HD", "newsone"),
        ("Movie Max FHD", "moviemax"),
        ("movie-max", "moviemax"),
        ("Télé Ünique", "teleunique"),
        ("Sport.2 UHD 4K", "sport2"),
        ("HD", "hd"),
        ("  Kids  &  Family  ", "kidsfamily"),
    ])
    func normalizesNames(name: String, expected: String) {
        #expect(GuideMatcher.normalize(name) == expected)
    }

    @Test func prefersOverrideThenIDThenName() {
        let matcher = GuideMatcher(channels: [
            GuideChannel(sourceID: 1, id: "News.One", name: "News One", names: "News One\nNouvelles"),
            GuideChannel(sourceID: 1, id: "movie.max", name: "Movie Max HD", names: "Movie Max HD"),
        ])
        typealias Target = GuideMatcher.Target
        #expect(matcher.guideID(for: Target(epgChannelID: "news.one", name: "Whatever")) == "News.One")
        #expect(matcher.guideID(for: Target(epgChannelID: "missing", name: "Movie Max")) == "movie.max")
        #expect(matcher.guideID(for: Target(epgChannelID: nil, name: "NOUVELLES")) == "News.One")
        #expect(matcher.guideID(for: Target(epgChannelID: "news.one", epgOverride: "other.id", name: "x")) == "other.id")
        #expect(matcher.guideID(for: Target(epgChannelID: nil, name: "Nothing Like It")) == nil)
    }
}
