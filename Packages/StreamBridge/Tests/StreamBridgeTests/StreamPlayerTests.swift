// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
@testable import StreamBridge
import Synchronization
import Testing

/// Plays the synthetic fixtures through the real renderers, at four times normal speed.
@Suite(.serialized)
struct StreamPlayerTests {
    /// Collects a player's events.
    final class Recorder: Sendable {
        private let events = Mutex<[PlayerEvent]>([])

        func record(_ event: PlayerEvent) {
            events.withLock { $0.append(event) }
        }

        var statuses: [PlayerStatus] {
            events.withLock { $0.compactMap { if case .status(let status) = $0 { status } else { nil } } }
        }

        var tracks: [PlayerTrack] {
            events.withLock { $0.compactMap { if case .tracks(let tracks) = $0 { tracks } else { nil } }.last ?? [] }
        }

        var duration: TimeInterval? {
            events.withLock { $0.compactMap { if case .duration(let duration) = $0 { duration } else { nil } }.last }
        }

        var videoSize: CGSize? {
            events.withLock { $0.compactMap { if case .videoSize(let size) = $0 { size } else { nil } }.last }
        }

        var subtitles: [String] {
            events.withLock {
                $0.compactMap {
                    if case .subtitle(let cue?) = $0, case .text(let text) = cue.content { text } else { nil }
                }
            }
        }
    }

    private func fixture(_ name: String) throws -> URL {
        let parts = name.split(separator: ".")
        return try #require(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                              subdirectory: "Fixtures"))
    }

    private func start(_ name: String, live: Bool = false, startPosition: TimeInterval? = nil,
                       subtitles: Bool = false) throws -> (StreamPlayer, Recorder) {
        let player = StreamPlayer()
        let recorder = Recorder()
        player.setRate(4)
        var english: (@Sendable (String?) -> Bool)?
        if subtitles { english = { @Sendable language in language == "eng" } }
        let source = PlayerSource(url: try fixture(name), isLive: live, startPosition: startPosition, buffer: 0.5,
                                  prefersSubtitleLanguage: english)
        player.start(source) { recorder.record($0) }
        return (player, recorder)
    }

    private func waitFor(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test(arguments: ["h264_mp2.ts", "hevc_aac.ts", "h264_interlaced_mp2.ts", "mpeg2_ac3_interlaced.ts"])
    func playsToTheEnd(_ name: String) async throws {
        let (player, recorder) = try start(name)
        defer { player.stop() }
        try await waitFor { recorder.statuses.contains(.playing) }
        #expect(recorder.duration.map { abs($0 - 6) < 0.5 } == true)
        try await waitFor { recorder.statuses.last == .ended || recorder.statuses.last.map(\.isFailure) == true }
        #expect(recorder.statuses.last == .ended)
        #expect(player.currentTime > 5)
    }

    @Test func scalesNonSquarePixels() async throws {
        // 720×576 at 64:45 is 16:9.
        let (player, recorder) = try start("mpeg2_ac3_interlaced.ts")
        defer { player.stop() }
        try await waitFor { recorder.videoSize != nil }
        #expect(recorder.videoSize == CGSize(width: 1024, height: 576))
    }

    @Test func listsTracksAndShowsSubtitles() async throws {
        let (player, recorder) = try start("tracks.mkv", subtitles: true)
        defer { player.stop() }
        try await waitFor { !recorder.tracks.isEmpty }
        let tracks = recorder.tracks
        #expect(tracks.filter { $0.kind == .audio }.map(\.language) == ["eng", "fra"])
        #expect(tracks.filter { $0.kind == .audio && $0.isSelected }.map(\.codec) == ["aac"])
        #expect(tracks.filter { $0.kind == .subtitle && $0.isSelected }.count == 1)

        try await waitFor { recorder.subtitles.count >= 2 }
        #expect(recorder.subtitles.prefix(2) == ["Hello there", "Second line"])

        let french = try #require(tracks.first { $0.language == "fra" })
        player.selectAudio(french)
        try await waitFor { recorder.tracks.contains { $0.id == french.id && $0.isSelected } }
        try await waitFor { recorder.statuses.last == .ended }
    }

    @Test func startsFromAPosition() async throws {
        let (player, recorder) = try start("tracks.mkv", startPosition: 3)
        defer { player.stop() }
        try await waitFor { recorder.statuses.contains(.playing) }
        #expect(player.currentTime >= 2.9)
    }

    @Test func seeksBackAndPausesAndResumes() async throws {
        let (player, recorder) = try start("h264_mp2.ts")
        defer { player.stop() }
        try await waitFor { player.currentTime > 4 }
        player.seek(to: 1)
        try await waitFor { recorder.statuses.last == .playing && player.currentTime < 3 }
        player.pause()
        try await waitFor { recorder.statuses.last == .paused }
        let paused = player.currentTime
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(player.currentTime - paused) < 0.01)
        player.play()
        try await waitFor { recorder.statuses.last == .ended }
    }

    @Test func liveStreamsReportTheSourceStopping() async throws {
        let (player, recorder) = try start("h264_mp2.ts", live: true)
        defer { player.stop() }
        try await waitFor { recorder.statuses.contains(.playing) }
        #expect(recorder.duration == nil)
        try await waitFor { recorder.statuses.last.map(\.isFailure) == true }
    }
}

extension PlayerStatus {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
