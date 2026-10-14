// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import AVKit
import Observation
import RpTvKit
import StreamBridge
import UIKit

/// RpTv's own player, for what AVPlayer can't play: raw MPEG-TS, MKV, RTMP and uncommon codecs. FFmpeg reads and
/// decodes (``StreamPlayer`` in StreamBridge); AVFoundation's sample buffer layer shows the picture, which
/// Picture in Picture can take over. Subtitles are drawn by ``SubtitleOverlay``.
@MainActor
@Observable
final class FFmpegPlayerEngine: PlayerEngine {
    let kind = PlayerEngineKind.ffmpeg
    private(set) var state = PlaybackState.idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var supportsPictureInPicture = false
    private(set) var isPictureInPictureActive = false
    /// The subtitle to show now.
    private(set) var subtitle: SubtitleCue?
    /// The picture's size in square pixels, to place subtitles on it.
    private(set) var videoSize = CGSize.zero

    var videoGravity = VideoGravity.fit {
        didSet { player.displayLayer.videoGravity = Self.layerGravity(videoGravity) }
    }

    var rate: Float = 1 {
        didSet { player.setRate(rate) }
    }

    @ObservationIgnored let player = StreamPlayer()
    @ObservationIgnored private var tracks: [PlayerTrack] = []
    @ObservationIgnored private var isLive = false
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPictureDelegate: PictureInPictureDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lifecycleTasks: [Task<Void, Never>] = []
    /// Bumped by each `load` and `stop`, so late events from an earlier stream are ignored.
    @ObservationIgnored private var generation = 0

