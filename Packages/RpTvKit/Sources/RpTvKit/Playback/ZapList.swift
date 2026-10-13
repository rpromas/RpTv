// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The channels the player can zap through: the list the user played from, and where they are in it.
public struct ZapList: Sendable, Equatable {
    public private(set) var channels: [Channel]
    /// The `stableKey` of the channel playing now.
    public private(set) var currentKey: String

    public init(channels: [Channel], currentKey: String) {
        self.channels = channels
        self.currentKey = currentKey
    }

    public var currentIndex: Int? {
        channels.firstIndex { $0.stableKey == currentKey }
    }

    /// "3 of 42", or `nil` when the current channel isn't in the list.
    public var positionLabel: String? {
        currentIndex.map { "\($0 + 1) of \(channels.count)" }
    }

    /// The channel `offset` places away from the current one, wrapping around at the ends.
    /// `nil` when there's nowhere else to go.
    public func neighbor(_ offset: Int) -> Channel? {
        guard !channels.isEmpty, offset != 0 else { return nil }
        // The current channel dropped out of the list (a resync removed it): start from an end.
        guard let index = currentIndex else { return offset > 0 ? channels.first : channels.last }
        let count = channels.count
        let target = ((index + offset) % count + count) % count
        return target == index ? nil : channels[target]
    }

    public mutating func select(_ stableKey: String) {
        currentKey = stableKey
    }

    /// Takes a fresh copy of the list, keeping the current channel.
    public mutating func replaceChannels(_ channels: [Channel]) {
        self.channels = channels
    }
}
