// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One entry of a TV guide.
public struct Programme: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var sourceID: Int64
    /// The XMLTV channel id the programme belongs to.
    public var epgChannelID: String
    public var start: Date
    /// When it ends. Missing when the guide gives no stop time and no later programme follows on the channel.
    public var stop: Date?
    public var title: String
    public var summary: String?
    public var category: String?
    public var iconURL: String?

    public init(
        id: Int64? = nil,
        sourceID: Int64,
        epgChannelID: String,
        start: Date,
        stop: Date? = nil,
        title: String,
        summary: String? = nil,
        category: String? = nil,
        iconURL: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.epgChannelID = epgChannelID
        self.start = start
        self.stop = stop
        self.title = title
        self.summary = summary
        self.category = category
        self.iconURL = iconURL
    }

    /// How far into the programme `date` is, from 0 to 1, or nil when the end is unknown.
    public func progress(at date: Date) -> Double? {
        guard let stop, stop > start else { return nil }
        return min(max(date.timeIntervalSince(start) / stop.timeIntervalSince(start), 0), 1)
    }
}

/// What's on a channel now and what comes after.
public struct NowNext: Sendable, Hashable {
    public var now: Programme?
    public var next: Programme?

    public init(now: Programme? = nil, next: Programme? = nil) {
        self.now = now
        self.next = next
    }
}
