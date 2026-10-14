// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import Testing
@testable import RpTvKit

@MainActor
@Observable
final class FakeEngine: PlayerEngine {
    let kind: PlayerEngineKind
    var state = PlaybackState.idle
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var videoGravity = VideoGravity.fit
    var rate: Float = 1
    var supportsPictureInPicture = false
    var isPictureInPictureActive = false
    private(set) var loadedItems: [PlaybackItem] = []
    private(set) var isStopped = false

    init(kind: PlayerEngineKind) {
        self.kind = kind
    }

    func load(_ item: PlaybackItem) {
        loadedItems.append(item)
        state = .loading
    }

    func play() { state = .playing }
    func pause() { state = .paused }
    func seek(to time: TimeInterval) { currentTime = time }

    func stop() {
        isStopped = true
        state = .idle
    }

    func select(track: MediaTrack) {}
    func disableSubtitles() {}
    func startPictureInPicture() {}
}

@MainActor
struct PlaybackCoordinatorTests {
    let memory = EngineMemory(defaults: UserDefaults(suiteName: "PlaybackCoordinatorTests.\(UUID())")!)
    let factory = EngineFactory()

    @MainActor
    final class EngineFactory {
        private(set) var made: [FakeEngine] = []

        func make(_ kind: PlayerEngineKind) -> any PlayerEngine {
            let engine = FakeEngine(kind: kind)
            made.append(engine)
            return engine
        }
    }

    private func coordinator(liveStartTimeout: Duration = .seconds(10)) -> PlaybackCoordinator {
        PlaybackCoordinator(memory: memory, liveStartTimeout: liveStartTimeout) { [factory] in factory.make($0) }
    }

    private func item(_ url: String, isLive: Bool = true, preference: EnginePreference = .automatic) -> PlaybackItem {
        PlaybackItem(id: url, url: URL(string: url)!, title: "Test", isLive: isLive, enginePreference: preference)
    }

    /// Waits for state changes to reach the coordinator, which observes its engine asynchronously.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - Initial engine

    @Test(arguments: [
        ("http://example.com/live/1.ts", PlayerEngineKind.ffmpeg),
        ("http://example.com/movie.mkv", .ffmpeg),
        ("http://example.com/live/1.m3u8", .native),
        ("http://example.com/live/1", .native),
    ])
    func picksEngineFromURL(url: String, expected: PlayerEngineKind) {
        #expect(PlaybackCoordinator.initialEngine(for: item(url), remembered: nil) == expected)
    }

    @Test func rememberedEngineWinsOnlyInAutomaticMode() {
        let hls = item("http://example.com/live/1.m3u8")
        #expect(PlaybackCoordinator.initialEngine(for: hls, remembered: .ffmpeg) == .ffmpeg)

        let forced = item("http://example.com/live/1.m3u8", preference: .native)
        #expect(PlaybackCoordinator.initialEngine(for: forced, remembered: .ffmpeg) == .native)
        let forcedFFmpeg = item("http://example.com/live/1.m3u8", preference: .ffmpeg)
        #expect(PlaybackCoordinator.initialEngine(for: forcedFFmpeg, remembered: nil) == .ffmpeg)
    }

