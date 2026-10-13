// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A group of channels, movies or series. Named to avoid clashing with the Objective-C `Category` type.
public struct MediaCategory: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case live
        case movie
        case series
    }

    public var id: Int64?
    public var sourceID: Int64
    public var kind: Kind
    /// Provider identifier: the Xtream `category_id`, or the M3U `group-title`.
    public var remoteID: String
    public var name: String
    public var sortIndex: Int
    public var isHidden: Bool

    public init(
        id: Int64? = nil,
        sourceID: Int64,
        kind: Kind,
        remoteID: String,
        name: String,
        sortIndex: Int,
        isHidden: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.remoteID = remoteID
        self.name = name
        self.sortIndex = sortIndex
        self.isHidden = isHidden
    }
}
