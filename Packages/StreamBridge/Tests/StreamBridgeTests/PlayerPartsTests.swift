// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AudioToolbox
import FFmpeg
import Foundation
@testable import StreamBridge
import Testing

struct LiveTimelineTests {
    @Test func startsNearZero() {
        var timeline = LiveTimeline()
        #expect(timeline.offset(forRaw: 5000, stream: 0) == -5000)
        #expect(timeline.offset(forRaw: 5000.04, stream: 0) == -5000)
        // Another stream starting later shares the timeline.
        #expect(timeline.offset(forRaw: 4999.9, stream: 1) == -5000)
    }

    @Test func smoothsOverAJumpForward() {
        var timeline = LiveTimeline()
        _ = timeline.offset(forRaw: 100, stream: 0)
        _ = timeline.offset(forRaw: 100, stream: 1)
        _ = timeline.offset(forRaw: 101, stream: 0)
        // The encoder restarts an hour later: video crosses first, audio still has old packets in flight.
        let videoOffset = timeline.offset(forRaw: 3700, stream: 0)
        #expect(3700 + videoOffset == 1)
        #expect(timeline.offset(forRaw: 100.98, stream: 1) == -100)
        // Audio crosses the same jump and lines up with the video again.
        #expect(timeline.offset(forRaw: 3699.95, stream: 1) == videoOffset)
    }

    @Test func smoothsOverAJumpBack() {
        var timeline = LiveTimeline()
        _ = timeline.offset(forRaw: 50_000, stream: 0)
        _ = timeline.offset(forRaw: 50_001.5, stream: 0)
        let offset = timeline.offset(forRaw: 2, stream: 0)
        #expect(2 + offset == 1.5)
    }

    @Test func keepsSmallGapsAndReordering() {
        var timeline = LiveTimeline()
        _ = timeline.offset(forRaw: 10, stream: 0)
        #expect(timeline.offset(forRaw: 11.5, stream: 0) == -10)
        #expect(timeline.offset(forRaw: 11.2, stream: 0) == -10)
    }

    @Test func subtitlesFollowTheLatestOffset() {
        var timeline = LiveTimeline()
        _ = timeline.offset(forRaw: 100, stream: 0)
        _ = timeline.offset(forRaw: 500, stream: 0)
        #expect(timeline.sparseOffset(forRaw: 520) == timeline.offset(forRaw: 500.1, stream: 0))
    }
}

struct PacketQueueTests {
    private func packet(size: Int32) -> UnsafeMutablePointer<AVPacket> {
        let packet = av_packet_alloc()!
        av_new_packet(packet, size)
        return packet
    }

    private func free(_ packet: UnsafeMutablePointer<AVPacket>) {
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
    }

    @Test func popsInOrderAndEnds() {
        let queue = PacketQueue()
        var source: UnsafeMutablePointer<AVPacket>? = packet(size: 10)
        defer { av_packet_free(&source) }
        queue.push(source!, time: 1)
        av_new_packet(source, 20)
        queue.push(source!, time: 3)
        #expect(queue.bytes == 30)
        #expect(queue.duration == 2)
        #expect(queue.latestTime == 3)
        queue.finish()

        guard case .packet(let first, serial: 0) = queue.pop(timeout: 0) else { Issue.record("no packet"); return }
        #expect(first.pointee.size == 10)
        free(first)
        guard case .packet(let second, _) = queue.pop(timeout: 0) else { Issue.record("no packet"); return }
        free(second)
        guard case .end(serial: 0) = queue.pop(timeout: 0) else { Issue.record("no end"); return }
    }

    @Test func flushStartsANewSerial() {
        let queue = PacketQueue()
        var source: UnsafeMutablePointer<AVPacket>? = packet(size: 10)
        defer { av_packet_free(&source) }
        queue.push(source!, time: 1)
        queue.finish()
        queue.flush(serial: 4)
        #expect(queue.bytes == 0)
        #expect(queue.latestTime == nil)
        #expect(!queue.isFinished)
        guard case .timedOut = queue.pop(timeout: 0.01) else { Issue.record("expected nothing"); return }
        av_new_packet(source, 10)
        queue.push(source!, time: 9)
        guard case .packet(let packet, serial: 4) = queue.pop(timeout: 0) else { Issue.record("no packet"); return }
        free(packet)
    }

    @Test func dropsOldPackets() {
        let queue = PacketQueue()
        var source: UnsafeMutablePointer<AVPacket>? = packet(size: 10)
        defer { av_packet_free(&source) }
        for time in [1.0, 2, 3, 4] {
            av_new_packet(source, 10)
            queue.push(source!, time: time)
        }
        queue.dropOlder(than: 3)
        #expect(queue.bytes == 20)
        #expect(queue.duration == 1)
    }
}

