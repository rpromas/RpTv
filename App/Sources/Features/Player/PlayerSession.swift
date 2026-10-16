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
    /// The channels of `list`, kept up to date and narrowed by `search`.
    func observeChannels(sourceID: Int64, list: ChannelList, search: String = "",
                         includingLocked: Bool) -> AsyncThrowingStream<[Channel], Error> {
        switch list {
        case .all: observeChannels(sourceID: sourceID, categoryID: nil, search: search, includingLocked: includingLocked)
        case .category(let id): observeChannels(sourceID: sourceID, categoryID: id, search: search, includingLocked: includingLocked)
        case .favorites: observeFavoriteChannels(sourceID: sourceID, includingLocked: includingLocked)
        case .recent: observeRecentChannels(sourceID: sourceID, includingLocked: includingLocked)
        }
    }
}

/// One stay in the player: what's playing, and the channels or episodes around it.
@MainActor
@Observable
final class PlayerSession: Identifiable {
    let coordinator: PlaybackCoordinator
    let context: ChannelListContext?
    /// The channel playing, or `nil` for a movie or an episode.
    private(set) var channel: Channel?
    /// The movie playing, or `nil` for a channel or an episode.
    let movie: Movie?
    /// The episode playing, or `nil` for a channel or a movie. Changes when the next one starts.
    private(set) var episode: Episode?
    /// The series of ``episode``.
    let series: Series?
    /// Every episode of ``series``, for Up Next. Empty until loaded.
    private(set) var episodes = SeriesEpisodes()
    /// Set when the user turns down Up Next for the episode playing.
    var isUpNextDismissed = false
    /// The programme playing from the archive, or `nil` when the channel is playing live.
    private(set) var catchupProgramme: Programme?
    private(set) var zapList: ZapList
    /// Goes up on every zap and every move to the next episode, so the screen can show the banner.
    private(set) var zapCount = 0
    var errorMessage: String?

    @ObservationIgnored private let source: Source
    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored private let resolver: PlaybackResolver
    @ObservationIgnored private let firstItem: PlaybackItem
    /// Whether locked categories were open when the player opened, so zapping can reach their channels.
    @ObservationIgnored private let includesLocked: Bool
    @ObservationIgnored private var recordTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    /// How long something plays before it's added to recents, so zapping doesn't fill the list.
    private static let watchedAfter = Duration.seconds(5)
    /// How often the position of a movie or episode is saved while it plays.
    private static let progressInterval = Duration.seconds(10)

    init(channel: Channel, source: Source, context: ChannelListContext?, catchup: Programme? = nil,
         includesLocked: Bool, database: AppDatabase, resolver: PlaybackResolver) throws {
        self.firstItem = try catchup.map { try resolver.catchupItem(for: channel, programme: $0, in: source) }
            ?? resolver.item(for: channel, in: source)
        self.channel = channel
        self.movie = nil
        self.series = nil
        self.catchupProgramme = catchup
        self.source = source
        self.context = context
        self.includesLocked = includesLocked
        self.database = database
        self.resolver = resolver
        self.zapList = ZapList(channels: [channel], currentKey: channel.stableKey)
        self.coordinator = Self.makeCoordinator()
    }

    /// Plays a movie from `startPosition` seconds in. There's nothing to zap to.
    init(movie: Movie, source: Source, startPosition: TimeInterval? = nil, database: AppDatabase, resolver: PlaybackResolver) throws {
        self.firstItem = try resolver.item(for: movie, in: source, startPosition: startPosition)
        self.channel = nil
        self.movie = movie
        self.series = nil
        self.source = source
        self.context = nil
        self.includesLocked = false
        self.database = database
        self.resolver = resolver
        self.zapList = ZapList(channels: [], currentKey: movie.stableKey)
        self.coordinator = Self.makeCoordinator()
    }

    /// Plays an episode from `startPosition` seconds in. Near its end, the next one is offered.
    init(episode: Episode, of series: Series, source: Source, startPosition: TimeInterval? = nil,
         database: AppDatabase, resolver: PlaybackResolver) throws {
        self.firstItem = try resolver.item(for: episode, of: series, in: source, startPosition: startPosition)
        self.channel = nil
        self.movie = nil
        self.episode = episode
        self.series = series
        self.source = source
        self.context = nil
        self.includesLocked = false
        self.database = database
        self.resolver = resolver
        self.zapList = ZapList(channels: [], currentKey: episode.stableKey)
        self.coordinator = Self.makeCoordinator()
    }

