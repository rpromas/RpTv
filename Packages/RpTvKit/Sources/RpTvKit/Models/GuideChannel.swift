// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A channel listed in a source's XMLTV guide. Playlist channels are matched to these by id or name.
public struct GuideChannel: Codable, Sendable, Hashable, Identifiable {
    public var sourceID: Int64
    /// The XMLTV channel id.
    public var id: String
    public var name: String
    /// Every display name the guide gives, one per line.
    public var names: String
    public var iconURL: String?

    public init(sourceID: Int64, id: String, name: String, names: String, iconURL: String? = nil) {
        self.sourceID = sourceID
        self.id = id
        self.name = name
        self.names = names
        self.iconURL = iconURL
    }
}
