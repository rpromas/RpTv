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

    /// The view VLC draws video into. Shown by ``VLCVideoSurface``.
    @ObservationIgnored let videoView = UIView()
    @ObservationIgnored private let player = VLCMediaPlayer()
    @ObservationIgnored private var events: Events?
    /// Set from `load` until `stop`, so the events of an explicit stop don't read as a failure.
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isBuffering = false
    @ObservationIgnored private var isLive = false

    init() {
        videoView.backgroundColor = .black
        player.drawable = videoView
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

        isActive = true
        hasStarted = false
        isBuffering = false
        isLive = item.isLive
        state = .loading
        currentTime = 0
        duration = nil
        player.media = media
        player.play()
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        player.time = VLCTime(number: NSNumber(value: Int64(time * 1000)))
    }

    func stop() {
        isActive = false
        player.stop()
        state = .idle
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
            duration = !isLive && milliseconds > 0 ? Double(milliseconds) / 1000 : nil
        }
    }

    /// Reads the player's state rather than trusting the event's, since events can arrive out of order.
    private func refreshState() {
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
