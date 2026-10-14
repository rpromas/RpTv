// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Plays any stream FFmpeg can read: it demuxes and decodes with FFmpeg (video in hardware through VideoToolbox
/// where it can) and renders through AVFoundation's sample buffer renderers, kept in sync by an
/// `AVSampleBufferRenderSynchronizer`. Put ``displayLayer`` on screen; Picture in Picture can take it too.
///
/// The player buffers by itself: it starts the clock once enough of the stream is read, and stops it when the
/// stream runs dry. All methods can be called from any thread; events arrive on a private queue, in order.
public final class StreamPlayer: @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "dev.romas.RpTv.StreamPlayer", qos: .userInitiated)
    /// Whether the user wants playback running, for Picture in Picture to read from the main thread.
    private let playing = Atomic<Bool>(true)
    /// A live stream's first timestamp: its ``currentTime`` counts from there.
    private let timeOffset = Mutex<Double>(0)

    // Confined to `queue`.
    private var pipeline: PlaybackPipeline?
    private var info: PlaybackPipeline.Info?
    private var timer: DispatchSourceTimer?
    private var onEvent: (@Sendable (PlayerEvent) -> Void)?
    private var status = PlayerStatus.loading
    private var wantsToPlay = true
    private var rate: Float = 1
    /// Live streams follow their buffer level instead of the chosen speed.
    private var liveRate: LiveRateController?
    private var clockStarted = false
    private var seekRequests = 0
    private var waitStarted = Date()
    private var reportedTime: Double?
    private var reportedCueID: Int?
    private var reportedVideoSize = CGSize.zero

    /// Seconds of stream read ahead before the clock first starts, when the source doesn't say.
    private static let defaultStartBuffer = 1.0
    /// A live stream with no buffer chosen starts on this much, then plays a little slower until it has
    /// ``defaultStartBuffer`` (``LiveRateController``), so changing channels doesn't wait for the whole cushion.
    private static let liveStartBuffer = 0.5
    /// Seconds read ahead before playing again after a stall.
    private static let rebuffer = 2.0

    public init() {
        // The player decides when there's enough to play; the synchronizer shouldn't wait on its own.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        displayLayer.videoGravity = .resizeAspect
    }

    deinit {
        pipeline?.cancel()
        timer?.cancel()
    }

    /// The playback position in seconds. Finite media count from their start, live streams from where playing
    /// began.
    public var currentTime: TimeInterval {
        max(0, CMTimebaseGetTime(synchronizer.timebase).seconds - timeOffset.withLock { $0 })
    }

    /// Whether playback is paused by the user (not merely waiting for data).
    public var isPaused: Bool { !playing.load(ordering: .relaxed) }

    /// Starts playing `source`, replacing whatever was playing.
    public func start(_ source: PlayerSource, onEvent: @escaping @Sendable (PlayerEvent) -> Void) {
        playing.store(true, ordering: .relaxed)
        queue.async { [self] in
            if pipeline != nil { stopNow() }
            info = nil
            wantsToPlay = true
            clockStarted = false
            seekRequests = 0
            reportedTime = nil
            reportedCueID = nil
            reportedVideoSize = .zero
            timeOffset.withLock { $0 = 0 }
            liveRate = source.isLive ? LiveRateController(target: source.buffer ?? Self.defaultStartBuffer) : nil
            self.onEvent = onEvent
            let pipeline = PlaybackPipeline(source: source, videoRenderer: displayLayer.sampleBufferRenderer,
                                    audioRenderer: audioRenderer, timebase: synchronizer.timebase) { [weak self] message in
                guard let player = self else { return }
                player.queue.async { player.handle(message) }
            }
            self.pipeline = pipeline
            set(.loading)
            waitStarted = Date()
            pipeline.start()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func play() {
        playing.store(true, ordering: .relaxed)
        queue.async { [self] in
            wantsToPlay = true
            switch status {
            case .paused:
                synchronizer.rate = playbackRate
                set(.playing)
            case .ended:
                seekNow(to: 0)
            default:
                break
            }
        }
    }

    public func pause() {
        playing.store(false, ordering: .relaxed)
        queue.async { [self] in
            wantsToPlay = false
            if status == .playing {
                synchronizer.rate = 0
                set(.paused)
            }
        }
    }

    /// The playback speed, 1 being normal. Kept while paused.
    public func setRate(_ rate: Float) {
        queue.async { [self] in
            self.rate = rate
            if status == .playing { synchronizer.rate = playbackRate }
        }
    }

    /// Jumps to `time` seconds into finite media. Ignored for live streams.
    public func seek(to time: TimeInterval) {
        queue.async { [self] in seekNow(to: time) }
    }

    public func selectAudio(_ track: PlayerTrack) {
        queue.async { [self] in
            pipeline?.selectAudio(track.id)
            updateTracks { $0.kind == .audio ? $0.id == track.id : $0.isSelected }
        }
    }

    /// Shows the subtitle track, or turns subtitles off with `nil`.
    public func selectSubtitle(_ track: PlayerTrack?) {
        queue.async { [self] in
            pipeline?.state.withLock { $0.selectedSubtitle = track?.id }
            updateTracks { $0.kind == .subtitle ? $0.id == track?.id : $0.isSelected }
            reportedCueID = nil
            report()
        }
    }

    /// Stops decoding video, for when nobody can see it (in the background without Picture in Picture).
    /// Sound carries on. Turned back on, the picture returns at the next keyframe.
    public func setVideoEnabled(_ enabled: Bool) {
        queue.async { [self] in
            pipeline?.state.withLock { $0.videoEnabled = enabled }
        }
    }

    /// Stops playing and releases the stream.
    public func stop() {
        queue.async { [self] in stopNow() }
    }

    private func stopNow() {
        timer?.cancel()
        timer = nil
        pipeline?.cancel()
        pipeline = nil
        onEvent = nil
        synchronizer.rate = 0
        audioRenderer.flush()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: - Control

    private func handle(_ message: PlaybackPipeline.Message) {
        guard pipeline != nil else { return }
        switch message {
        case .opened(let info):
            self.info = info
            emit(.duration(info.duration))
            emit(.tracks(info.tracks))
        case .foundTrack(let track):
            guard var info, !info.tracks.contains(where: { $0.id == track.id }) else { return }
            info.tracks.append(track)
            self.info = info
            emit(.tracks(info.tracks))
        case .failed(let message):
            timer?.cancel()
            synchronizer.rate = 0
            set(.failed(message))
        }
    }

    private func seekNow(to time: TimeInterval) {
        guard let pipeline, let info, info.isSeekable, let duration = info.duration else { return }
        let target = min(max(0, time), max(0, duration - 1))
        seekRequests += 1
        pipeline.requestSeek(to: target, id: seekRequests)
        // Moving the clock now keeps the position from jumping back while the seek runs.
        synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90_000))
        clockStarted = false
        waitStarted = Date()
        set(.buffering)
        report()
    }

    /// Runs every 50 ms: starts and stops the clock as the buffer fills and drains, and reports progress.
    private func tick() {
        guard let pipeline, info != nil else { return }
        let state = pipeline.state.withLock { $0 }
        let clock = CMTimebaseGetTime(synchronizer.timebase).seconds
        let hasVideo = info?.hasVideo == true && state.videoEnabled && !state.videoUnavailable
        let hasAudio = state.selectedAudio >= 0 && !state.unavailableAudio.contains(state.selectedAudio)

        switch status {
        case .loading, .buffering:
            guard state.appliedSeeks == seekRequests, let origin = state.origin else { break }
            let waited = Date().timeIntervalSince(waitStarted)
            let from = clockStarted ? clock : origin
            let needed = clockStarted ? max(Self.rebuffer, startBuffer) : startBuffer
            var ready = state.reachedEnd
            if !ready, let buffered = pipeline.bufferedUntil(lenient: waited > 3) {
                ready = buffered >= from + needed
            }
            // Show a picture before starting, unless the video can't be decoded.
            if ready, !state.reachedEnd, hasVideo, state.firstVideoSerial != state.serial, waited < 5 { ready = false }
            if ready { resume(from: origin) }
        case .playing:
            if !state.reachedEnd, let buffered = pipeline.bufferedUntil(lenient: true), buffered < clock + 0.1 {
                synchronizer.rate = 0
                liveRate?.reset()
                waitStarted = Date()
                set(.buffering)
            } else if !state.reachedEnd, liveRate != nil, let buffered = pipeline.bufferedUntil(lenient: true) {
                let previous = playbackRate
                _ = liveRate?.update(buffered: buffered - clock, interval: 0.05)
                if playbackRate != previous { synchronizer.rate = playbackRate }
            } else if state.reachedEnd, !hasVideo || state.videoEndedSerial == state.serial,
                      !hasAudio || state.audioEndedSerial == state.serial,
                      clock >= max(state.videoEnd, state.audioEnd) - 0.05 {
                synchronizer.rate = 0
                // A live stream has no end: it stopped.
                if pipeline.source.isLive {
                    set(.failed(PlayerError.sourceStopped.localizedDescription))
                } else if let error = state.readError {
                    set(.failed(error))
                } else {
                    set(.ended)
                }
            }
        case .paused, .ended, .failed:
            break
        }

        if state.videoSize != reportedVideoSize, state.videoSize != .zero {
            reportedVideoSize = state.videoSize
            emit(.videoSize(state.videoSize))
        }
        report()
    }

    /// The chosen speed for finite media; the drift-correcting one for live streams.
    private var playbackRate: Float {
        liveRate?.rate ?? rate
    }

    private var startBuffer: Double {
        guard let source = pipeline?.source else { return Self.defaultStartBuffer }
        return source.buffer ?? (source.isLive ? Self.liveStartBuffer : Self.defaultStartBuffer)
    }

    private func resume(from origin: Double) {
        if !clockStarted {
            clockStarted = true
            if pipeline?.source.isLive == true, seekRequests == 0 { timeOffset.withLock { $0 = origin } }
            synchronizer.setRate(wantsToPlay ? playbackRate : 0, time: CMTime(seconds: origin, preferredTimescale: 90_000))
        } else if wantsToPlay {
            synchronizer.rate = playbackRate
        }
        set(wantsToPlay ? .playing : .paused)
    }

    /// Sends the position twice a second, and the subtitle whenever it changes.
    private func report() {
        let time = currentTime
        if reportedTime == nil || abs(time - reportedTime!) >= 0.5 || status != .playing {
            if reportedTime != time {
                reportedTime = time
                emit(.time(time))
            }
        }
        let cue = pipeline?.cue(at: CMTimebaseGetTime(synchronizer.timebase).seconds)
        if cue?.id != reportedCueID {
            reportedCueID = cue?.id
            emit(.subtitle(cue))
        }
    }

    private func updateTracks(_ isSelected: (PlayerTrack) -> Bool) {
        guard var info else { return }
        for index in info.tracks.indices {
            info.tracks[index].isSelected = isSelected(info.tracks[index])
        }
        self.info = info
        emit(.tracks(info.tracks))
    }

    private func set(_ status: PlayerStatus) {
        guard status != self.status || status == .loading else { return }
        self.status = status
        emit(.status(status))
    }

    private func emit(_ event: PlayerEvent) {
        onEvent?(event)
    }
}
