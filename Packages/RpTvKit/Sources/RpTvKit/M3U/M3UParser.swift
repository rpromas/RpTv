// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One playable item from an M3U playlist.
public struct M3UEntry: Sendable, Hashable {
    public var name: String
    public var url: String
    public var duration: Int?
    /// `#EXTINF` attributes with lowercased keys, e.g. `tvg-id`, `tvg-logo`, `group-title`.
    public var attributes: [String: String]
    public var group: String?
    public var userAgent: String?
    public var referrer: String?
    /// The `catchup` mode (lowercased), from the entry or else the `#EXTM3U` line.
    public var catchupMode: String?
    /// The `catchup-source` template, from the entry or else the `#EXTM3U` line.
    public var catchupSource: String?
    /// Days of archive (`catchup-days`, `tvg-rec` or `timeshift`), from the entry or else the `#EXTM3U` line.
    /// A catch-up mode with no days given counts as a week.
    public var catchupDays: Int?

    public var tvgID: String? { attributes["tvg-id"].nonEmpty }
    public var tvgName: String? { attributes["tvg-name"].nonEmpty }
    public var logo: String? { (attributes["tvg-logo"] ?? attributes["logo"]).nonEmpty }
    public var channelNumber: Int? { (attributes["tvg-chno"] ?? attributes["channel-number"]).flatMap { Int($0) } }

    /// What an entry holds.
    public enum ContentKind: Sendable, Hashable {
        case live
        case movie
        /// An episode, whose name gives the series, season and number (see ``EpisodeName``).
        case episode
    }

    /// What the entry holds, judged by its URL path (`/movie/`, `/series/`) or a recording's file extension
    /// outside a live group. Recordings named like "Show S01E02" are episodes; other `/series/` entries count as
    /// movies so they can still be played.
    public var contentKind: ContentKind {
        let path = (URLComponents(string: url)?.path ?? url).lowercased()
        if path.contains("/movie/") { return .movie }
        if path.contains("/series/") { return episodeName == nil ? .movie : .episode }
        let fileExtension = (path as NSString).pathExtension
        if Self.vodExtensions.contains(fileExtension), !Self.isLiveGroup(group) {
            return episodeName == nil ? .movie : .episode
        }
        return .live
    }

    /// The series, season and episode number in the entry's name, if it has them.
    public var episodeName: EpisodeName? { EpisodeName(parsing: name) }

    /// File types that are recordings rather than streams. MPEG-TS (`.ts`) is left out: live channels use it.
    static let vodExtensions: Set<String> = ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "flv", "webm", "mpg", "mpeg", "divx", "ogv", "3gp"]

    /// Groups like "Live Sports" or "24/7 Movies" hold channels that loop files, so their entries stay live.
    static func isLiveGroup(_ group: String?) -> Bool {
        guard let group = group?.lowercased() else { return false }
        let words = group.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains("live") || group.contains("24/7")
    }

    static let defaultCatchupDays = 7

    static func catchupDays(in attributes: [String: String]) -> Int? {
        (attributes["catchup-days"] ?? attributes["tvg-rec"] ?? attributes["timeshift"]).flatMap { Int($0) }
    }

    static func catchupMode(in attributes: [String: String]) -> String? {
        (attributes["catchup"] ?? attributes["catchup-type"]).nonEmpty?.lowercased()
    }
}

/// Playlist-level attributes from the `#EXTM3U` line.
public struct M3UHeader: Sendable, Hashable {
    public var attributes: [String: String] = [:]

