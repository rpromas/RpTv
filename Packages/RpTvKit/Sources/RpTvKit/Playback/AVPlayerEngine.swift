// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import Observation

/// AVPlayer-backed engine for HLS and progressive MP4.
@MainActor
@Observable
public final class AVPlayerEngine: PlayerEngine {
    public let kind = PlayerEngineKind.native
    public let player = AVPlayer()
    public private(set) var state = PlaybackState.idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refreshState() }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { @Sendable [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    isolated deinit {
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
        player.replaceCurrentItem(with: playerItem)
        if let start = item.startPosition, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        player.play()
    }

    public func play() { player.play() }

    public func pause() { player.pause() }

    public func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservations = []
        state = .idle
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
