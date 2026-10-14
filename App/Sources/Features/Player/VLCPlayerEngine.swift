// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Observation
import RpTvKit
import SwiftUI
import VLCKit

/// VLCKit-backed engine for what AVPlayer can't play: raw MPEG-TS, MKV, RTMP and uncommon codecs.
///
/// Lives in the app target rather than RpTvKit so the core package builds and tests without the VLCKit binary.
@MainActor
@Observable
final class VLCPlayerEngine: PlayerEngine {
    let kind = PlayerEngineKind.vlc
    private(set) var state = PlaybackState.idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    /// Becomes true once VLC hands over its Picture in Picture controller, after the first frame.
    private(set) var supportsPictureInPicture = false
    private(set) var isPictureInPictureActive = false

    var videoGravity = VideoGravity.fit {
        didSet { applyVideoGravity() }
    }

    var rate: Float = 1 {
        didSet { player.rate = rate }
    }

    /// The view VLC draws video into. Shown by ``VLCVideoSurface``.
    @ObservationIgnored let videoView = UIView()
    @ObservationIgnored private let player = VLCMediaPlayer()
    @ObservationIgnored private var events: Events?
    @ObservationIgnored private var drawable: Drawable?
    @ObservationIgnored private var pictureInPicture: (any VLCPictureInPictureWindowControlling)?
    /// Set from `load` until `stop`, so the events of an explicit stop don't read as a failure.
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isBuffering = false

    init() {
        videoView.backgroundColor = .black
        let drawable = Drawable(view: videoView, player: player) { [weak self] controller in
            self?.pictureInPictureReady(controller)
        }
        player.drawable = drawable
        self.drawable = drawable
        let events = Events { [weak self] event in
            // VLCKit calls its delegate on its own queue.
            Task { @MainActor in self?.handle(event) }
        }
        player.delegate = events
        self.events = events
    }

    isolated deinit {
        player.stop()
    }

    func load(_ item: PlaybackItem) {
        guard let media = VLCMedia(url: item.url) else {
            state = .failed("The stream address isn't valid.")
            return
        }
        // VLC can't send arbitrary headers, only these two.
        if let userAgent = item.headers["User-Agent"] { media.addOption(":http-user-agent=\(userAgent)") }
        if let referrer = item.headers["Referer"] { media.addOption(":http-referrer=\(referrer)") }
        if let start = item.startPosition, start > 0 { media.addOption(":start-time=\(start)") }
        if let buffer = item.liveBuffer { media.addOption(":network-caching=\(Int(buffer * 1000))") }
        // VLC picks these tracks itself when the stream has them.
        if let language = item.audioLanguage { media.addOption(":audio-language=\(language)") }
        if let language = item.subtitleLanguage { media.addOption(":sub-language=\(language)") }

        isActive = true
        hasStarted = false
        isBuffering = false
        state = .loading
        currentTime = 0
        duration = nil
        audioTracks = []
        subtitleTracks = []
        player.media = media
        player.play()
        player.rate = rate
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        player.time = VLCTime(number: NSNumber(value: Int64(time * 1000)))
    }

    func stop() {
        isActive = false
        pictureInPicture?.stopPictureInPicture()
        player.stop()
        audioTracks = []
        subtitleTracks = []
        state = .idle
    }

    func select(track: MediaTrack) {
        let tracks = track.kind == .audio ? player.audioTracks : player.textTracks
        tracks.first { $0.trackId == track.id }?.isSelectedExclusively = true
        refreshTracks()
    }

    func disableSubtitles() {
        player.deselectAllTextTracks()
        refreshTracks()
    }

    func startPictureInPicture() {
        pictureInPicture?.startPictureInPicture()
    }

    private func pictureInPictureReady(_ controller: any VLCPictureInPictureWindowControlling) {
        controller.stateChangeEventHandler = { [weak self] isStarted in
            Task { @MainActor in self?.isPictureInPictureActive = isStarted }
        }
        pictureInPicture = controller
        supportsPictureInPicture = true
    }

    private func applyVideoGravity() {
        switch videoGravity {
        case .fit:
            player.videoAspectRatio = nil
            player.videoFitMode = .smaller
        case .fill:
            player.videoAspectRatio = nil
            player.videoFitMode = .larger
        case .stretch:
            // Forcing the view's own aspect ratio makes the picture fill it exactly.
            let size = videoView.bounds.size
            player.videoAspectRatio = size.height > 0 ? "\(Int(size.width)):\(Int(size.height))" : nil
            player.videoFitMode = .smaller
        }
    }

    private func refreshTracks() {
        audioTracks = player.audioTracks.map {
            MediaTrack(id: $0.trackId, kind: .audio, name: $0.trackName, isSelected: $0.isSelected)
        }
        subtitleTracks = player.textTracks.map {
            MediaTrack(id: $0.trackId, kind: .subtitle, name: $0.trackName, isSelected: $0.isSelected)
        }
    }

