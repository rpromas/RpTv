// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
import RpTvKit
import StreamBridge

private let log = Logger(subsystem: "dev.romas.RpTv", category: "StreamBridge")

/// Plays streams AVPlayer can't open by converting them to HLS with ``HLSBridge``, serving that with
/// ``HLSServer`` on the Wi-Fi address, and playing it in an ``AVPlayerEngine``, which AirPlay can hand to a TV.
@MainActor
@Observable
final class BridgedPlayerEngine: PlayerEngine {
    let kind = PlayerEngineKind.bridge
    /// Plays the bridge's output once enough of it is ready.
    let player = AVPlayerEngine()

    /// Overrides the player's state while the bridge gets ready, or after it fails.
    private var bridgeState: PlaybackState?
    /// How many times AVPlayer has been restarted on the bridge's playlist after an error.
    private var recoveries = 0

    @ObservationIgnored private var bridge: HLSBridge?
    @ObservationIgnored private var server: HLSServer?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    /// What AVPlayer is playing: the bridge's playlist on the local server.
    @ObservationIgnored private var localItem: PlaybackItem?

    private static let maxRecoveries = 3

    var state: PlaybackState {
        if let bridgeState { return bridgeState }
        // AVPlayer gives up when a live playlist stalls briefly. While the bridge runs, report buffering and
        // restart it.
        if player.state.isFailed, localItem != nil, recoveries < Self.maxRecoveries { return .buffering }
        return player.state
    }
    var currentTime: TimeInterval { player.currentTime }
    var duration: TimeInterval? { player.duration }
    var audioTracks: [MediaTrack] { player.audioTracks }
    var subtitleTracks: [MediaTrack] { player.subtitleTracks }
    var supportsPictureInPicture: Bool { player.supportsPictureInPicture }
    var isPictureInPictureActive: Bool { player.isPictureInPictureActive }

    var videoGravity: VideoGravity {
        get { player.videoGravity }
        set { player.videoGravity = newValue }
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    func load(_ item: PlaybackItem) {
        stop()
        bridgeState = .loading
        let directory = URL.temporaryDirectory.appending(component: "StreamBridge/\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            bridgeState = .failed(error.localizedDescription)
            return
        }
        let bridge = HLSBridge(source: BridgeSource(url: item.url, headers: item.headers, isLive: item.isLive),
                               directory: directory)
        let server = HLSServer(directory: directory)
        self.bridge = bridge
        self.server = server

        startTask = Task { [weak self] in
            do {
                let port = try await server.start()
                guard let self, self.bridge === bridge else { return }
                bridge.start { event in
                    Task { @MainActor [weak self] in self?.bridge(bridge, sent: event, item: item, port: port) }
                }
            } catch {
                log.error("Server didn't start: \(error.localizedDescription, privacy: .public)")
                guard let self, self.bridge === bridge else { return }
                self.bridgeState = .failed(error.localizedDescription)
            }
        }
    }

    private func bridge(_ bridge: HLSBridge, sent event: HLSBridge.Event, item: PlaybackItem, port: UInt16) {
        guard bridge === self.bridge, let server else { return }
        switch event {
        case .ready(let plan):
            // The Wi-Fi address, not localhost: once AirPlay takes over, the Apple TV fetches this same URL.
            let host = LocalNetwork.address() ?? "127.0.0.1"
            var local = item
            local.url = server.playlistURL(host: host, port: port)
            log.info("Ready (\(String(describing: plan), privacy: .public)), serving on \(host, privacy: .public):\(port)")
            local.headers = [:]
            localItem = local
            watchPlayer()
            reportIfStuck()
            player.load(local)
            bridgeState = nil
        case .failed(let message):
            log.error("Bridge failed: \(message, privacy: .public)")
            player.stop()
            bridgeState = .failed(message)
        case .finished:
            // AVPlayer plays on to the end of the playlist by itself.
            break
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to time: TimeInterval) { player.seek(to: time) }
    func select(track: MediaTrack) { player.select(track: track) }
    func disableSubtitles() { player.disableSubtitles() }
    func startPictureInPicture() { player.startPictureInPicture() }

    /// Logs what AVPlayer is doing when it hasn't started a few seconds after the bridge was ready.
    private func reportIfStuck() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            for _ in 0..<6 {
                guard let self, !Task.isCancelled, self.player.state != .playing else { return }
                let player = self.player.player
                let item = player.currentItem
                let access = item?.accessLog()?.events.last
                let errors = item?.errorLog()?.events.suffix(3).map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? []
                log.info("""
                    Not playing yet: item status \(item?.status.rawValue ?? -1), control \(player.timeControlStatus.rawValue), \
                    waiting for \(player.reasonForWaitingToPlay?.rawValue ?? "-", privacy: .public), \
                    AirPlay video \(player.isExternalPlaybackActive), \
                    media requests \(access?.numberOfMediaRequests ?? 0), \
                    errors \(errors.joined(separator: " | "), privacy: .public)
                    """)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Restarts AVPlayer on the bridge's playlist when it fails while the bridge is still producing segments.
    private func watchPlayer() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            guard let player = self?.player else { return }
            for await state in Observations({ player.state }) {
                guard let self, !Task.isCancelled else { return }
                if case .failed(let message) = state, let localItem, recoveries < Self.maxRecoveries {
                    recoveries += 1
                    let details = player.player.currentItem?.errorLog()?.events.last.map {
                        "\($0.errorStatusCode) \($0.errorComment ?? "")"
                    } ?? "-"
                    log.error("AVPlayer failed (\(message, privacy: .public); \(details, privacy: .public)), restarting \(self.recoveries)/\(Self.maxRecoveries)")
                    player.load(localItem)
                } else if state == .playing, recoveries > 0 {
                    log.info("Recovered")
                }
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        diagnosticsTask?.cancel()
        localItem = nil
        recoveries = 0
        startTask?.cancel()
        bridge?.cancel()
        server?.stop()
        player.stop()
        if let directory = bridge?.directory {
            // The bridge thread may still be writing; removing the folder just ends it sooner.
            try? FileManager.default.removeItem(at: directory)
        }
        bridge = nil
        server = nil
        bridgeState = nil
    }
}

extension PlayerEngine {
    /// The AVPlayer engine drawing this engine's video, if it uses one.
    var avPlayerEngine: AVPlayerEngine? {
        (self as? AVPlayerEngine) ?? (self as? BridgedPlayerEngine)?.player
    }
}