    /// Whether what's playing has an end (a movie or an episode), rather than being a channel.
    var isOnDemand: Bool { movie != nil || episode != nil }

    private static func makeCoordinator() -> PlaybackCoordinator {
        PlaybackCoordinator { kind in
            switch kind {
            case .native: AVPlayerEngine()
            case .ffmpeg: FFmpegPlayerEngine()
            case .bridge: BridgedPlayerEngine()
            }
        }
    }

    /// Starts playing, unless it already is.
    func start() {
        guard coordinator.item == nil else { return }
        coordinator.play(firstItem)
        recordWhenWatched()
        saveProgressPeriodically()
    }

    func stop() {
        recordTask?.cancel()
        progressTask?.cancel()
        saveProgress()
        coordinator.stop()
    }

    /// Plays the channel `offset` places away in the list.
    func zap(by offset: Int) {
        if let next = zapList.neighbor(offset) { zap(to: next) }
    }

    /// Plays `channel` live. Picking the channel that's playing from the archive goes back to live.
    func zap(to channel: Channel) {
        guard !isOnDemand, channel.stableKey != self.channel?.stableKey || catchupProgramme != nil else { return }
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

    /// What the recent list notes: the channel or movie, or the series of an episode.
    private var recentKey: ItemKey? { channel?.itemKey ?? movie?.itemKey ?? episode?.seriesItemKey }

    /// Adds the channel, movie or series to the recent list once it has played for a few seconds without failing.
    private func recordWhenWatched() {
        recordTask?.cancel()
        guard let key = recentKey else { return }
        recordTask = Task { [weak self] in
            try? await Task.sleep(for: Self.watchedAfter)
            guard let self, !Task.isCancelled, recentKey == key, !coordinator.state.isFailed else { return }
            try? await database.recordPlay(key)
        }
    }

    // MARK: - Watch progress

    /// The movie or episode playing, whose progress is saved.
    private var progressKey: ItemKey? { movie?.itemKey ?? episode?.itemKey }

    /// Saves the playback position of the movie or episode. Call on pause and when leaving; it also runs
    /// periodically while playing.
    func saveProgress() {
        guard let key = progressKey, let engine = coordinator.engine, coordinator.item?.id == key.stableKey,
              engine.currentTime > 0, !coordinator.state.isFailed else { return }
        let position = engine.currentTime
        let duration = engine.duration ?? 0
        let database = database
        Task { try? await database.saveProgress(key, position: position, duration: duration) }
    }

    private func saveProgressPeriodically() {
        progressTask?.cancel()
        guard progressKey != nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                guard let self, !Task.isCancelled else { return }
                if coordinator.state == .playing { saveProgress() }
            }
        }
    }

    // MARK: - Episodes

    /// The episode after the one playing, which Up Next offers.
    var nextEpisode: Episode? {
        episode.flatMap { episodes.episode(after: $0) }
    }

    /// Loads the series' episodes for Up Next. Runs while the player is on screen.
    func observeEpisodes() async {
        guard let series else { return }
        do {
            for try await episodes in database.observeEpisodes(sourceID: series.sourceID, seriesKey: series.stableKey) {
                self.episodes = episodes
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves on to the next episode, resuming it if started before, and marks the current one watched.
    func playNextEpisode() {
        guard let next = nextEpisode, let series, let current = episode, let engine = coordinator.engine else { return }
        let position = engine.currentTime, duration = engine.duration ?? 0
        let database = database
        Task {
            try? await database.saveProgress(current.itemKey, position: position, duration: duration)
            try? await database.setWatched(current.itemKey, true)
            let resume = try? await database.progress(for: next.itemKey)?.resumePosition
            guard episode == current else { return }
            do {
                let item = try resolver.item(for: next, of: series, in: source, startPosition: resume)
                episode = next
                isUpNextDismissed = false
                zapList = ZapList(channels: [], currentKey: next.stableKey)
                coordinator.play(item)
                zapCount += 1
                recordWhenWatched()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Keeps ``zapList`` in step with the catalog. Runs while the player is on screen.
    func observeChannels() async {
        guard let context else { return }
        do {
            for try await channels in database.observeChannels(sourceID: context.sourceID, list: context.list,
                                                               includingLocked: includesLocked) {
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
