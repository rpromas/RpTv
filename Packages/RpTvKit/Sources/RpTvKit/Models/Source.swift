// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A playlist provider the user added: an M3U playlist or an Xtream Codes account.
public struct Source: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case m3u
        case xtream
    }

    public var id: Int64?
    public var name: String
    public var kind: Kind
    /// M3U: a remote URL, or a file name inside the app's playlist directory when isLocalFile is set.
    /// Xtream: the server base URL, e.g. `http://example.com:8080`.
    public var location: String
    public var isLocalFile: Bool
    /// Xtream username. The password lives in the keychain under credentialKey.
    public var username: String?
    public var credentialKey: String?
    /// XMLTV guide URL. For M3U it may come from the playlist header. For Xtream it is an optional override:
    /// otherwise the guide URL is built from the credentials at sync time, since it embeds the password.
    public var epgURL: String?
    public var userAgent: String?
    public var referrer: String?
    /// Container used for Xtream live streams (`m3u8` or `ts`).
    public var liveFormat: String?
    /// The Xtream server's time zone identifier (`server_info.timezone`), refreshed on every sync.
    /// Catch-up URLs give the programme's start in this zone.
    public var serverTimeZone: String?
    /// Which player engine plays this source's streams.
    public var enginePreference: EnginePreference
    public var createdAt: Date
    public var lastSyncedAt: Date?
    public var lastSyncError: String?
    public var lastEPGSyncAt: Date?
    public var lastEPGSyncError: String?
    /// When the Xtream account runs out, refreshed on every sync. `nil` for M3U and for accounts that don't expire.
    public var accountExpiresAt: Date?

    public init(
        id: Int64? = nil,
        name: String,
        kind: Kind,
        location: String,
        isLocalFile: Bool = false,
        username: String? = nil,
        credentialKey: String? = nil,
        epgURL: String? = nil,
        userAgent: String? = nil,
        referrer: String? = nil,
        liveFormat: String? = nil,
        serverTimeZone: String? = nil,
        enginePreference: EnginePreference = .automatic,
        createdAt: Date = .now,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        lastEPGSyncAt: Date? = nil,
        lastEPGSyncError: String? = nil,
        accountExpiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.isLocalFile = isLocalFile
        self.username = username
        self.credentialKey = credentialKey
        self.epgURL = epgURL
        self.userAgent = userAgent
        self.referrer = referrer
        self.liveFormat = liveFormat
        self.serverTimeZone = serverTimeZone
        self.enginePreference = enginePreference
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.lastEPGSyncAt = lastEPGSyncAt
        self.lastEPGSyncError = lastEPGSyncError
        self.accountExpiresAt = accountExpiresAt
    }

    /// How many days are left on the account when it has run out or runs out within `warningDays`, else `nil`.
    /// Zero or less means it has already expired.
    public func daysUntilExpiry(now: Date = .now, warningDays: Int = 7, calendar: Calendar = .current) -> Int? {
        guard let accountExpiresAt else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: accountExpiresAt)).day ?? 0
        return days <= warningDays ? days : nil
    }

    /// HTTP headers every request for this source should carry.
    public var httpHeaders: [String: String] {
        var headers: [String: String] = [:]
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        if let referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        return headers
    }
}