    private func handle(_ event: Event) {
        guard isActive else { return }
        switch event {
        case .stateChanged:
            refreshState()
        case .buffering(let progress):
            isBuffering = progress < 1
            refreshState()
        case .timeChanged:
            currentTime = (player.time.value?.doubleValue ?? 0) / 1000
        case .lengthChanged(let milliseconds):
            // Live streams report no length, which leaves `duration` nil like AVPlayer does.
            duration = milliseconds > 0 ? Double(milliseconds) / 1000 : nil
        case .tracksChanged:
            refreshTracks()
        }
    }

    /// Reads the player's state rather than trusting the event's, since events can arrive out of order.
    private func refreshState() {
        defer { pictureInPicture?.invalidatePlaybackState() }
        switch player.state {
        case .opening:
            state = .loading
        case .playing:
            hasStarted = true
            state = isBuffering ? .buffering : .playing
        case .paused:
            state = .paused
        case .error:
            state = .failed("The stream couldn't be played.")
        case .stopped:
            // Stopping before ever playing means the stream couldn't be opened. Otherwise it ended.
            if case .failed = state { break }
            state = hasStarted ? .idle : .failed("The stream couldn't be played.")
        case .stopping, .nothingSpecial:
            break
        @unknown default:
            break
        }
    }

    fileprivate enum Event: Sendable {
        case stateChanged
        case buffering(Float)
        case timeChanged
        case lengthChanged(Int64)
        case tracksChanged
    }

    /// Forwards `VLCMediaPlayerDelegate` calls, which can come from any queue.
    private final class Events: NSObject, VLCMediaPlayerDelegate {
        private let send: @Sendable (Event) -> Void

        init(send: @escaping @Sendable (Event) -> Void) {
            self.send = send
        }

        func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) { send(.stateChanged) }
        func mediaPlayerBufferingChanged(_ progress: Float) { send(.buffering(progress)) }
        func mediaPlayerTimeChanged(_ aNotification: Notification) { send(.timeChanged) }
        func mediaPlayerLengthChanged(_ length: Int64) { send(.lengthChanged(length)) }
        func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) { send(.tracksChanged) }
        func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType) { send(.tracksChanged) }
        func mediaPlayerTrackUpdated(_ trackId: String, with trackType: VLCMedia.TrackType) { send(.tracksChanged) }
        func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
            send(.tracksChanged)
        }
    }

    /// What VLC draws into. Taking this instead of a plain view is how VLCKit 4 offers Picture in Picture: it hands
    /// over a controller once video is up, and asks this object to drive playback from the PiP window.
    private final class Drawable: NSObject, VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling,
                                  @unchecked Sendable {
        private let view: UIView
        private weak var player: VLCMediaPlayer?
        private let onReady: @MainActor (any VLCPictureInPictureWindowControlling) -> Void

        init(view: UIView, player: VLCMediaPlayer,
             onReady: @escaping @MainActor (any VLCPictureInPictureWindowControlling) -> Void) {
            self.view = view
            self.player = player
            self.onReady = onReady
        }

        // VLCDrawable. VLC may call these off the main thread.

        func addSubview(_ subview: UIView) {
            Self.onMain {
                subview.frame = self.view.bounds
                subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.view.addSubview(subview)
            }
        }

        func bounds() -> CGRect {
            Self.onMain { view.bounds }
        }

        // VLCPictureInPictureDrawable

        func mediaController() -> any VLCPictureInPictureMediaControlling { self }

        func pictureInPictureReady() -> ((any VLCPictureInPictureWindowControlling)?) -> Void {
            { [onReady] controller in
                guard let controller else { return }
                nonisolated(unsafe) let unsafeController = controller
                Self.onMain { onReady(unsafeController) }
            }
        }

        // VLCPictureInPictureMediaControlling

        func play() { player?.play() }
        func pause() { player?.pause() }

        func seek(by offset: Int64, completion: @escaping () -> Void) {
            guard let player, player.jump(withOffset: Int32(clamping: offset), completion: completion) else {
                return completion()
            }
        }

        func mediaLength() -> Int64 { Int64(player?.media?.length.intValue ?? 0) }
        func mediaTime() -> Int64 { Int64(player?.time.intValue ?? 0) }
        func isMediaSeekable() -> Bool { player?.isSeekable ?? false }
        func isMediaPlaying() -> Bool { player?.isPlaying ?? false }

        private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
            if Thread.isMainThread { return MainActor.assumeIsolated(body) }
            return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
        }
    }
}

/// Hosts the view a ``VLCPlayerEngine`` draws into.
struct VLCVideoSurface: UIViewRepresentable {
    let engine: VLCPlayerEngine

    func makeUIView(context: Context) -> UIView {
        engine.videoView
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