struct SubtitleTests {
    @Test func stripsASSDialogue() {
        let line = "0,0,Default,,0,0,0,,{\\an8}Hello {\\i1}there{\\i0}\\Nsecond\\hline"
        #expect(SubtitleDecoder.plainText(fromASS: line) == "Hello there\nsecond line")
    }

    @Test func newCueReplacesTheOneShowing() {
        var track = SubtitleTrackCues()
        track.add(SubtitleCue(id: 1, start: 1, end: .infinity, content: .text("one")))
        track.add(SubtitleCue(id: 2, start: 4, end: 6, content: .text("two")))
        // An empty subtitle clears the screen.
        track.add(SubtitleCue(id: 3, start: 5, end: .infinity, content: .text("")))
        #expect(track.cue(at: 0.5) == nil)
        #expect(track.cue(at: 3.9)?.id == 1)
        #expect(track.cue(at: 4.5)?.id == 2)
        #expect(track.cue(at: 5.5) == nil)
        track.dropEnded(before: 4.2)
        #expect(track.cues.map(\.id) == [2])
    }
}

struct AudioLayoutTests {
    private func labels(_ name: String) throws -> [AudioChannelLabel]? {
        var layout = AVChannelLayout()
        try #require(av_channel_layout_from_string(&layout, name) >= 0)
        defer { av_channel_layout_uninit(&layout) }
        guard let data = AudioDecoder.coreAudioLayout(for: layout) else { return nil }
        return data.withUnsafeBytes { bytes in
            let header = bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            if header.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_Stereo { return [kAudioChannelLabel_Left, kAudioChannelLabel_Right] }
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            let descriptions = (bytes.baseAddress! + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<Int(header.pointee.mNumberChannelDescriptions)).map { descriptions[$0].mChannelLabel }
        }
    }

    @Test func describesCommonLayouts() throws {
        #expect(try labels("stereo") == [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        #expect(try labels("5.1(side)") == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround,
                                            kAudioChannelLabel_RightSurround])
        #expect(try labels("7.1")?[4...] == [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                                             kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
    }

    @Test func leavesOutLayoutsCoreAudioCantName() throws {
        #expect(try labels("22.2") == nil)
    }
}

struct LiveRateControllerTests {
    /// Feeds `seconds` of updates at 20 a second with the buffer at `buffered`, and returns the final speed.
    private func run(_ controller: inout LiveRateController, buffered: Double, for seconds: Double) -> Float {
        var rate: Float = 1
        for _ in 0..<Int(seconds * 20) { rate = controller.update(buffered: buffered, interval: 0.05) }
        return rate
    }

    @Test func holdsSpeedAroundTheTarget() {
        var controller = LiveRateController(target: 2)
        #expect(run(&controller, buffered: 2, for: 30) == 1)
        #expect(run(&controller, buffered: 1.5, for: 30) == 1)
        #expect(run(&controller, buffered: 5, for: 30) == 1)
    }

    @Test func slowsDownAsTheBufferDrains() {
        var controller = LiveRateController(target: 2)
        _ = run(&controller, buffered: 2, for: 10)
        #expect(run(&controller, buffered: 0.8, for: 30) == LiveRateController.slow)
        // Stays slow until the buffer is back at the target, not just above the trigger.
        #expect(run(&controller, buffered: 1.6, for: 30) == LiveRateController.slow)
        #expect(run(&controller, buffered: 2.2, for: 30) == 1)
    }

    @Test func speedsUpWhenDelayPilesUp() {
        var controller = LiveRateController(target: 1)
        _ = run(&controller, buffered: 1, for: 10)
        #expect(run(&controller, buffered: 8, for: 30) == LiveRateController.fast)
        #expect(run(&controller, buffered: 3, for: 30) == LiveRateController.fast)
        #expect(run(&controller, buffered: 1.5, for: 30) == 1)
    }

    @Test func ignoresBriefDips() {
        var controller = LiveRateController(target: 2)
        _ = run(&controller, buffered: 2, for: 10)
        // Half a second of jitter barely moves a ten-second average.
        #expect(run(&controller, buffered: 0.2, for: 0.5) == 1)
    }

    @Test func resets() {
        var controller = LiveRateController(target: 2)
        _ = run(&controller, buffered: 0.5, for: 30)
        controller.reset()
        #expect(controller.rate == 1)
        #expect(controller.average == nil)
    }
}
