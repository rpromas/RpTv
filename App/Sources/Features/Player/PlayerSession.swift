// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import RpTvKit

/// One of a source's channel lists.
enum ChannelList: Hashable {
    case all
    case category(Int64)
    case favorites
    case recent
}

/// The channel list the user played from, so the player can zap through it.
struct ChannelListContext: Hashable {
    var sourceID: Int64
    var list: ChannelList
    var title: String
}

extension AppDatabase {
    /// The channels of `list`, kept up to date. `search` narrows All Channels and categories.
    func observeChannels(sourceID: Int64, list: ChannelList, search: String = "") -> AsyncThrowingStream<[Channel], Error> {
        switch list {
        case .all: observeChannels(sourceID: sourceID, categoryID: nil, search: search)
        case .category(let id): observeChannels(sourceID: sourceID, categoryID: id, search: search)
        case .favorites: observeFavoriteChannels(sourceID: sourceID)
        case .recent: observeRecentChannels(sourceID: sourceID)
        }
    }
}

/// One stay in the player: what's playing, and the channels around it.
@MainActor
@Observable
final class PlayerSession: Identifiable {
    let coordinator: PlaybackCoordinator
    let context: ChannelListContext?
    /// The channel playing, or nil for a movie.
    private(set) var channel: Channel?
    /// The movie playing, or nil for a channel.
    let movie: Movie?
    /// The programme playing from the archive, or nil when the channel is playing live.
    private(set) var catchupProgramme: Programme?
    private(set) var zapList: ZapList
    /// Goes up on every zap, so the screen can show the channel banner.
    private(set) var zapCount = 0
    var errorMessage: String?

    @ObservationIgnored private let source: Source
    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let firstItem: PlaybackItem
    @ObservationIgnored private var recordTask: Task<Void, Never>?

    /// How long something has to play before it counts as watched, so zapping past channels doesn't fill
    /// the recent list.
    private static let watchedAfter = Duration.seconds(5)

    init(channel: Channel, source: Source, context: ChannelListContext?, catchup: Programme? = nil,
         database: AppDatabase, resolver: PlaybackResolver) throws {
        self.firstItem = try catchup.map { try resolver.catchupItem(for: channel, programme: $0, in: source) }
            ?? resolver.item(for: channel, in: source)
        self.channel = channel
        self.movie = nil
        self.catchupProgramme = catchup
        self.source = source
        self.context = context
        self.database = database
        self.resolver = resolver
        self.zapList = ZapList(channels: [channel], currentKey: channel.stableKey)
        self.coordinator = Self.makeCoordinator()
    }

    /// Plays a movie. There's nothing to zap to.
    init(movie: Movie, source: Source, database: AppDatabase, resolver: PlaybackResolver) throws {
        self.firstItem = try resolver.item(for: movie, in: source)
        self.channel = nil
        self.movie = movie
        self.source = source
        self.context = nil
        self.database = database
        self.resolver = resolver
        self.zapList = ZapList(channels: [], currentKey: movie.stableKey)
        self.coordinator = Self.makeCoordinator()
    }

    private static func makeCoordinator() -> PlaybackCoordinator {
        PlaybackCoordinator { kind in
            switch kind {
            case .native: AVPlayerEngine()
            case .vlc: VLCPlayerEngine()
            case .bridge: BridgedPlayerEngine()
            }
        }
    }

    /// Starts playing, unless it already is.
    func start() {
        guard coordinator.item == nil else { return }
        coordinator.play(firstItem)
        recordWhenWatched()
    }

    func stop() {
        recordTask?.cancel()
        coordinator.stop()
    }

    /// Plays the channel `offset` places away in the list.
    func zap(by offset: Int) {
        if let next = zapList.neighbor(offset) { zap(to: next) }
    }

    /// Plays `channel` live. Picking the channel that's playing from the archive goes back to live.
    func zap(to channel: Channel) {
        guard movie == nil, channel.stableKey != self.channel?.stableKey || catchupProgramme != nil else { return }
        do {
            let item = try resolver.item(for: channel, in: source)
            self.channel = channel
            catchupProgramme = nil
            zapList.select(channel.stableKey)
            coordinator.play(item)
            zapCount += 1
            recordWhenWatched()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Leaves the archive for the live stream of the same channel.
    func goLive() {
        if let channel { zap(to: channel) }
    }

    /// Adds the channel or movie to the recent list once it has played for a few seconds without failing.
    private func recordWhenWatched() {
        recordTask?.cancel()
        guard let key = channel?.itemKey ?? movie?.itemKey else { return }
        recordTask = Task { [weak self] in
            try? await Task.sleep(for: Self.watchedAfter)
            guard let self, !Task.isCancelled, (channel?.itemKey ?? movie?.itemKey) == key, !coordinator.state.isFailed
            else { return }
            try? await database.recordPlay(key)
        }
    }

    /// Keeps ``zapList`` in step with the catalog. Runs while the player is on screen.
    func observeChannels() async {
        guard let context else { return }
        do {
            for try await channels in database.observeChannels(sourceID: context.sourceID, list: context.list) {
                zapList.replaceChannels(channels)
                // Watching reorders the recent list. Zap through it as it was when the player opened.
                if context.list == .recent { break }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
