// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum CatchupError: LocalizedError, Equatable {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This programme isn't in the channel's catch-up archive."
        }
    }
}

/// Archive ("catch-up") URLs for M3U channels, following the conventions of Kodi's IPTV Simple client.
/// Xtream channels use `XtreamCredentials.timeshiftURL` instead.
public enum Catchup {
    /// How the playlist says its archive URLs are built (the M3U `catchup` attribute).
    public enum Mode: String, Sendable {
        /// `catchup-source` is the whole archive URL.
        case `default`
        /// `catchup-source` is appended to the stream URL.
        case append
        /// `utc` and `lutc` query parameters are added to the stream URL.
        case shift
        /// The stream URL is rewritten the way Flussonic servers expect.
        case flussonic

        public init?(_ raw: String) {
            switch raw.lowercased() {
            case "default": self = .default
            case "append": self = .append
            case "shift", "timeshift": self = .shift
            case "flussonic", "flussonic-hls", "flussonic-ts", "fs": self = .flussonic
            default: return nil
            }
        }

        /// Whether the mode needs a `catchup-source` template.
        var needsSource: Bool { self == .default || self == .append }
    }

    /// The archive URL of the programme from `start` to `end` on an M3U channel, or nil when the
    /// mode is unknown or the URL can't be built.
    public static func m3uURL(streamURL: String, mode: String, source: String?, start: Date, end: Date,
                              now: Date) -> URL? {
        guard let mode = Mode(mode) else { return nil }
        let template: String
        switch mode {
        case .default:
            guard let source else { return nil }
            template = source
        case .append:
            guard let source else { return nil }
            // `?utc=…` after a URL that already has a query joins it with `&`.
            template = streamURL + (streamURL.contains("?") && source.hasPrefix("?") ? "&" + source.dropFirst() : source)
        case .shift:
            template = streamURL + (streamURL.contains("?") ? "&" : "?") + "utc={utc}&lutc={lutc}"
        case .flussonic:
            guard let flussonic = flussonicTemplate(streamURL) else { return nil }
            template = flussonic
        }
        return URL(string: expand(template, start: start, end: end, now: now))
    }

    /// `http://host/channel/index.m3u8?token=t` → `http://host/channel/index-{utc}-{duration}.m3u8?token=t`,
    /// `http://host/channel/mpegts` → `http://host/channel/timeshift_abs-{utc}.ts`.
    static func flussonicTemplate(_ streamURL: String) -> String? {
        guard let components = URLComponents(string: streamURL), components.host != nil else { return nil }
        var path = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count >= 2, let file = path.popLast() else { return nil }
        let newFile: String
        if file == "mpegts" {
            newFile = "timeshift_abs-{utc}.ts"
        } else if file.hasSuffix(".m3u8") {
            newFile = "\(file.dropLast(5))-{utc}-{duration}.m3u8"
        } else {
            return nil
        }
        var prefix = components
        prefix.percentEncodedPath = ""
        prefix.percentEncodedQuery = nil
        prefix.fragment = nil
        guard let root = prefix.string else { return nil }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return root + "/" + path.joined(separator: "/") + "/" + newFile + query
    }

    // MARK: - Templates

    /// Fills in the placeholders of a catch-up template. Times are Unix seconds; date parts are UTC.
    ///
    /// - `{utc}`, `{start}`, `${start}`: programme start. `{utcend}`, `{end}`, `${end}`: programme end.
    /// - `{lutc}`, `{now}`, `${now}`, `{timestamp}`, `${timestamp}`: the current time.
    /// - `{duration}`, `{offset}` (seconds since the start), optionally divided: `{duration:60}`.
    /// - `{Y}`, `{m}`, `{d}`, `{H}`, `{M}`, `{S}`: parts of the start time.
    /// - `{utc:Y-m-d H:M:S}` and the same for the other times: a time formatted with those letters.
    ///
    /// Unknown placeholders are left as they are.
    public static func expand(_ template: String, start: Date, end: Date, now: Date) -> String {
        let times = Times(start: start, end: end, now: now)
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            var head = rest[..<open]
            let hasDollar = head.last == "$"
            if hasDollar { head = head.dropLast() }
            let body = rest[rest.index(after: open)..<close]
            if let value = times.value(for: body) {
                result += head
                result += value
            } else {
                result += rest[..<rest.index(after: close)]
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    private struct Times {
        var start: Date
        var end: Date
        var now: Date

        private static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            return calendar
        }()

        func value(for placeholder: Substring) -> String? {
            let parts = placeholder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0]
            let argument = parts.count > 1 ? parts[1] : nil

            let date: Date?
            switch name {
            case "utc", "start": date = start
            case "utcend", "end": date = end
            case "lutc", "now", "timestamp": date = now
            default: date = nil
            }
            if let date {
                guard let argument else { return String(Self.seconds(date)) }
                return Self.format(date, argument)
            }

            let amount: Int64
            switch name {
            case "duration": amount = Self.seconds(end) - Self.seconds(start)
            case "offset": amount = Self.seconds(now) - Self.seconds(start)
            default:
                guard argument == nil, name.count == 1, let part = Self.part(name.first!, of: start) else { return nil }
                return part
            }
            guard let argument else { return String(amount) }
            guard let divisor = Int64(argument), divisor > 0 else { return nil }
            return String(amount / divisor)
        }

        private static func seconds(_ date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970.rounded(.down))
        }

        /// Replaces the letters Y m d H M S in `pattern` with parts of `date`.
        private static func format(_ date: Date, _ pattern: Substring) -> String {
            pattern.map { part($0, of: date) ?? String($0) }.joined()
        }

        private static func part(_ letter: Character, of date: Date) -> String? {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            func twoDigits(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
            switch letter {
            case "Y": return String(format: "%04d", components.year ?? 0)
            case "m": return twoDigits(components.month)
            case "d": return twoDigits(components.day)
            case "H": return twoDigits(components.hour)
            case "M": return twoDigits(components.minute)
            case "S": return twoDigits(components.second)
            default: return nil
            }
        }
    }
}

extension Channel {
    /// Whether the provider keeps an archive of this channel that the app knows how to play.
    public var canCatchUp: Bool {
        guard let catchupDays, catchupDays > 0 else { return false }
        if xtreamStreamID != nil { return true }
        guard streamURL != nil, let mode = catchupMode.flatMap(Catchup.Mode.init(_:)) else { return false }
        return !mode.needsSource || catchupSource != nil
    }

    /// Whether `programme` can be watched from its start: it has started, and started recently
    /// enough to still be in the archive.
    public func isCatchupPlayable(_ programme: Programme, now: Date = .now) -> Bool {
        isCatchupPlayable(startingAt: programme.start, now: now)
    }

    /// Whether a programme starting at `start` can be watched from its start.
    public func isCatchupPlayable(startingAt start: Date, now: Date = .now) -> Bool {
        guard canCatchUp, let catchupDays else { return false }
        return start <= now && start >= now.addingTimeInterval(-Double(catchupDays) * 86_400)
    }
}
