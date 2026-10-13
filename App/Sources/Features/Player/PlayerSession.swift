// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import RpTvKit

/// The channel list the user played from, so the player can zap through it.
struct ChannelListContext: Hashable {
    var sourceID: Int64
    /// `nil` for All Channels.
    var categoryID: Int64?
    var title: String
}

/// One stay in the player: what's playing, and the channels around it.
@MainActor
@Observable
final class PlayerSession: Identifiable {
    let coordinator: PlaybackCoordinator
    let context: ChannelListContext?
    private(set) var channel: Channel
    private(set) var zapList: ZapList
    /// Goes up on every zap, so the screen can show the channel banner.
    private(set) var zapCount = 0
    var errorMessage: String?

    @ObservationIgnored private let source: Source
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let firstItem: PlaybackItem

    init(channel: Channel, source: Source, context: ChannelListContext?, database: AppDatabase,
         resolver: PlaybackResolver) throws {
        self.firstItem = try resolver.item(for: channel, in: source)
        self.channel = channel
        self.source = source
        self.context = context
        self.database = database
        self.resolver = resolver
        self.zapList = ZapList(channels: [channel], currentKey: channel.stableKey)
        self.coordinator = PlaybackCoordinator { kind in
            switch kind {
            case .native: AVPlayerEngine()
            case .vlc: VLCPlayerEngine()
            case .bridge: BridgedPlayerEngine()
            }
        }
    }

    /// Starts playing, unless it already is.
    func start() {
        if coordinator.item == nil { coordinator.play(firstItem) }
    }

    func stop() {
        coordinator.stop()
    }

    /// Plays the channel `offset` places away in the list.
    func zap(by offset: Int) {
        if let next = zapList.neighbor(offset) { zap(to: next) }
    }

    func zap(to channel: Channel) {
        guard channel.stableKey != self.channel.stableKey else { return }
        do {
            let item = try resolver.item(for: channel, in: source)
            self.channel = channel
            zapList.select(channel.stableKey)
            coordinator.play(item)
            zapCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps ``zapList`` in step with the catalog. Runs while the player is on screen.
    func observeChannels() async {
        guard let context else { return }
        do {
            for try await channels in database.observeChannels(sourceID: context.sourceID, categoryID: context.categoryID) {
                zapList.replaceChannels(channels)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