    /// Guide URLs advertised by the playlist (`url-tvg`, `x-tvg-url`, `tvg-url`), possibly comma separated.
    public var epgURLs: [String] {
        ["url-tvg", "x-tvg-url", "tvg-url"]
            .compactMap { attributes[$0] }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// What a file given as a playlist turns out to be instead, judged by its first line.
public enum M3UForeignContent: Sendable, Equatable {
    /// XML, almost always an XMLTV guide.
    case guide
    /// An HTML page, such as a provider's error or login page.
    case webPage
    /// Binary data, almost always a gzipped guide (`.xml.gz`).
    case binary

    init?(firstLine line: String) {
        if let first = line.unicodeScalars.first, first.properties.generalCategory == .control || first == "\u{FFFD}" {
            self = .binary
        } else if line.hasPrefix("<") {
            let lowercased = line.lowercased()
            self = lowercased.hasPrefix("<!doctype html") || lowercased.hasPrefix("<html") ? .webPage : .guide
        } else {
            return nil
        }
    }
}

/// Incremental M3U parser. Feed it lines one at a time so large playlists never sit in memory as one string.
public struct M3UParser: Sendable {
    public private(set) var header = M3UHeader()
    /// Set when the first line shows the file isn't a playlist. The parser then ignores the rest.
    public private(set) var foreignContent: M3UForeignContent?

    private var isFirstLine = true
    private var sawContent = false
    private var pendingInfo: (duration: Int?, attributes: [String: String], title: String)?
    private var pendingGroup: String?
    private var pendingUserAgent: String?
    private var pendingReferrer: String?

    public init() {}

    /// Consumes one line and returns an entry when the line completes one (that is, when it is a URL).
    public mutating func consume(_ rawLine: some StringProtocol) -> M3UEntry? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFirstLine {
            isFirstLine = false
            if line.unicodeScalars.first == "\u{FEFF}" {
                line = String(line.unicodeScalars.dropFirst())
            }
        }
        guard !line.isEmpty else { return nil }
        if !sawContent {
            sawContent = true
            foreignContent = M3UForeignContent(firstLine: line)
        }
        guard foreignContent == nil else { return nil }

        if line.hasPrefix("#") {
            consumeDirective(line)
            return nil
        }
        guard Self.startsWithScheme(line) else { return nil }
        return makeEntry(url: line)
    }

    /// Parses a whole playlist held in memory.
    public static func parse(_ text: String) -> (header: M3UHeader, entries: [M3UEntry]) {
        var parser = M3UParser()
        var entries: [M3UEntry] = []
        text.enumerateLines { line, _ in
            if let entry = parser.consume(line) { entries.append(entry) }
        }
        return (parser.header, entries)
    }

    private mutating func consumeDirective(_ line: String) {
        if let rest = line.dropPrefix("#EXTM3U") {
            header.attributes.merge(Self.parseAttributes(rest)) { _, new in new }
        } else if let rest = line.dropPrefix("#EXTINF:") {
            pendingInfo = Self.parseInfo(rest)
        } else if let rest = line.dropPrefix("#EXTGRP:") {
            pendingGroup = rest.trimmingCharacters(in: .whitespaces).nonEmpty
        } else if let rest = line.dropPrefix("#EXTVLCOPT:") {
            let option = rest.trimmingCharacters(in: .whitespaces)
            guard let equals = option.firstIndex(of: "=") else { return }
            let key = option[..<equals].lowercased()
            let value = String(option[option.index(after: equals)...])
            switch key {
            case "http-user-agent": pendingUserAgent = value.nonEmpty
            case "http-referrer", "http-referer": pendingReferrer = value.nonEmpty
            default: break
            }
        }
    }

    private mutating func makeEntry(url: String) -> M3UEntry {
        defer {
            pendingInfo = nil
            pendingGroup = nil
            pendingUserAgent = nil
            pendingReferrer = nil
        }
        let attributes = pendingInfo?.attributes ?? [:]
        let name = pendingInfo?.title.nonEmpty
            ?? attributes["tvg-name"].nonEmpty
            ?? Self.fallbackName(for: url)
        let catchupMode = M3UEntry.catchupMode(in: attributes) ?? M3UEntry.catchupMode(in: header.attributes)
        let catchupDays = M3UEntry.catchupDays(in: attributes) ?? M3UEntry.catchupDays(in: header.attributes)
        return M3UEntry(
            name: name,
            url: url,
            duration: pendingInfo?.duration,
            attributes: attributes,
            group: attributes["group-title"].nonEmpty ?? pendingGroup,
            userAgent: pendingUserAgent ?? attributes["http-user-agent"].nonEmpty,
            referrer: pendingReferrer ?? attributes["http-referrer"].nonEmpty,
            catchupMode: catchupMode,
            catchupSource: attributes["catchup-source"].nonEmpty ?? header.attributes["catchup-source"].nonEmpty,
            catchupDays: catchupDays ?? (catchupMode == nil ? nil : M3UEntry.defaultCatchupDays)
        )
    }

    /// Splits `-1 tvg-id="a" group-title="News, Local",Channel Name` into duration, attributes and title,
    /// at the first comma outside quotes.
    static func parseInfo(_ text: Substring) -> (duration: Int?, attributes: [String: String], title: String) {
        var inQuotes = false
        var splitIndex: Substring.Index?
        for index in text.indices {
            let character = text[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                splitIndex = index
                break
            }
        }
        let meta = splitIndex.map { text[..<$0] } ?? text
        let title = splitIndex.map { text[text.index(after: $0)...] } ?? ""

        let trimmedMeta = meta.drop { $0.isWhitespace }
        let durationEnd = trimmedMeta.firstIndex { $0.isWhitespace } ?? trimmedMeta.endIndex
        let durationText = trimmedMeta[..<durationEnd]
        let duration = Int(durationText) ?? Double(durationText).map { Int($0) }
        let attributes = parseAttributes(trimmedMeta[durationEnd...])

        return (duration, attributes, title.trimmingCharacters(in: .whitespaces))
    }

    /// Parses `key="value" key2='value' key3=value` pairs. Keys are lowercased.
    static func parseAttributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex

        func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        }

        while true {
            skipWhitespace()
            guard index < text.endIndex else { break }

            let keyStart = index
            while index < text.endIndex, text[index] != "=", !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let key = text[keyStart..<index].lowercased()
            guard index < text.endIndex, text[index] == "=" else { continue }
            index = text.index(after: index)

            let value: Substring
            if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                let valueStart = index
                while index < text.endIndex, text[index] != quote { index = text.index(after: index) }
                value = text[valueStart..<index]
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let valueStart = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                value = text[valueStart..<index]
            }
            if !key.isEmpty { result[key] = String(value) }
        }
        return result
    }

    /// Whether a line starts like a stream URL (`scheme://`). Other lines aren't entries.
    static func startsWithScheme(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), line[colon...].hasPrefix("://") else { return false }
        let scheme = line[..<colon]
        return scheme.first?.isLetter == true
            && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    private static func fallbackName(for url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        let last = (components.path as NSString).lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        return stem.nonEmpty ?? components.host ?? url
    }
}

private extension String {
    /// Returns the rest of the string after `prefix`, compared case-insensitively.
    func dropPrefix(_ prefix: String) -> Substring? {
        let head = self.prefix(prefix.count)
        guard head.count == prefix.count, head.caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        return self[head.endIndex...]
    }
}
