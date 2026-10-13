// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A live TV channel.
public struct Channel: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var sourceID: Int64
    public var categoryID: Int64?
    /// Identifies the channel across refreshes, so favorites and history survive a resync.
    public var stableKey: String
    public var name: String
    public var number: Int?
    public var logoURL: String?
    /// Direct stream URL (M3U sources). Xtream channels use xtreamStreamID instead,
    /// because their URLs embed the account password, which never goes in the database.
    public var streamURL: String?
    public var xtreamStreamID: Int?
    public var epgChannelID: String?
    /// A guide id the user picked for this channel, replacing the automatic match. Survives resyncs.
    public var epgOverride: String?
    /// The guide channel this channel is matched to. Kept up to date by the database.
    public var guideID: String?
    /// Days of catch-up archive the provider keeps, if any.
    public var catchupDays: Int?
    public var userAgent: String?
    public var referrer: String?
    public var sortIndex: Int

    public init(
        id: Int64? = nil,
        sourceID: Int64,
        categoryID: Int64? = nil,
        stableKey: String,
        name: String,
        number: Int? = nil,
        logoURL: String? = nil,
        streamURL: String? = nil,
        xtreamStreamID: Int? = nil,
        epgChannelID: String? = nil,
        epgOverride: String? = nil,
        guideID: String? = nil,
        catchupDays: Int? = nil,
        userAgent: String? = nil,
        referrer: String? = nil,
        sortIndex: Int
    ) {
        self.id = id
        self.sourceID = sourceID
        self.categoryID = categoryID
        self.stableKey = stableKey
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.xtreamStreamID = xtreamStreamID
        self.epgChannelID = epgChannelID
        self.epgOverride = epgOverride
        self.guideID = guideID
        self.catchupDays = catchupDays
        self.userAgent = userAgent
        self.referrer = referrer
        self.sortIndex = sortIndex
    }
}
