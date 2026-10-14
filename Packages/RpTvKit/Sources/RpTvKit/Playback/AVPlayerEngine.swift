// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import AVKit
import Observation

/// AVPlayer-backed engine for HLS and progressive MP4.
@MainActor
@Observable
public final class AVPlayerEngine: PlayerEngine {
    public let kind = PlayerEngineKind.native
    public let player = AVPlayer()
    /// The layer to show video in. The engine owns it so Picture in Picture can outlive the player screen.
    public let playerLayer: AVPlayerLayer
    public private(set) var state = PlaybackState.idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var supportsPictureInPicture = false
    public private(set) var isPictureInPictureActive = false
    /// True while AirPlay plays the video on another screen, which leaves ``playerLayer`` empty.
    public private(set) var isExternalPlaybackActive = false

    public var videoGravity = VideoGravity.fit {
        didSet { playerLayer.videoGravity = Self.layerGravity(videoGravity) }
    }

    public var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    @ObservationIgnored private let pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var subtitleGroup: AVMediaSelectionGroup?
    /// The item being played, for the track languages it asks for.
    @ObservationIgnored private var item: PlaybackItem?
    @ObservationIgnored private var tracksTask: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // Send video, not just sound, when the user picks an AirPlay screen.
        player.allowsExternalPlayback = true
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        pictureInPicture = AVPictureInPictureController.isPictureInPictureSupported()
            ? AVPictureInPictureController(playerLayer: playerLayer) : nil
        #if os(iOS)
        pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        if let pictureInPicture {
            observations.append(pictureInPicture.observe(\.isPictureInPicturePossible, options: .initial) { @Sendable [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor in self?.supportsPictureInPicture = possible }
            })
            observations.append(pictureInPicture.observe(\.isPictureInPictureActive) { @Sendable [weak self] controller, _ in
                let active = controller.isPictureInPictureActive
                Task { @MainActor in self?.isPictureInPictureActive = active }
            })
        }
        observations.append(player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refreshState() }
        })
        observations.append(player.observe(\.isExternalPlaybackActive) { @Sendable [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.isExternalPlaybackActive = active }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { @Sendable [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    isolated deinit {
        tracksTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    public func load(_ item: PlaybackItem) {
        var options: [String: Any] = [:]
        if !item.headers.isEmpty {
            if let userAgent = item.headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = userAgent }
            // Not a public constant, but the documented-by-convention way to send extra headers (e.g. Referer).
            options["AVURLAssetHTTPHeaderFieldsKey"] = item.headers
        }
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: item.url, options: options))
        if let buffer = item.liveBuffer { playerItem.preferredForwardBufferDuration = buffer }
        self.item = item
        #if os(tvOS) || os(visionOS)
        // Shown by the system player UI.
        playerItem.externalMetadata = [Self.metadata(.commonIdentifierTitle, item.title)]
            + (item.subtitle.map { [Self.metadata(.iTunesMetadataTrackSubTitle, $0)] } ?? [])
        #endif

        itemObservations = [
            playerItem.observe(\.status) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            playerItem.observe(\.duration) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.refreshDuration() }
            },
        ]

        state = .loading
        currentTime = 0
        duration = nil
        clearTracks()
        tracksTask = Task { [weak self] in await self?.loadTracks(of: playerItem) }
        player.replaceCurrentItem(with: playerItem)
        if let start = item.startPosition, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        player.play()
    }

    // Starts at `defaultRate`, which follows `rate`.
    public func play() { player.play() }

    public func pause() { player.pause() }

    public func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func stop() {
        pictureInPicture?.stopPictureInPicture()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservations = []
        clearTracks()
        state = .idle
    }

    public func select(track: MediaTrack) {
        let group = track.kind == .audio ? audioGroup : subtitleGroup
        guard let group, let item = player.currentItem,
              let option = group.options.first(where: { Self.trackID($0, in: group) == track.id }) else { return }
        item.select(option, in: group)
        refreshTracks()
    }

    public func disableSubtitles() {
        guard let subtitleGroup, let item = player.currentItem else { return }
        item.select(nil, in: subtitleGroup)
        refreshTracks()
    }

    public func startPictureInPicture() {
        pictureInPicture?.startPictureInPicture()
    }

    // MARK: - Tracks

    private func loadTracks(of item: AVPlayerItem) async {
        let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, player.currentItem === item else { return }
        audioGroup = audio
        subtitleGroup = legible
        selectPreferredLanguages(in: item)
        refreshTracks()
    }

    /// Picks the audio and subtitle tracks in the languages the user prefers, when the stream has them.
    private func selectPreferredLanguages(in playerItem: AVPlayerItem) {
        func option(in group: AVMediaSelectionGroup?, _ language: String?) -> AVMediaSelectionOption? {
            guard let group, let language else { return nil }
            return AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles])
                .first { TrackLanguage.matches($0.extendedLanguageTag ?? $0.locale?.identifier, language) }
        }
        if let audioGroup, let audio = option(in: audioGroup, item?.audioLanguage) {
            playerItem.select(audio, in: audioGroup)
        }
        if let subtitleGroup, let subtitle = option(in: subtitleGroup, item?.subtitleLanguage) {
            playerItem.select(subtitle, in: subtitleGroup)
        }
    }

    private func refreshTracks() {
        guard let item = player.currentItem else { return clearTracks() }
        let selection = item.currentMediaSelection
        audioTracks = audioGroup.map { group in
            group.options.map { option in
                MediaTrack(id: Self.trackID(option, in: group), kind: .audio, name: option.displayName,
                           isSelected: selection.selectedMediaOption(in: group) == option)
            }
        } ?? []
        subtitleTracks = subtitleGroup.map { group in
            // Forced subtitles show automatically with their audio track; they aren't a choice.
            AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles])
                .map { option in
                    MediaTrack(id: Self.trackID(option, in: group), kind: .subtitle, name: option.displayName,
                               isSelected: selection.selectedMediaOption(in: group) == option)
                }
        } ?? []
    }

    private func clearTracks() {
        tracksTask?.cancel()
        audioGroup = nil
        subtitleGroup = nil
        audioTracks = []
        subtitleTracks = []
    }

    private static func trackID(_ option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) -> String {
        String(group.options.firstIndex(of: option) ?? -1)
    }

    private static func layerGravity(_ gravity: VideoGravity) -> AVLayerVideoGravity {
        switch gravity {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }

    private func refreshState() {
        guard let item = player.currentItem else {
            if state != .idle, !isFailed { state = .idle }
            return
        }
        if item.status == .failed {
            state = .failed(item.error?.localizedDescription ?? "The stream couldn't be played.")
            return
        }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .paused: state = item.status == .readyToPlay ? .paused : .loading
        case .waitingToPlayAtSpecifiedRate: state = item.status == .readyToPlay ? .buffering : .loading
        @unknown default: break
        }
    }

    private func refreshDuration() {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else {
            duration = nil
            return
        }
        duration = seconds
    }

    #if os(tvOS) || os(visionOS)
    private static func metadata(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
    #endif

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }
}