    init() {
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let delegate = PictureInPictureDelegate(engine: self)
            let controller = AVPictureInPictureController(contentSource: .init(
                sampleBufferDisplayLayer: player.displayLayer, playbackDelegate: delegate))
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            observations.append(controller.observe(\.isPictureInPicturePossible, options: .initial) { @Sendable [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor in self?.supportsPictureInPicture = possible }
            })
            observations.append(controller.observe(\.isPictureInPictureActive) { @Sendable [weak self] controller, _ in
                let active = controller.isPictureInPictureActive
                Task { @MainActor in self?.pictureInPictureChanged(active) }
            })
            pictureInPicture = controller
            pictureInPictureDelegate = delegate
        }
        followAppLifecycle()
    }

    isolated deinit {
        for task in lifecycleTasks { task.cancel() }
        player.stop()
    }

    func load(_ item: PlaybackItem) {
        generation += 1
        let generation = generation
        isLive = item.isLive
        state = .loading
        currentTime = item.startPosition ?? 0
        duration = nil
        subtitle = nil
        tracks = []
        refreshTracks()

        let source = PlayerSource(
            url: item.url, headers: item.headers, isLive: item.isLive, startPosition: item.startPosition,
            buffer: item.liveBuffer, prefersAudioLanguage: Self.matcher(item.audioLanguage),
            prefersSubtitleLanguage: Self.matcher(item.subtitleLanguage))
        player.setRate(rate)
        player.start(source) { [weak self] event in
            // In order, which a Task per event wouldn't guarantee.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, generation: generation) }
            }
        }
    }

    /// Matches track language tags against `language`.
    private static func matcher(_ language: String?) -> (@Sendable (String?) -> Bool)? {
        guard let language else { return nil }
        return { tag in TrackLanguage.matches(tag, language) }
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        currentTime = time
        player.seek(to: time)
    }

    func stop() {
        generation += 1
        pictureInPicture?.stopPictureInPicture()
        player.stop()
        tracks = []
        refreshTracks()
        subtitle = nil
        state = .idle
    }

    func select(track: MediaTrack) {
        guard let selected = tracks.first(where: { String($0.id) == track.id }) else { return }
        switch selected.kind {
        case .audio: player.selectAudio(selected)
        case .subtitle: player.selectSubtitle(selected)
        }
    }

    func disableSubtitles() {
        player.selectSubtitle(nil)
    }

    func startPictureInPicture() {
        pictureInPicture?.startPictureInPicture()
    }

    // MARK: - Events

    private func handle(_ event: PlayerEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .status(let status):
            state = switch status {
            case .loading: .loading
            case .buffering: .buffering
            case .playing: .playing
            // Like AVPlayer, a finished movie stays on its last frame, paused.
            case .paused, .ended: .paused
            case .failed(let message): .failed(message)
            }
            pictureInPicture?.invalidatePlaybackState()
        case .duration(let duration):
            self.duration = duration
            pictureInPicture?.invalidatePlaybackState()
        case .tracks(let tracks):
            self.tracks = tracks
            refreshTracks()
        case .time(let time):
            currentTime = time
        case .videoSize(let size):
            videoSize = size
        case .subtitle(let cue):
            subtitle = cue
        }
    }

    private func refreshTracks() {
        let audio = tracks.filter { $0.kind == .audio }
        audioTracks = audio.enumerated().map { index, track in
            MediaTrack(id: String(track.id), kind: .audio, name: Self.name(of: track, number: index + 1, among: audio),
                       isSelected: track.isSelected)
        }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        subtitleTracks = subtitles.enumerated().map { index, track in
            MediaTrack(id: String(track.id), kind: .subtitle, name: Self.name(of: track, number: index + 1, among: subtitles),
                       isSelected: track.isSelected)
        }
    }

    /// "French", or "English (Dolby Digital 5.1)" when another audio track is also in English.
    static func name(of track: PlayerTrack, number: Int, among tracks: [PlayerTrack]) -> String {
        func base(_ track: PlayerTrack, _ number: Int) -> String {
            track.title ?? TrackLanguage.displayName(track.language) ?? "Track \(number)"
        }
        let name = base(track, number)
        let isAmbiguous = tracks.enumerated().contains { $0.element.id != track.id && base($0.element, $0.offset + 1) == name }
        guard track.kind == .audio, isAmbiguous else { return name }
        let channels = switch track.channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(track.channels) ch"
        }
        return "\(name) (\(codecTitle(track.codec)) \(channels))"
    }

    private static func codecTitle(_ codec: String) -> String {
        switch codec {
        case "ac3": "Dolby Digital"
        case "eac3": "Dolby Digital Plus"
        case "truehd": "Dolby TrueHD"
        case "dts": "DTS"
        case "aac", "aac_latm": "AAC"
        default: codec.uppercased()
        }
    }

    private static func layerGravity(_ gravity: VideoGravity) -> AVLayerVideoGravity {
        switch gravity {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }

    // MARK: - Picture in Picture and the background

    fileprivate var pictureInPictureTimeRange: CMTimeRange {
        guard !isLive, let duration else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    private func pictureInPictureChanged(_ active: Bool) {
        isPictureInPictureActive = active
        if active { player.setVideoEnabled(true) }
    }

    /// In the background without Picture in Picture nobody sees the video, so only the sound is decoded.
    private func followAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleTasks = [
            Task { [weak self] in
                for await _ in center.notifications(named: UIApplication.didEnterBackgroundNotification) {
                    // Picture in Picture starts as the app leaves; give it a moment to show up.
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, UIApplication.shared.applicationState == .background,
                          !self.isPictureInPictureActive else { continue }
                    self.player.setVideoEnabled(false)
                }
            },
            Task { [weak self] in
                for await _ in center.notifications(named: UIApplication.willEnterForegroundNotification) {
                    self?.player.setVideoEnabled(true)
                }
            },
        ]
    }
}

/// Lets the Picture in Picture window drive the player. AVKit calls it on the main thread.
@MainActor
private final class PictureInPictureDelegate: NSObject, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private weak var engine: FFmpegPlayerEngine?

    init(engine: FFmpegPlayerEngine) {
        self.engine = engine
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        engine?.pictureInPictureTimeRange ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        engine?.player.isPaused ?? true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        if let engine { engine.seek(to: max(0, engine.currentTime + skipInterval.seconds)) }
        completion()
    }
}