    @Test func bridgeStandsInForFFmpegWhileAirPlaying() {
        #expect(PlaybackCoordinator.initialEngine(for: item("http://example.com/live/1.ts"), remembered: nil,
                                                  prefersBridge: true) == .bridge)
        #expect(PlaybackCoordinator.initialEngine(for: item("http://example.com/live/1.m3u8"), remembered: .ffmpeg,
                                                  prefersBridge: true) == .bridge)
        #expect(PlaybackCoordinator.initialEngine(for: item("http://example.com/live/1.m3u8"), remembered: nil,
                                                  prefersBridge: true) == .native)
        // A forced FFmpeg choice stays FFmpeg.
        let forcedFFmpeg = item("http://example.com/live/1.ts", preference: .ffmpeg)
        #expect(PlaybackCoordinator.initialEngine(for: forcedFFmpeg, remembered: nil, prefersBridge: true) == .ffmpeg)
    }

    // MARK: - Playback and fallback

    @Test func playsTransportStreamsOnFFmpeg() {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.ts"))
        #expect(coordinator.engine?.kind == .ffmpeg)
        #expect(factory.made.map(\.kind) == [.ffmpeg])
        #expect(factory.made[0].loadedItems.count == 1)
    }

    @Test func fallsBackToFFmpegWhenNativeFails() async throws {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.m3u8"))
        #expect(coordinator.engine?.kind == .native)

        factory.made[0].state = .failed("Cannot Open")
        try await eventually { coordinator.engine?.kind == .ffmpeg }
        #expect(factory.made[0].isStopped)
        #expect(factory.made[1].loadedItems.map(\.id) == ["http://example.com/live/1.m3u8"])
        #expect(coordinator.state == .loading)
    }

    @Test func showsFailureWhenFallbackFailsToo() async throws {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.m3u8"))
        factory.made[0].state = .failed("Cannot Open")
        try await eventually { coordinator.engine?.kind == .ffmpeg }

        factory.made[1].state = .failed("FFmpeg failed")
        try await settle()
        #expect(factory.made.count == 2)
        #expect(coordinator.state == .failed("FFmpeg failed"))
    }

    @Test func fallsBackWhenLiveStreamDoesNotStartInTime() async throws {
        let coordinator = coordinator(liveStartTimeout: .milliseconds(50))
        coordinator.play(item("http://example.com/live/1"))
        #expect(coordinator.engine?.kind == .native)
        try await eventually { coordinator.engine?.kind == .ffmpeg }
    }

    @Test func waitsForVODWithoutTimeout() async throws {
        let coordinator = coordinator(liveStartTimeout: .milliseconds(50))
        coordinator.play(item("http://example.com/movie.mp4", isLive: false))
        try await settle()
        #expect(coordinator.engine?.kind == .native)
    }

    @Test func doesNotTimeOutOnceStarted() async throws {
        let coordinator = coordinator(liveStartTimeout: .milliseconds(100))
        coordinator.play(item("http://example.com/live/1.m3u8"))
        factory.made[0].state = .playing
        try await Task.sleep(for: .milliseconds(200))
        #expect(factory.made.count == 1)
    }

    @Test func doesNotFallBackAfterPlaybackStarted() async throws {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.m3u8"))
        factory.made[0].state = .playing
        try await settle()
        factory.made[0].state = .failed("Connection lost")
        try await settle()
        #expect(factory.made.count == 1)
        #expect(coordinator.state == .failed("Connection lost"))
    }

    @Test func forcedEngineDoesNotFallBack() async throws {
        let coordinator = coordinator(liveStartTimeout: .milliseconds(50))
        coordinator.play(item("http://example.com/live/1.m3u8", preference: .native))
        factory.made[0].state = .failed("Cannot Open")
        try await settle()
        #expect(factory.made.count == 1)
        #expect(coordinator.state == .failed("Cannot Open"))
    }

    @Test func remembersWorkingEngineForNextTime() async throws {
        let hls = item("http://example.com/live/1.m3u8")
        let coordinator = coordinator()
        coordinator.play(hls)
        factory.made[0].state = .failed("Cannot Open")
        try await eventually { coordinator.engine?.kind == .ffmpeg }
        factory.made[1].state = .playing
        try await eventually { memory.engine(for: hls.id) == .ffmpeg }

        coordinator.play(hls)
        #expect(coordinator.engine?.kind == .ffmpeg)
        #expect(factory.made.count == 3)
        #expect(memory.engine(for: "http://example.com/live/other.m3u8") == nil)
    }

    @Test func doesNotRememberForcedEngine() async throws {
        let hls = item("http://example.com/live/1.m3u8", preference: .ffmpeg)
        let coordinator = coordinator()
        coordinator.play(hls)
        factory.made[0].state = .playing
        try await settle()
        #expect(memory.engine(for: hls.id) == nil)
    }

    @Test func retryStartsOverFromFirstEngine() async throws {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.m3u8"))
        factory.made[0].state = .failed("Cannot Open")
        try await eventually { coordinator.engine?.kind == .ffmpeg }
        factory.made[1].state = .failed("FFmpeg failed")
        try await settle()

        coordinator.retry()
        #expect(factory.made[1].isStopped)
        #expect(coordinator.engine?.kind == .native)
        factory.made[2].state = .failed("Cannot Open")
        try await eventually { coordinator.engine?.kind == .ffmpeg }
    }

    @Test func stopStopsEngine() {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.ts"))
        coordinator.stop()
        #expect(factory.made[0].isStopped)
        #expect(coordinator.engine == nil)
        #expect(coordinator.state == .idle)
    }

    // MARK: - AirPlay bridge

    @Test func movesFromFFmpegToBridgeWhenAirPlayStarts() async throws {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.ts"))
        #expect(coordinator.engine?.kind == .ffmpeg)

        coordinator.setPrefersBridge(true)
        #expect(coordinator.engine?.kind == .bridge)
        #expect(factory.made.first?.isStopped == true)
        #expect(factory.made.last?.loadedItems.map(\.id) == ["http://example.com/live/1.ts"])
    }

    @Test func keepsNativePlaybackWhenAirPlayStarts() {
        let coordinator = coordinator()
        coordinator.play(item("http://example.com/live/1.m3u8"))
        coordinator.setPrefersBridge(true)
        #expect(coordinator.engine?.kind == .native)
        #expect(factory.made.count == 1)
    }

    @Test func fallsBackFromNativeToBridgeThenFFmpegWhileAirPlaying() async throws {
        let coordinator = coordinator()
        coordinator.setPrefersBridge(true)
        coordinator.play(item("http://example.com/live/1"))
        #expect(coordinator.engine?.kind == .native)

        (coordinator.engine as? FakeEngine)?.state = .failed("no")
        try await eventually { coordinator.engine?.kind == .bridge }
        (coordinator.engine as? FakeEngine)?.state = .failed("no")
        try await eventually { coordinator.engine?.kind == .ffmpeg }
    }

    @Test func remembersBridgedStreamsAsFFmpeg() async throws {
        let coordinator = coordinator()
        coordinator.setPrefersBridge(true)
        coordinator.play(item("http://example.com/live/1.ts"))
        (coordinator.engine as? FakeEngine)?.play()
        try await eventually { memory.engine(for: "http://example.com/live/1.ts") == .ffmpeg }
    }
}
